import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../firebase/firestore_service.dart';
import '../../firebase_options.dart';
import 'pending_media_message.dart';
import 'pending_message_queue_service.dart';

const String pendingQueueRetryTaskName = 'pendingQueueRetryTask';
const int pendingQueueMaxAttempts = 8;
const Duration pendingQueueUploadTimeout = Duration(seconds: 20);

// Shared by the live PendingMessageQueueController (foreground) and the
// background isolate spawned by BGTaskScheduler/WorkManager — a single
// attempt at uploading+sending one queued item, idempotent via its
// pre-generated messageId.
Future<bool> attemptSendPendingMessage(
  PendingMediaMessage item,
  FirestoreService firestoreService, {
  Duration timeout = pendingQueueUploadTimeout,
}) async {
  try {
    if (!await File(item.filePath).exists()) {
      debugPrint('attemptSendPendingMessage: file missing for ${item.localId}');
      return false;
    }
    switch (item.type) {
      case 'image':
        final url = await firestoreService
            .uploadChatImage(chatId: item.chatId, filePath: item.filePath)
            .timeout(timeout);
        await firestoreService
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
            .timeout(timeout);
        return true;
      case 'audio':
        final url = await firestoreService
            .uploadChatAudio(chatId: item.chatId, filePath: item.filePath)
            .timeout(timeout);
        await firestoreService
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
            .timeout(timeout);
        return true;
      case 'video':
        final url = await firestoreService
            .uploadChatVideo(chatId: item.chatId, filePath: item.filePath)
            .timeout(timeout);
        await firestoreService
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
            .timeout(timeout);
        return true;
      default:
        return false;
    }
  } catch (e) {
    debugPrint('attemptSendPendingMessage: failed for ${item.localId} ($e)');
    return false;
  }
}

// Runs in a fresh, headless background isolate spawned by the OS (BGTaskScheduler
// on iOS, WorkManager on Android) — no ProviderScope/widget tree exists here, so
// this talks to the same persisted queue directly instead of going through
// PendingMessageQueueController. One best-effort pass: for each chat, attempt
// its oldest queued item, and keep going through that chat's queue only while
// attempts keep succeeding — a failure stops that chat for this run (no
// backoff *wait* here; background execution windows are too short to spend on
// waiting, the next periodic run or the next app foreground is the retry).
Future<void> processPendingQueueOnce() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final prefs = await SharedPreferences.getInstance();
  final service = PendingMessageQueueService(prefs);
  final firestoreService = FirestoreService();

  final items = service
      .readAll()
      .map((e) => e.status == 'uploading' ? e.copyWith(status: 'queued') : e)
      .toList();
  final byChat = <String, List<PendingMediaMessage>>{};
  for (final item in items) {
    byChat.putIfAbsent(item.chatId, () => []).add(item);
  }

  final result = List<PendingMediaMessage>.from(items);

  for (final chatItems in byChat.values) {
    chatItems.sort((a, b) => a.createdAtMillis.compareTo(b.createdAtMillis));
    for (final item in chatItems) {
      final current = result.where((e) => e.localId == item.localId).toList();
      if (current.isEmpty || current.first.status != 'queued') continue;

      final success = await attemptSendPendingMessage(item, firestoreService);
      if (success) {
        await service.deleteFile(item.filePath);
        result.removeWhere((e) => e.localId == item.localId);
        await service.saveAll(result);
        continue;
      }

      final newAttemptCount = item.attemptCount + 1;
      final index = result.indexWhere((e) => e.localId == item.localId);
      if (newAttemptCount >= pendingQueueMaxAttempts) {
        result[index] = item.copyWith(status: 'failed', attemptCount: newAttemptCount);
      } else {
        result[index] = item.copyWith(status: 'queued', attemptCount: newAttemptCount);
      }
      await service.saveAll(result);
      // Stop processing the rest of this chat's queue for this run — the
      // next item must not jump ahead of one that just failed and is
      // awaiting its next attempt (same FIFO rule as the live controller).
      break;
    }
  }
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    await processPendingQueueOnce();
    return true;
  });
}
