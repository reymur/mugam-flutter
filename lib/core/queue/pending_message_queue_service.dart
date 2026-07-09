import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pending_media_message.dart';

// Disk persistence for the offline media-send queue: the queue's own
// metadata (shared_preferences, one JSON blob) and the actual pending files
// (copied into the app's Documents directory, NOT the OS-reclaimable temp
// directory, so a file waiting on a slow/offline retry cycle survives disk
// pressure cleanup).
class PendingMessageQueueService {
  PendingMessageQueueService(this._prefs);

  final SharedPreferences _prefs;

  static const String _queueKey = 'mugam_pending_queue_v1';
  static const String _pendingFilesDirName = 'pending_uploads';

  List<PendingMediaMessage> readAll() {
    final raw = _tryRead();
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => PendingMediaMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('PendingMessageQueueService: corrupted queue, clearing ($e)');
      _tryRemove();
      return [];
    }
  }

  Future<void> saveAll(List<PendingMediaMessage> items) async {
    try {
      await _prefs.setString(
        _queueKey,
        jsonEncode(items.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('PendingMessageQueueService: failed to save queue ($e)');
    }
  }

  // Copies the captured/recorded file (currently sitting in a temp
  // directory) into a durable location before it's handed to the queue —
  // by the time a retry actually fires the original temp file may already
  // be gone.
  Future<String> persistFile(String sourcePath, String localId) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final pendingDir = Directory('${docsDir.path}/$_pendingFilesDirName');
    if (!await pendingDir.exists()) {
      await pendingDir.create(recursive: true);
    }
    final ext = sourcePath.contains('.') ? sourcePath.split('.').last : 'dat';
    final destPath = '${pendingDir.path}/$localId.$ext';
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  // path is null for queue items with nothing to clean up (text messages
  // have no local file) — a plain no-op rather than making every caller
  // guard the call itself.
  Future<void> deleteFile(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('PendingMessageQueueService: failed to delete "$path" ($e)');
    }
  }

  String? _tryRead() {
    try {
      return _prefs.getString(_queueKey);
    } catch (e) {
      debugPrint('PendingMessageQueueService: failed to read queue ($e)');
      return null;
    }
  }

  Future<void> _tryRemove() async {
    try {
      await _prefs.remove(_queueKey);
    } catch (e) {
      debugPrint('PendingMessageQueueService: failed to remove queue key ($e)');
    }
  }
}
