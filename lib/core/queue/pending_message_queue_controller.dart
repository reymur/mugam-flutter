import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../firebase/firestore_service.dart';
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
  static const int maxAttempts = 8;
  static const List<int> _baseBackoffSeconds = [1, 2, 4, 8, 16, 32, 60];
  static const Duration uploadTimeout = Duration(seconds: 20);

  final Set<String> _activeChatProcessors = {};
  final Map<String, _CancelableWait> _pendingWaits = {};

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
    );
    state = [...state, item];
    await _service.saveAll(state);
    unawaited(_processChatQueue(chatId));
    return null;
  }

  // Manual long-press retry: one immediate attempt outside the automatic
  // FIFO/backoff loop — never silently re-enters an 8-attempt wait cycle
  // after the user explicitly asked for this right now.
  Future<void> retry(String localId) async {
    final current = state.where((e) => e.localId == localId).toList();
    if (current.isEmpty) return;
    final item = current.first;
    _updateItem(item.copyWith(status: 'uploading'));
    final success = await _attemptSend(item);
    if (success) {
      await _removeInternal(localId);
    } else {
      _updateItem(
        item.copyWith(status: 'failed', attemptCount: item.attemptCount + 1),
      );
      await _service.saveAll(state);
    }
  }

  Future<void> remove(String localId) => _removeInternal(localId);

  Future<void> _removeInternal(String localId) async {
    final current = state.where((e) => e.localId == localId).toList();
    if (current.isEmpty) return;
    await _service.deleteFile(current.first.filePath);
    state = state.where((e) => e.localId != localId).toList();
    await _service.saveAll(state);
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
        final success = await _attemptSend(next);
        if (success) {
          await _removeInternal(next.localId);
          continue;
        }
        final newAttemptCount = next.attemptCount + 1;
        if (newAttemptCount >= maxAttempts) {
          _updateItem(next.copyWith(status: 'failed', attemptCount: newAttemptCount));
          await _service.saveAll(state);
          // A permanently-failed item must not block the rest of this
          // chat's queue forever — move on.
          continue;
        }
        _updateItem(next.copyWith(status: 'queued', attemptCount: newAttemptCount));
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
  // flows into the same backoff/retry path.
  Future<bool> _attemptSend(PendingMediaMessage item) async {
    try {
      if (!await File(item.filePath).exists()) {
        debugPrint(
          'PendingMessageQueueController: file missing for ${item.localId}',
        );
        return false;
      }
      switch (item.type) {
        case 'image':
          final url = await _firestoreService
              .uploadChatImage(chatId: item.chatId, filePath: item.filePath)
              .timeout(uploadTimeout);
          await _firestoreService
              .sendImageMessage(
                chatId: item.chatId,
                senderId: item.senderId,
                imageURL: url,
                messageId: item.messageId,
                replyToId: item.replyToId,
                replyToText: item.replyToText,
                replyToSenderName: item.replyToSenderName,
                replyToImageURL: item.replyToImageURL,
                replyToVideoURL: item.replyToVideoURL,
              )
              .timeout(uploadTimeout);
          return true;
        case 'audio':
          final url = await _firestoreService
              .uploadChatAudio(chatId: item.chatId, filePath: item.filePath)
              .timeout(uploadTimeout);
          await _firestoreService
              .sendAudioMessage(
                chatId: item.chatId,
                senderId: item.senderId,
                audioURL: url,
                messageId: item.messageId,
                replyToId: item.replyToId,
                replyToText: item.replyToText,
                replyToSenderName: item.replyToSenderName,
                replyToImageURL: item.replyToImageURL,
                replyToVideoURL: item.replyToVideoURL,
              )
              .timeout(uploadTimeout);
          return true;
        case 'video':
          final url = await _firestoreService
              .uploadChatVideo(chatId: item.chatId, filePath: item.filePath)
              .timeout(uploadTimeout);
          await _firestoreService
              .sendVideoMessage(
                chatId: item.chatId,
                senderId: item.senderId,
                videoURL: url,
                messageId: item.messageId,
                replyToId: item.replyToId,
                replyToText: item.replyToText,
                replyToSenderName: item.replyToSenderName,
                replyToImageURL: item.replyToImageURL,
                replyToVideoURL: item.replyToVideoURL,
              )
              .timeout(uploadTimeout);
          return true;
        default:
          return false;
      }
    } catch (e) {
      debugPrint(
        'PendingMessageQueueController: attempt failed for ${item.localId} ($e)',
      );
      return false;
    }
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
