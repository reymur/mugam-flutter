import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../firebase/firestore_service.dart';
import '../../firebase/models.dart';
import '../../firebase_options.dart';
import '../media/video_compressor.dart';
import '../store/local_message_store.dart';
import 'pending_file_storage.dart';

const String pendingQueueRetryTaskName = 'pendingQueueRetryTask';
const int pendingQueueMaxAttempts = 8;
const Duration pendingQueueUploadTimeout = Duration(seconds: 20);

// Shared by the live MessageSendController (foreground) and the background
// isolate spawned by BGTaskScheduler/WorkManager — a single attempt at
// uploading+sending one pending Message, idempotent via its own `id` (the
// same Firestore messageId end to end — see LocalMessageStore's own doc
// comment).
//
// Reuses item.uploadedUrl instead of re-uploading when a previous attempt's
// upload step succeeded but the Firestore write after it didn't (timeout on
// a slow reconnect, etc.) — re-uploading the whole file on every retry was
// both wasteful and, worse, left a real duplicate-write race: two attempts
// for the same messageId (manual retry() firing alongside the automatic
// per-chat loop, or the foreground queue racing the WorkManager background
// task) could each upload their own copy and then both call
// sendXMessage(messageId: ...), with the later Firestore write silently
// clobbering the earlier one's videoURL/imageURL/audioURL. onUploaded lets
// the caller persist the URL the moment it's obtained, before the send step
// that might still fail. The remaining half of the fix — sendXMessage only
// writing if the document doesn't already exist — lives in
// FirestoreService._commitMessage, so even if two attempts still race to
// call it, only one write survives (and both learn the real seq either
// way — see that function's own doc comment).
//
// Returns (success, seq): seq is only non-null when success is true — the
// caller uses it to call LocalMessageStore.markConfirmed and update this
// device's own pending row in place.
Future<(bool success, int? seq)> attemptSendPendingMessage(
  Message item,
  FirestoreService firestoreService, {
  Duration timeout = pendingQueueUploadTimeout,
  void Function(String url)? onUploaded,
  // Image/video only — see FirestoreService.uploadChatImage's doc comment.
  // Left null (as the background isolate does) when there's no UI able to
  // show progress or offer cancellation anyway.
  void Function(UploadTask task)? onTaskStarted,
  void Function(double progress)? onProgress,
}) async {
  final chatId = item.chatId;
  if (chatId == null) return (false, null);
  try {
    // Text has nothing to upload — no file, no Storage step, no
    // waitForValidatedUpload — so it's handled entirely separately from the
    // file-based types below, before localFilePath is ever touched.
    if (item.type == 'text') {
      final seq = await firestoreService
          .sendMessage(
            chatId: chatId,
            senderId: item.senderId,
            text: item.text,
            messageId: item.id,
            replyToId: item.replyToId,
            replyToText: item.replyToText,
            replyToSenderName: item.replyToSenderName,
            replyToImageURL: item.replyToImageURL,
            replyToVideoURL: item.replyToVideoURL,
          )
          .timeout(timeout);
      return (true, seq);
    }

    // Every remaining type is file-based, so localFilePath must be set — a
    // non-text item with a null localFilePath is an invariant violation (a
    // bug elsewhere, not a normal runtime state) and gets handled
    // explicitly rather than risking a null-check crash further down. This
    // early return is also what lets `filePath` below be used unwrapped
    // for the rest of this function — Dart promotes it to non-null for
    // every path reachable only past this check, including inside every
    // switch case.
    final filePath = item.localFilePath;
    if (filePath == null) {
      debugPrint(
        'attemptSendPendingMessage: no localFilePath for non-text item '
        '${item.id} (type=${item.type}) — treating as failed',
      );
      return (false, null);
    }

    // A prior attempt's upload can have already succeeded (item.uploadedUrl
    // set) even though the local temp file is gone by now — iOS is free to
    // purge app temp storage, and video's own compressed copy is deleted
    // right after upload (see the `finally` block below). In that case the
    // file is irrelevant: every branch below only reads it to perform the
    // upload, which is skipped whenever uploadedUrl is already set. Only
    // require the file to exist when the upload itself still needs to run.
    if (item.uploadedUrl == null && !await File(filePath).exists()) {
      debugPrint('attemptSendPendingMessage: file missing for ${item.id}');
      return (false, null);
    }
    switch (item.type) {
      case 'image':
        {
          final fileName = '${item.id}.jpg';
          final url =
              item.uploadedUrl ??
              await firestoreService
                  .uploadChatImage(
                    chatId: chatId,
                    filePath: filePath,
                    senderId: item.senderId,
                    fileName: fileName,
                    onTaskStarted: onTaskStarted,
                    onProgress: onProgress,
                  )
                  .timeout(timeout);
          if (item.uploadedUrl == null) onUploaded?.call(url);
          final validated = await firestoreService.waitForValidatedUpload(
            chatId: chatId,
            fileName: fileName,
          );
          if (!validated) return (false, null);
          final seq = await firestoreService
              .sendImageMessage(
                chatId: chatId,
                senderId: item.senderId,
                imageURL: url,
                imageWidth: item.imageWidth,
                imageHeight: item.imageHeight,
                mediaOriginChatId: chatId,
                mediaFileName: fileName,
                messageId: item.id,
                replyToId: item.replyToId,
                replyToText: item.replyToText,
                replyToSenderName: item.replyToSenderName,
                replyToImageURL: item.replyToImageURL,
                replyToVideoURL: item.replyToVideoURL,
              )
              .timeout(timeout);
          return (true, seq);
        }
      case 'audio':
        {
          final fileName = '${item.id}.m4a';
          final url =
              item.uploadedUrl ??
              await firestoreService
                  .uploadChatAudio(
                    chatId: chatId,
                    filePath: filePath,
                    senderId: item.senderId,
                    fileName: fileName,
                  )
                  .timeout(timeout);
          if (item.uploadedUrl == null) onUploaded?.call(url);
          final validated = await firestoreService.waitForValidatedUpload(
            chatId: chatId,
            fileName: fileName,
          );
          if (!validated) return (false, null);
          final seq = await firestoreService
              .sendAudioMessage(
                chatId: chatId,
                senderId: item.senderId,
                audioURL: url,
                waveform: item.waveform,
                mediaOriginChatId: chatId,
                mediaFileName: fileName,
                messageId: item.id,
                replyToId: item.replyToId,
                replyToText: item.replyToText,
                replyToSenderName: item.replyToSenderName,
                replyToImageURL: item.replyToImageURL,
                replyToVideoURL: item.replyToVideoURL,
              )
              .timeout(timeout);
          return (true, seq);
        }
      case 'location':
        {
          final fileName = '${item.id}.jpg';
          final url =
              item.uploadedUrl ??
              await firestoreService
                  .uploadChatImage(
                    chatId: chatId,
                    filePath: filePath,
                    senderId: item.senderId,
                    fileName: fileName,
                    onTaskStarted: onTaskStarted,
                    onProgress: onProgress,
                  )
                  .timeout(timeout);
          if (item.uploadedUrl == null) onUploaded?.call(url);
          final validated = await firestoreService.waitForValidatedUpload(
            chatId: chatId,
            fileName: fileName,
          );
          if (!validated) return (false, null);
          final lat = item.latitude;
          final lng = item.longitude;
          if (lat == null || lng == null) return (false, null);
          final seq = await firestoreService
              .sendLocationMessage(
                chatId: chatId,
                senderId: item.senderId,
                locationImageURL: url,
                latitude: lat,
                longitude: lng,
                mediaOriginChatId: chatId,
                mediaFileName: fileName,
                messageId: item.id,
                replyToId: item.replyToId,
                replyToText: item.replyToText,
                replyToSenderName: item.replyToSenderName,
                replyToImageURL: item.replyToImageURL,
                replyToVideoURL: item.replyToVideoURL,
              )
              .timeout(timeout);
          return (true, seq);
        }
      case 'file':
        {
          // Preserve the picked file's own extension in the Storage object
          // name (unlike image/video, whose extension is fixed by the
          // compression step) — open_filex and the OS's own file-type
          // association both need a real extension on the locally cached
          // copy at open time, and that copy's name is derived from this
          // same mediaFileName (see FileMessageBubble).
          final originalName = item.fileName ?? '${item.id}.bin';
          final ext = originalName.contains('.')
              ? originalName.split('.').last
              : 'bin';
          final fileName = '${item.id}.$ext';
          final url =
              item.uploadedUrl ??
              await firestoreService
                  .uploadChatFile(
                    chatId: chatId,
                    filePath: filePath,
                    senderId: item.senderId,
                    fileName: fileName,
                    onTaskStarted: onTaskStarted,
                    onProgress: onProgress,
                  )
                  .timeout(timeout);
          if (item.uploadedUrl == null) onUploaded?.call(url);
          final validated = await firestoreService.waitForValidatedUpload(
            chatId: chatId,
            fileName: fileName,
          );
          if (!validated) return (false, null);
          final seq = await firestoreService
              .sendFileMessage(
                chatId: chatId,
                senderId: item.senderId,
                fileURL: url,
                fileName: originalName,
                fileSizeBytes: item.fileSizeBytes,
                mediaOriginChatId: chatId,
                mediaFileName: fileName,
                messageId: item.id,
                replyToId: item.replyToId,
                replyToText: item.replyToText,
                replyToSenderName: item.replyToSenderName,
                replyToImageURL: item.replyToImageURL,
                replyToVideoURL: item.replyToVideoURL,
              )
              .timeout(timeout);
          return (true, seq);
        }
      case 'video':
        {
          // Compressed fresh on every attempt rather than once at enqueue
          // time — keeps the pending bubble's instant appearance (see
          // chat_screen.dart's _uploadAndSendVideoFile) since this only
          // runs once the item is actually picked up for upload. Skipped
          // entirely when a prior attempt's upload already succeeded
          // (item.uploadedUrl set) — nothing left to compress for, that
          // path only needs the earlier Firestore write retried.
          String uploadPath = filePath;
          if (item.uploadedUrl == null) {
            uploadPath = await compressVideoFile(
              filePath,
              hd: item.videoHd,
              onProgress: onProgress == null
                  ? null
                  : (p) => onProgress(p * 0.4),
            );
          }
          try {
            final ext = uploadPath.contains('.')
                ? uploadPath.split('.').last
                : 'mp4';
            final fileName = '${item.id}.$ext';
            final url =
                item.uploadedUrl ??
                await firestoreService
                    .uploadChatVideo(
                      chatId: chatId,
                      filePath: uploadPath,
                      senderId: item.senderId,
                      fileName: fileName,
                      onTaskStarted: onTaskStarted,
                      onProgress: onProgress == null
                          ? null
                          : (p) => onProgress(0.4 + p * 0.6),
                    )
                    .timeout(timeout);
            if (item.uploadedUrl == null) onUploaded?.call(url);
            final validated = await firestoreService.waitForValidatedUpload(
              chatId: chatId,
              fileName: fileName,
            );
            if (!validated) return (false, null);
            final seq = await firestoreService
                .sendVideoMessage(
                  chatId: chatId,
                  senderId: item.senderId,
                  videoURL: url,
                  videoDurationMs: item.videoDurationMs,
                  videoWidth: item.videoWidth,
                  videoHeight: item.videoHeight,
                  mediaOriginChatId: chatId,
                  mediaFileName: fileName,
                  messageId: item.id,
                  replyToId: item.replyToId,
                  replyToText: item.replyToText,
                  replyToSenderName: item.replyToSenderName,
                  replyToImageURL: item.replyToImageURL,
                  replyToVideoURL: item.replyToVideoURL,
                )
                .timeout(timeout);
            return (true, seq);
          } finally {
            if (uploadPath != filePath) {
              unawaited(
                File(
                  uploadPath,
                ).delete().catchError((_) => File(uploadPath)),
              );
            }
          }
        }
      default:
        return (false, null);
    }
  } catch (e, st) {
    debugPrint('attemptSendPendingMessage: failed for ${item.id} ($e)');
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'attemptSendPendingMessage: failed for ${item.id} (type=${item.type})',
    );
    return (false, null);
  }
}

