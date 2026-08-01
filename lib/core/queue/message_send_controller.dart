import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../firebase/firestore_service.dart';
import '../../firebase/models.dart';
import '../native_sound_effect.dart';
import '../store/local_message_store.dart';
import 'background_queue_processor.dart';
import 'pending_file_storage.dart';

// A Future that can be completed early (used so a connectivity-regained
// event can short-circuit an in-progress backoff wait instead of the item
// sitting idle for the rest of a stale delay).
class _CancelableWait {
  _CancelableWait(Duration duration) {
    _timer = Timer(duration, () {
      if (!_completer.isCompleted) _completer.complete();
    });
  }
  final Completer<void> _completer = Completer<void>();
  late final Timer _timer;
  Future<void> get future => _completer.future;
  void completeNow() {
    _timer.cancel();
    if (!_completer.isCompleted) _completer.complete();
  }
  void cancel() => _timer.cancel();
}

// Drives the offline-send retry loop against LocalMessageStore — the single
// authoritative row for a pending send lives there, this controller only
// decides WHEN to attempt/retry it, never holds a separate copy of the data
// itself (unlike the old PendingMessageQueueController, which owned its own
// `List<PendingMediaMessage>` Riverpod state — see LocalMessageStore's own
// doc comment for why two independently-timed copies of the same message
// was the actual bug). Any chat screen watching
// LocalMessageStore.watchChat(chatId) sees every mutation this makes
// immediately, in place — there's nothing for this controller to expose as
// its own `state` for the UI to read.
//
// App-wide, not scoped to any single chat screen's lifetime — a video
// queued while viewing chat A must keep retrying in the background while
// the user is in chat B or has left the chat feature entirely. Retried
// strictly FIFO per chat (one item fully resolves — success or permanently
// failed — before the next one in that same chat starts), exponential
// backoff + jitter, idempotent (retries reuse the same pre-generated
// Firestore message id, so a lost-ack retry overwrites rather than
// duplicates — see FirestoreService.generateMessageId).
class MessageSendController extends Notifier<void> {
  late final LocalMessageStore _store;
  late final FirestoreService _firestoreService;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  static const int maxQueueSize = 50;
  static const int maxAttempts = pendingQueueMaxAttempts;
  static const List<int> _baseBackoffSeconds = [1, 2, 4, 8, 16, 32, 60];
  static const Duration uploadTimeout = pendingQueueUploadTimeout;

  final Set<String> _activeChatProcessors = {};
  final Map<String, _CancelableWait> _pendingWaits = {};
  // Live reference to whatever Storage UploadTask is currently in flight
  // for a given item (image/video only) — lets remove() actually cancel
  // the transfer instead of just hiding the item while it keeps uploading
  // unseen in the background. Populated in _attemptSend, cleared once that
  // attempt settles (success or failure) or the task is cancelled.
  final Map<String, UploadTask> _activeUploadTasks = {};

