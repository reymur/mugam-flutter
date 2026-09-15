/// ГОЛОС ПРИЧИНЫ ВЫХОДА НА ДИСКЕ — читаем SDK-ом, ПО ПРАВУ, а не по ссылке
/// (N232, шаг 2; решение владельца 15.09).
///
/// **Зачем это вообще.** До 15.09 показ открывал `voiceUrl` из документа
/// вечера, а в той ссылке лежит `firebaseStorageDownloadTokens` — и по ней
/// файл отдаётся **кому угодно и без входа** (замер 15.09: анонимный запрос
/// 200 и 141 981 байт; тот же путь без `token=` — 403). Шаг 1 сузил правило
/// чтения, но ссылку не тронул: правило отнимает право, а ссылка ходит мимо
/// права. Шаг 2 убирает саму ссылку из дороги к файлу.
///
/// **Ссылка из документа при показе больше НЕ читается ни разу.** Адрес в
/// хранилище выводится из `eventId` и `uid` (`leaveNoteVoicePath`), то есть
/// из того, что показу и так известно. Поле `voiceUrl` остаётся — его
/// продолжают писать и старые сборки, и наша, — но служит оно теперь только
/// признаком «голос есть», а не дорогой к байтам.
///
/// **ЧЕГО ЗДЕСЬ НЕТ НАРОЧНО: отката на `voiceUrl`, если скачать не удалось.**
/// Такой откат вернул бы ровно то, что шаг 2 убирает, и делал бы это тихо —
/// в единственном случае, когда никто не смотрит (ошибка сети). Не
/// скачалось — голос не играет, ровно как и сегодня при обрыве связи.
library;

import 'dart:io';

import 'leave_note.dart';

/// Скачивание одного файла из хранилища на диск. Отдельным типом, чтобы
/// сюда не приезжал Firebase: настоящую дорогу даёт `FirestoreService`, а
/// тесты — счётчик вызовов.
typedef LeaveNoteVoiceDownload =
    Future<void> Function({required String storagePath, required File dest});

/// Скачанные причины на диске: один файл на пару «вечер + человек».
class LeaveNoteVoiceStore {
  const LeaveNoteVoiceStore({required this.download, required this.cacheDir});

  final LeaveNoteVoiceDownload download;

  /// Куда кладём. Временная папка телефона — та же, куда пишет запись голоса
  /// и сжатие медиа, и та самая, которую сносит уборка при смене учётки
  /// (`core/media/media_cache_cleanup.dart`). Своей уборки здесь нет НАРОЧНО:
  /// второй сторож того же места разошёлся бы с первым.
  final Future<Directory> Function() cacheDir;

  /// Отдаёт файл причины, скачивая его только если его ещё нет.
  ///
  /// **Скачивание идёт в `.part` и переименовывается в конце.** Иначе обрыв
  /// посреди загрузки оставил бы обрезанный файл, который `exists()` считает
  /// годным, — и причина играла бы огрызком ВСЕГДА, без способа заметить это
  /// (правка бы не помогла: файл на месте, значит не качаем). Класс тот же,
  /// что у «пустого вывода, прочитанного как хорошая новость» (I14).
  Future<File> voiceFile({
    required String eventId,
    required String uid,
  }) async {
    final dir = await cacheDir();
    final name = leaveNoteVoiceFileName(eventId: eventId, uid: uid);
    final file = File('${dir.path}/$name');
    if (await file.exists() && await file.length() > 0) return file;

    final part = File('${file.path}.part');
    if (await part.exists()) await part.delete();
    try {
      await download(
        storagePath: leaveNoteVoicePath(eventId: eventId, uid: uid),
        dest: part,
      );
      if (!await part.exists() || await part.length() == 0) {
        throw StateError(
          'причина выхода: скачивание $name не оставило файла — '
          'пустой результат нельзя отдавать проигрывателю как годный',
        );
      }
      return await part.rename(file.path);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }
}
