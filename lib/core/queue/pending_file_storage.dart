import 'dart:io';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

// Pure filesystem helpers for the pending-send retry path — split out from
// the old PendingMessageQueueService (which bundled these with its own
// SharedPreferences-backed queue metadata) since neither of these needs
// SharedPreferences at all, and both LocalMessageStore's callers and the
// WorkManager background isolate need them independent of any queue state.

const String _pendingFilesDirName = 'pending_uploads';

// Copies the captured/recorded file (currently sitting in a temp directory)
// into a durable location before it's handed to the send queue — by the
// time a retry actually fires the original temp file may already be gone.
Future<String> persistPendingFile(String sourcePath, String id) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final pendingDir = Directory('${docsDir.path}/$_pendingFilesDirName');
  if (!await pendingDir.exists()) {
    await pendingDir.create(recursive: true);
  }
  final ext = sourcePath.contains('.') ? sourcePath.split('.').last : 'dat';
  final destPath = '${pendingDir.path}/$id.$ext';
  await File(sourcePath).copy(destPath);
  return destPath;
}

// path is null for items with nothing to clean up (text messages have no
// local file) — a plain no-op rather than making every caller guard this.
Future<void> deletePendingFile(String? path) async {
  if (path == null) return;
  try {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  } catch (e, st) {
    debugPrint('deletePendingFile: failed to delete "$path" ($e)');
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'deletePendingFile: failed to delete "$path"',
    );
  }
}