  @override
  void build() {
    _store = ref.watch(localMessageStoreProvider);
    _firestoreService = ref.watch(firestoreServiceProvider);
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      _onConnectivityChanged,
    );
    ref.onDispose(() {
      _connectivitySub?.cancel();
      for (final wait in _pendingWaits.values) {
        wait.cancel();
      }
    });
    // Loaded once here rather than per-chat-screen (chat_screen.dart's own
    // _initBeepPlayer) — this controller is eagerly instantiated app-wide at
    // startup (see main.dart), so a background/reconnect send that
    // completes while the user isn't even on a chat screen still has the
    // sound ready to play.
    unawaited(
      NativeSoundEffect.load('success_send', 'assets/sounds/success_send.wav'),
    );
    // LocalMessageStore.init() (awaited in main.dart before this controller
    // is ever read) already hydrated every pending item across every chat —
    // just kick off each affected chat's retry loop. Deferred to a
    // microtask: this only reads _store, no `state` mutation risk here (this
    // Notifier's state is void), but matches the same startup shape the old
    // controller used.
    final chatIds = _store.allPending().map((e) => e.chatId).whereType<String>().toSet();
    Future.microtask(() async {
      await _normalizeInterruptedUploads();
      for (final chatId in chatIds) {
        unawaited(_processChatQueue(chatId));
      }
    });
  }

  // An item left in 'uploading' means the app died mid-attempt — the
  // previous run never got to record success or failure for it. Nothing in
  // the foreground path picks such an item back up: _processChatQueue only
  // ever selects 'queued', and retry() explicitly refuses an 'uploading'
  // item (correctly — it's guarding against racing a live attempt that, in
  // this case, no longer exists). So it sat there permanently: never
  // retried, never marked failed, never removed, and still rendering as an
  // in-progress bubble. Confirmed on-device 2026-08-01 — a row stuck this
  // way for days.
  //
  // processPendingQueueOnce (the WorkManager/BGTaskScheduler isolate) has
  // always done exactly this normalisation on its own startup; the
  // foreground controller simply never did, and the asymmetry is the whole
  // bug. Re-attempting is safe for the same reason it is there: the send is
  // idempotent on its pre-generated messageId (see
  // FirestoreService._commitMessage), so a re-attempt of something that
  // actually did land resolves to that message's existing seq rather than a
  // duplicate.
  Future<void> _normalizeInterruptedUploads() async {
    for (final item in _store.allPending()) {
      final chatId = item.chatId;
      if (chatId == null || item.localSendStatus != 'uploading') continue;
      await _store.updatePendingStatus(
        chatId: chatId,
        messageId: item.id,
        status: 'queued',
      );
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasConnection = results.any((r) => r != ConnectivityResult.none);
    if (!hasConnection) return;
    final chatIds = _store.allPending().map((e) => e.chatId).whereType<String>().toSet();
    for (final chatId in chatIds) {
      _pendingWaits[chatId]?.completeNow();
      unawaited(_processChatQueue(chatId));
    }
  }

  // Returns null on success, or a user-facing error string if the item was
  // rejected (queue full) — chat_screen.dart shows this directly as a
  // SnackBar rather than silently queuing.
  Future<String?> enqueue({
    required String chatId,
    required String senderId,
    required String type,
    required String sourceFilePath,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
    int? videoDurationMs,
    int? videoWidth,
    int? videoHeight,
    bool videoHd = false,
    int? imageWidth,
    int? imageHeight,
    List<int>? waveform,
    Uint8List? previewBytes,
    String? fileName,
    int? fileSizeBytes,
    double? latitude,
    double? longitude,
  }) async {
    if (_store.allPending().where((e) => e.chatId == chatId).length >=
        maxQueueSize) {
      return 'Növbə doludur, gözləyin';
    }
    final messageId = _firestoreService.generateMessageId(chatId);
    final durablePath = await persistPendingFile(sourceFilePath, messageId);
    final item = Message(
      id: messageId,
      chatId: chatId,
      senderId: senderId,
      text: '',
      type: type,
      timestamp: Timestamp.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
      videoDurationMs: videoDurationMs,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      videoHd: videoHd,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      waveform: waveform,
      localPreviewBytes: previewBytes,
      fileName: fileName,
      fileSizeBytes: fileSizeBytes,
      latitude: latitude,
      longitude: longitude,
      localFilePath: durablePath,
      localSendStatus: 'queued',
    );
    await _store.insertPending(item);
    unawaited(_processChatQueue(chatId));
    return null;
  }

  // Text counterpart to enqueue() above — same queue, same FIFO/backoff/
  // idempotency machinery, just with no source file (localFilePath stays
  // null) and no upload step, so it reaches Firestore in a single retry
  // instead of an upload-then-validate-then-write sequence. Kept as a
  // separate method rather than folding into enqueue() because the two
  // have no meaningful parameters in common beyond chatId/senderId/reply* —
  // a single method accepting both an optional sourceFilePath and an
  // optional text would just move the "which one is this" branching into
  // the caller instead of removing it.
  Future<String?> enqueueText({
    required String chatId,
    required String senderId,
    required String text,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
  }) async {
    if (_store.allPending().where((e) => e.chatId == chatId).length >=
        maxQueueSize) {
      return 'Növbə doludur, gözləyin';
    }
    final messageId = _firestoreService.generateMessageId(chatId);
    final item = Message(
      id: messageId,
      chatId: chatId,
      senderId: senderId,
      text: text,
      type: 'text',
      timestamp: Timestamp.now(),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
      localSendStatus: 'queued',
    );
    await _store.insertPending(item);
    unawaited(_processChatQueue(chatId));
    return null;
  }

  // Manual long-press retry: one immediate attempt outside the automatic
  // FIFO/backoff loop — never silently re-enters an 8-attempt wait cycle
  // after the user explicitly asked for this right now.
  //
  // Guarded against the automatic per-chat loop already being mid-attempt
  // on this same item (status == 'uploading') — without this, a manual
  // retry tapped right as connectivity returns could run concurrently with
  // _processChatQueue's own attempt, each uploading its own copy of the
  // file and racing to write the same Firestore message.
  Future<void> retry({required String chatId, required String messageId}) async {
    final item = _store
        .allPending()
        .where((e) => e.chatId == chatId && e.id == messageId)
        .firstOrNull;
    if (item == null || item.localSendStatus == 'uploading') return;
    await _store.updatePendingStatus(
      chatId: chatId,
      messageId: messageId,
      status: 'uploading',
    );
    final (seq, uploadedUrl) = await _attemptSend(item);
    if (seq != null) {
      unawaited(NativeSoundEffect.play('success_send'));
      await _confirmAfterDelay(chatId: chatId, messageId: messageId, seq: seq);
    } else {
      await _store.updatePendingStatus(
        chatId: chatId,
        messageId: messageId,
        status: 'failed',
        attemptCount: item.attemptCount + 1,
        uploadedUrl: uploadedUrl,
      );
    }
  }

  Future<void> remove({required String chatId, required String messageId}) async {
    // If this item is mid-upload (the user tapped cancel on the progress
    // ring), actually stop the transfer instead of just hiding it — without
    // this, the bytes would keep flowing to Storage, unseen, until it
    // finished or errored on its own. _attemptSend clears this same entry
    // once its own attempt settles, so this is a no-op for the (far more
    // common) already-finished-successfully removal path.
    final activeTask = _activeUploadTasks.remove(messageId);
    if (activeTask != null) {
      try {
        await activeTask.cancel();
      } catch (e, st) {
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          reason: 'MessageSendController: activeTask.cancel() failed',
        );
      }
    }
    final item = _store
        .allPending()
        .where((e) => e.chatId == chatId && e.id == messageId)
        .firstOrNull;
    await _store.removePending(chatId: chatId, messageId: messageId);
    // If this chat's loop is mid-backoff (waiting to retry this or an
    // earlier item), wake it now instead of leaving it to idle out the
    // delay before re-checking candidates against the now-shorter queue.
    _pendingWaits[chatId]?.completeNow();
    if (item != null) await deletePendingFile(item.localFilePath);
  }

  Future<void> _processChatQueue(String chatId) async {
    if (_activeChatProcessors.contains(chatId)) return;
    _activeChatProcessors.add(chatId);
    try {
      while (true) {
        final candidates =
            _store
                .allPending()
                .where((e) => e.chatId == chatId && e.localSendStatus == 'queued')
                .toList()
              ..sort((a, b) {
                final aTime = a.timestamp?.millisecondsSinceEpoch ?? 0;
                final bTime = b.timestamp?.millisecondsSinceEpoch ?? 0;
                return aTime.compareTo(bTime);
              });
        if (candidates.isEmpty) break;
        final next = candidates.first;
        await _store.updatePendingStatus(
          chatId: chatId,
          messageId: next.id,
          status: 'uploading',
        );
        final (seq, uploadedUrl) = await _attemptSend(next);
        if (seq != null) {
          unawaited(NativeSoundEffect.play('success_send'));
          unawaited(_confirmAfterDelay(chatId: chatId, messageId: next.id, seq: seq));
          continue;
        }
        final newAttemptCount = next.attemptCount + 1;
        if (newAttemptCount >= maxAttempts) {
          await _store.updatePendingStatus(
            chatId: chatId,
            messageId: next.id,
            status: 'failed',
            attemptCount: newAttemptCount,
            uploadedUrl: uploadedUrl,
          );
          // A permanently-failed item must not block the rest of this
          // chat's queue forever — move on.
          continue;
        }
        await _store.updatePendingStatus(
          chatId: chatId,
          messageId: next.id,
          status: 'queued',
          attemptCount: newAttemptCount,
          uploadedUrl: uploadedUrl,
        );
        await _cancelableBackoffDelay(chatId, newAttemptCount);
      }
    } finally {
      _activeChatProcessors.remove(chatId);
    }
  }

  // Not an immediate markConfirmed() the instant send() returns.
  // FirestoreService._commitMessage's seq-assignment transaction has no
  // local-cache optimism the way a plain write does — transactions only
  // become visible, to the writer's own listeners included, once the full
  // round trip actually completes — so this Future resolving and the chat
  // screen's live Firestore sync picking up the real message are two
  // independently-timed events with no ordering guarantee. Marking this
  // row confirmed (which flips its rendering from the pending clock icon)
  // synchronously here, before that live sync has necessarily caught up,
  // isn't itself a visibility gap the way the old two-source design's
  // instant queue-removal was (this row stays in LocalMessageStore and
  // keeps rendering throughout — there's no second object to swap in
  // anymore), but the delay is kept anyway as a deliberate grace window so
  // reactions/read-receipts arriving from the live sync have a moment to
  // land on the now-confirmed row rather than racing its own transition.
  Future<void> _confirmAfterDelay({
    required String chatId,
    required String messageId,
    required int seq,
  }) {
    return Future.delayed(const Duration(milliseconds: 300)).then(
      (_) => _store.markConfirmed(chatId: chatId, messageId: messageId, seq: seq),
    );
  }

  Future<void> _cancelableBackoffDelay(String chatId, int attemptNumber) {
    final wait = _CancelableWait(_backoffWithJitter(attemptNumber));
    _pendingWaits[chatId] = wait;
    return wait.future.whenComplete(() => _pendingWaits.remove(chatId));
  }

  Duration _backoffWithJitter(int attemptNumber) {
    final index = (attemptNumber - 1).clamp(0, _baseBackoffSeconds.length - 1);
    final baseMs = _baseBackoffSeconds[index] * 1000;
    // ±25% jitter — spreads out simultaneous retries across many devices
    // reconnecting at once instead of hammering the backend in lockstep.
    final jitterFactor = 1 + (Random().nextDouble() * 0.5 - 0.25);
    return Duration(milliseconds: (baseMs * jitterFactor).round());
  }

  // No separate "is the internet actually reachable" probe — connectivity
  // status is only ever used as a hint to retry sooner. The real arbiter of
  // success is this attempt itself; a captive-portal-style "connected but
  // no real internet" case simply times out like any other failure and
  // flows into the same backoff/retry path. Delegates to the same
  // attemptSendPendingMessage() the background isolate uses (see
  // background_queue_processor.dart) so the two never drift apart.
  //
  // Returns (seq, uploadedUrl): seq is non-null only on success. uploadedUrl
  // is reported back (even on an overall-failed attempt) so the caller can
  // persist it on the item — see Message.uploadedUrl's doc comment.
  Future<(int? seq, String? uploadedUrl)> _attemptSend(Message item) async {
    String? uploadedUrl;
    try {
      final (success, seq) = await attemptSendPendingMessage(
        item,
        _firestoreService,
        timeout: uploadTimeout,
        onUploaded: (url) => uploadedUrl = url,
        onTaskStarted: (task) => _activeUploadTasks[item.id] = task,
        onProgress: (progress) => _updateProgress(item.chatId!, item.id, progress),
      );
      return (success ? seq : null, uploadedUrl);
    } finally {
      // Whether this attempt succeeded, failed, or was cancelled out from
      // under it — the task this item was tracking is no longer relevant.
      _activeUploadTasks.remove(item.id);
    }
  }

  // Throttled to whole-percent steps so a fast upload doesn't trigger
  // dozens of store emits/rebuilds — LocalMessageStore.updateProgress
  // itself never touches disk (see its own doc comment), this throttle is
  // purely about not spamming watchChat's listeners.
  void _updateProgress(String chatId, String messageId, double progress) {
    final current = _store
        .allPending()
        .where((e) => e.chatId == chatId && e.id == messageId)
        .firstOrNull;
    if (current == null) return;
    if ((progress * 100).round() ==
        ((current.localUploadProgress ?? 0) * 100).round()) {
      return;
    }
    _store.updateProgress(chatId: chatId, messageId: messageId, progress: progress);
  }
}

final messageSendControllerProvider =
    NotifierProvider<MessageSendController, void>(MessageSendController.new);