// Runs in a fresh, headless background isolate spawned by the OS
// (BGTaskScheduler on iOS, WorkManager on Android) — no ProviderScope/widget
// tree exists here, so this talks to a standalone LocalMessageStore
// directly instead of going through MessageSendController. One best-effort
// pass: for each chat, attempt its oldest queued item, and keep going
// through that chat's queue only while attempts keep succeeding — a
// failure stops that chat for this run (no backoff *wait* here; background
// execution windows are too short to spend on waiting, the next periodic
// run or the next app foreground is the retry).
Future<void> processPendingQueueOnce() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final prefs = await SharedPreferences.getInstance();
  final store = LocalMessageStore(prefs);
  await store.init();
  final firestoreService = FirestoreService();

  final byChat = <String, List<Message>>{};
  for (final item in store.allPending()) {
    final chatId = item.chatId;
    if (chatId == null) continue;
    // An item stuck 'uploading' means the app died mid-attempt last run —
    // we can't know if that upload actually landed, so treat it as
    // 'queued' again; the idempotent messageId makes re-attempting safe
    // either way.
    final normalized = item.localSendStatus == 'uploading'
        ? item.withLocalStatus(status: 'queued')
        : item;
    byChat.putIfAbsent(chatId, () => []).add(normalized);
  }

  for (final entry in byChat.entries) {
    final chatId = entry.key;
    final chatItems = entry.value
      ..sort((a, b) {
        final aTime = a.timestamp?.millisecondsSinceEpoch ?? 0;
        final bTime = b.timestamp?.millisecondsSinceEpoch ?? 0;
        return aTime.compareTo(bTime);
      });
    for (final item in chatItems) {
      if (item.localSendStatus != 'queued') continue;

      String? uploadedUrl;
      final (success, seq) = await attemptSendPendingMessage(
        item,
        firestoreService,
        onUploaded: (url) => uploadedUrl = url,
      );
      if (success && seq != null) {
        await store.markConfirmed(chatId: chatId, messageId: item.id, seq: seq);
        await deletePendingFile(item.localFilePath);
        continue;
      }

      final newAttemptCount = item.attemptCount + 1;
      if (newAttemptCount >= pendingQueueMaxAttempts) {
        await store.updatePendingStatus(
          chatId: chatId,
          messageId: item.id,
          status: 'failed',
          attemptCount: newAttemptCount,
          uploadedUrl: uploadedUrl,
        );
      } else {
        await store.updatePendingStatus(
          chatId: chatId,
          messageId: item.id,
          status: 'queued',
          attemptCount: newAttemptCount,
          uploadedUrl: uploadedUrl,
        );
      }
      // Stop processing the rest of this chat's queue for this run — the
      // next item must not jump ahead of one that just failed and is
      // awaiting its next attempt (same FIFO rule as the live controller).
      break;
    }
  }
  await store.flushPending();
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    await processPendingQueueOnce();
    return true;
  });
}
