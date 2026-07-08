import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../firebase/firestore_service.dart';
import 'background_queue_processor.dart';
import 'pending_media_message.dart';
import 'pending_message_queue_service.dart';

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

// Offline media-send queue: photo/voice/video messages that couldn't upload
// immediately are retried here with exponential backoff + jitter, strictly
// FIFO per chat (one item fully resolves — success or permanently failed —
// before the next one in that same chat starts), capped in size, and
// idempotent (retries reuse the same pre-generated Firestore message id, so
// a lost-ack retry overwrites rather than duplicates).
//
// This is app-wide, not scoped to any single chat screen's lifetime — a
// video queued while viewing chat A must keep retrying in the background
// while the user is in chat B or has left the chat feature entirely.
class PendingMessageQueueController extends Notifier<List<PendingMediaMessage>> {
  late final PendingMessageQueueService _service;
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
  List<PendingMediaMessage> build() {
    _service = ref.watch(pendingMessageQueueServiceProvider);
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
    // An item stuck 'uploading' means the app died mid-attempt last run —
    // we can't know if that upload actually landed, so treat it as
    // 'queued' again; the idempotent messageId makes re-attempting safe
    // either way.
    final items = _service
        .readAll()
        .map((e) => e.status == 'uploading' ? e.copyWith(status: 'queued') : e)
        .toList();
    // Deferred to a microtask: _processChatQueue mutates `state`, which
    // Riverpod forbids doing synchronously from inside build() itself.
    Future.microtask(() {
      for (final chatId in items.map((e) => e.chatId).toSet()) {
        unawaited(_processChatQueue(chatId));
      }
    });
    return items;
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasConnection = results.any((r) => r != ConnectivityResult.none);
    if (!hasConnection) return;
    for (final chatId in state.map((e) => e.chatId).toSet()) {
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
  }) async {
    if (state.length >= maxQueueSize) {
      return 'Növbə doludur, gözləyin';
    }
    final localId = PendingMediaMessage.generateLocalId();
    final messageId = _firestoreService.generateMessageId(chatId);
    final durablePath = await _service.persistFile(sourceFilePath, localId);
    final item = PendingMediaMessage(
      localId: localId,
      messageId: messageId,
      chatId: chatId,
      senderId: senderId,
      type: type,
      filePath: durablePath,
      createdAtMillis: DateTime.now().millisecondsSinceEpoch,
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
      previewBytes: previewBytes,
    );
    state = [...state, item];
    await _service.saveAll(state);
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
  Future<void> retry(String localId) async {
    final current = state.where((e) => e.localId == localId).toList();
    if (current.isEmpty) return;
    final item = current.first;
    if (item.status == 'uploading') return;
    _updateItem(item.copyWith(status: 'uploading'));
    final (success, uploadedUrl) = await _attemptSend(item);
    if (success) {
      await _removeInternal(localId);
    } else {
      _updateItem(
        item.copyWith(
          status: 'failed',
          attemptCount: item.attemptCount + 1,
          uploadedUrl: uploadedUrl,
        ),
      );
      await _service.saveAll(state);
    }
  }

  Future<void> remove(String localId) => _removeInternal(localId);

  // State is updated (hiding the synthetic pending bubble) BEFORE the local
  // file cleanup, not after — by the time this runs, the real Firestore
  // document this item's send() call just wrote is already visible to the
  // live message stream, so leaving the pending item in `state` during a
  // slow disk delete meant both the synthetic and the real message rendered
  // at once for however long that delete took (confirmed on-device: a
  // visible duplicate-then-jump when sending photo/video/voice, never for
  // text since it has no pending phase). File deletion is a pure cleanup
  // side effect and doesn't need to block that.
  Future<void> _removeInternal(String localId) async {
    final current = state.where((e) => e.localId == localId).toList();
    if (current.isEmpty) return;
    // If this item is mid-upload (the user tapped cancel on the progress
    // ring), actually stop the transfer instead of just hiding it — without
    // this, the bytes would keep flowing to Storage, unseen, until it
    // finished or errored on its own. _attemptSend clears this same entry
    // once its own attempt settles, so this is a no-op for the (far more
    // common) already-finished-successfully removal path.
    final activeTask = _activeUploadTasks.remove(localId);
    if (activeTask != null) {
      try {
        await activeTask.cancel();
      } catch (_) {}
    }
    state = state.where((e) => e.localId != localId).toList();
    await _service.saveAll(state);
    // If this chat's loop is mid-backoff (waiting to retry this or an
    // earlier item), wake it now instead of leaving it to idle out the
    // delay before re-checking candidates against the now-shorter queue.
    _pendingWaits[current.first.chatId]?.completeNow();
    await _service.deleteFile(current.first.filePath);
  }

  void _updateItem(PendingMediaMessage updated) {
    state = [
      for (final e in state) if (e.localId == updated.localId) updated else e,
    ];
  }

  Future<void> _processChatQueue(String chatId) async {
    if (_activeChatProcessors.contains(chatId)) return;
    _activeChatProcessors.add(chatId);
    try {
      while (true) {
        final candidates =
            state.where((e) => e.chatId == chatId && e.status == 'queued').toList()
              ..sort((a, b) => a.createdAtMillis.compareTo(b.createdAtMillis));
        if (candidates.isEmpty) break;
        final next = candidates.first;
        _updateItem(next.copyWith(status: 'uploading'));
        final (success, uploadedUrl) = await _attemptSend(next);
        if (success) {
          await _removeInternal(next.localId);
          continue;
        }
        final newAttemptCount = next.attemptCount + 1;
        if (newAttemptCount >= maxAttempts) {
          _updateItem(
            next.copyWith(
              status: 'failed',
              attemptCount: newAttemptCount,
              uploadedUrl: uploadedUrl,
            ),
          );
          await _service.saveAll(state);
          // A permanently-failed item must not block the rest of this
          // chat's queue forever — move on.
          continue;
        }
        _updateItem(
          next.copyWith(
            status: 'queued',
            attemptCount: newAttemptCount,
            uploadedUrl: uploadedUrl,
          ),
        );
        await _service.saveAll(state);
        await _cancelableBackoffDelay(chatId, newAttemptCount);
      }
    } finally {
      _activeChatProcessors.remove(chatId);
    }
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
  // Reports back the uploaded URL (if the upload step got that far) so the
  // caller can persist it on the item even when the overall attempt still
  // counts as failed — see PendingMediaMessage.uploadedUrl.
  Future<(bool success, String? uploadedUrl)> _attemptSend(
    PendingMediaMessage item,
  ) async {
    String? uploadedUrl;
    try {
      final success = await attemptSendPendingMessage(
        item,
        _firestoreService,
        timeout: uploadTimeout,
        onUploaded: (url) => uploadedUrl = url,
        onTaskStarted: (task) => _activeUploadTasks[item.localId] = task,
        onProgress: (progress) => _updateProgress(item.localId, progress),
      );
      return (success, uploadedUrl);
    } finally {
      // Whether this attempt succeeded, failed, or was cancelled out from
      // under it — the task this item was tracking is no longer relevant.
      _activeUploadTasks.remove(item.localId);
    }
  }

  // Only updates in-memory state (drives the progress ring), never touches
  // disk — Storage's snapshotEvents can fire many times a second, and
  // persisting on every tick would be needless I/O for a value that's
  // meaningless across an app restart anyway (see
  // PendingMediaMessage.uploadProgress). Throttled to whole-percent steps
  // so a fast upload doesn't still trigger dozens of rebuilds.
  void _updateProgress(String localId, double progress) {
    final current = state.where((e) => e.localId == localId).toList();
    if (current.isEmpty) return;
    final item = current.first;
    if ((progress * 100).round() == (item.uploadProgress * 100).round()) {
      return;
    }
    state = [
      for (final e in state)
        if (e.localId == localId) e.copyWith(uploadProgress: progress) else e,
    ];
  }
}

final pendingMessageQueueServiceProvider =
    Provider<PendingMessageQueueService>((ref) {
      throw UnimplementedError(
        'pendingMessageQueueServiceProvider must be overridden with a '
        'SharedPreferences instance at app startup',
      );
    });

final pendingMessageQueueProvider =
    NotifierProvider<PendingMessageQueueController, List<PendingMediaMessage>>(
      PendingMessageQueueController.new,
    );

final pendingMessagesForChatProvider =
    Provider.family<List<PendingMediaMessage>, String>((ref, chatId) {
      return ref
          .watch(pendingMessageQueueProvider)
          .where((e) => e.chatId == chatId)
          .toList();
    });
