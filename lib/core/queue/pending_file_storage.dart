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

// Wipes the whole pending-uploads directory. Used on sign-out (see
// LocalMessageStore.clearAllForSignOut): the pending queue's own JSON blob
// is cleared at the same moment, so every file left here is by definition
// unreferenced from that point on — leaving them would strand the previous
// account's captured photos/videos/voice notes on the device indefinitely.
Future<void> deleteAllPendingFiles() async {
  try {
    final docsDir = await getApplicationDocumentsDirectory();
    final pendingDir = Directory('${docsDir.path}/$_pendingFilesDirName');
    if (await pendingDir.exists()) {
      await pendingDir.delete(recursive: true);
    }
  } catch (e, st) {
    debugPrint('deleteAllPendingFiles: failed ($e)');
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'deleteAllPendingFiles: failed',
    );
  }
}

// Удаляет файлы в pending_uploads/, на которые не ссылается ни одна
// запись очереди отправки (N2).
//
// Зачем нужна вообще, если течь заделана: сама течь (файл не удалялся
// при подтверждении на переднем плане) закрыта в `6175ac1`, но уже
// накопленное на устройствах никуда не делось — замер тогда показал 10
// файлов-сирот из 12, ~83 МБ у одного тестировщика и ~18 МБ у другого.
// Ни один существующий путь до них не дотягивается: удаление привязано к
// конкретной записи очереди, а у этих её нет.
//
// Та же форма, что у серверного сборщика сирот (functions/src/
// orphanSweep.ts), включая главное правило: **неполное знание не даёт
// права удалять**. Здесь оно означает, что список ссылок обязан быть
// полным до единого файла, поэтому вызывать это можно только после
// LocalMessageStore.init(), который поднимает в память записи всех чатов
// сразу, а не по мере открытия. Отсюда и требование к аргументу: это
// именно allPending(), а не пачка одного чата.
//
// Идемпотентна по построению: сверка ссылок, потом удаление.
//
// Окно ожидания — ровно по той же причине, что и у серверного сборщика:
// файл создаётся раньше записи о нём (persistPendingFile, потом
// insertPending), и между этими двумя моментами он выглядит ничьим.
// Здесь к этому добавляется фоновый изолят очереди: он может начать
// отправку в тот же момент, когда приложение читает список ссылок, — и
// тогда его свежий файл в этом списке ещё не значится. Час на порядки
// больше обоих зазоров.
const Duration _pendingFileGracePeriod = Duration(hours: 1);

Future<int> deleteUnreferencedPendingFiles(
  Iterable<String> referencedPaths,
) async {
  try {
    final docsDir = await getApplicationDocumentsDirectory();
    final pendingDir = Directory('${docsDir.path}/$_pendingFilesDirName');
    if (!await pendingDir.exists()) return 0;

    final referenced = referencedPaths.toSet();
    final now = DateTime.now();
    var deleted = 0;
    await for (final entity in pendingDir.list()) {
      if (entity is! File) continue;
      if (referenced.contains(entity.path)) continue;
      // Возраст не прочитался — считаем файл свежим: неизвестный возраст
      // не повод удалять.
      DateTime? modified;
      try {
        modified = (await entity.stat()).modified;
      } catch (_) {
        continue;
      }
      if (now.difference(modified) < _pendingFileGracePeriod) continue;
      try {
        await entity.delete();
        deleted++;
      } catch (e) {
        debugPrint('deleteUnreferencedPendingFiles: "${entity.path}" ($e)');
      }
    }
    if (deleted > 0) {
      debugPrint('deleteUnreferencedPendingFiles: удалено $deleted файлов');
    }
    return deleted;
  } catch (e, st) {
    debugPrint('deleteUnreferencedPendingFiles: failed ($e)');
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'deleteUnreferencedPendingFiles: failed',
    );
    return 0;
  }
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
