/// ПРИЧИНА ВЫХОДА ИЗ ВЕЧЕРА — «почему не приду», сказанное при уходе.
///
/// **Решение владельца 13.09:** причина хранится при вечере и показывается
/// ТОЛЬКО ВЛАДЕЛЬЦУ. Чат для хранения не нужен — ни заводить, ни искать.
///
/// **С 17.09 — СВОИМ ДОКУМЕНТОМ, а не полем вечера:**
/// `personalEvents/{eventId}/leaveNotes/{uid}`, читают автор и владелец
/// (`firestore.rules`). Здесь стояло «полем `leaveNotes.<uid>` в документе
/// вечера, а "только владельцу" держится на показе» — и это было доказанно
/// нестандартно: *«It is impossible using security rules alone to prevent
/// users from reading specific fields within a document»*
/// (firebase.google.com/docs/firestore/security/rules-fields). Документ вечера
/// читает весь состав, и причину доставал любой из него, обойдя экран.
/// Разбор — `docs/plan.md`, «`leaveNotes` — отдельным заходом и первым».
///
/// **Путь документа совпадает с путём файла голоса** (`event_leave_notes/
/// {eventId}/{uid}`), и круг читателей у них один — автор и владелец.
///
/// **Текст и голос лежат РЯДОМ, одним документом**: строка, признак «голос
/// есть» и волна. Самого файла здесь нет — его адрес выводится из `eventId`
/// и `uid` ([leaveNoteVoicePath]).
library;

import 'event_answers.dart';

/// Имя подколлекции причин под документом вечера.
const String kLeaveNotesCollection = 'leaveNotes';

class LeaveNote {
  const LeaveNote({
    this.text = '',
    this.hasVoice = false,
    this.voiceWaveform = const [],
  });

  final String text;

  /// ЕСТЬ ЛИ ГОЛОС — признак, а не дорога к нему (N236, шаг 2, 16.09).
  ///
  /// **Здесь стояло `String? voiceUrl` — ссылка, выданная
  /// `getDownloadURL()`.** В такой ссылке лежит токен, и по ней файл отдаётся
  /// **кому угодно и без входа** (замер 15.09: анонимный запрос — 200, тот же
  /// путь без `token=` — 403). Адрес в хранилище выводится из `eventId` и
  /// `uid` ([leaveNoteVoicePath]), поэтому документ дороги к байтам не знает.
  ///
  /// **Имя взято от того, как вещь зовётся в МОДЕЛИ, а не в базе (I45).**
  final bool hasVoice;

  /// Волна записи для показа. Без голоса смысла не имеет и не пишется.
  final List<int> voiceWaveform;

  /// Нечего сказать — ни слова, ни записи.
  ///
  /// Пробелы словом не считаются: поле, в котором человек нажал пробел и
  /// передумал, причиной не является.
  bool get isEmpty => text.trim().isEmpty && !hasVoice;

  /// Документ причины. Ключи — ровно те, что пускает правило:
  /// `text`, `hasVoice`, `voiceWaveform`.
  Map<String, dynamic> toMap() => {
    if (text.trim().isNotEmpty) 'text': text.trim(),
    if (hasVoice) 'hasVoice': true,
    if (hasVoice && voiceWaveform.isNotEmpty) 'voiceWaveform': voiceWaveform,
  };

  /// Разбор ОДНОЙ причины. `null` — причины нет либо она пустая.
  ///
  /// ЧТЕНИЕ ЗАЩИТНОЕ (I49): документ правят ещё сервер мимо правил и рука в
  /// консоли, а падение здесь роняет показ состава. Чужой тип читается как
  /// отсутствие, и это законно ровно потому, что решается «что показать»
  /// (I47).
  ///
  /// **`voiceUrl` БОЛЬШЕ НЕ ЧИТАЕТСЯ — запасной ход снят 17.09.** Здесь стояло
  /// «старая форма со ссылкой тоже значит "голос есть"» — ради записей
  /// переходного периода N236. По закону стройки их не переносят, а стирают,
  /// и правило такую форму больше не пускает; держать чтение того, чего нет
  /// и быть не может, — держать дорогу для возврата ссылки.
  static LeaveNote? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    final wave = raw['voiceWaveform'];
    final note = LeaveNote(
      text: text is String ? text : '',
      hasVoice: raw['hasVoice'] == true,
      voiceWaveform: wave is List
          ? wave.whereType<num>().map((n) => n.toInt()).toList(growable: false)
          : const [],
    );
    return note.isEmpty ? null : note;
  }
}

/// Причины вечера из документов подколлекции: id документа — uid автора.
///
/// Пустые и нечитаемые пропускаются по правилу [LeaveNote.fromMap]. Документ
/// с пустым id не причина ничья — пропускается тоже.
Map<String, LeaveNote> leaveNotesFromDocs(
  Iterable<MapEntry<String, Object?>> docs,
) {
  final out = <String, LeaveNote>{};
  for (final doc in docs) {
    if (doc.key.isEmpty) continue;
    final note = LeaveNote.fromMap(doc.value);
    if (note != null) out[doc.key] = note;
  }
  return out;
}

/// Запись выхода — ПАЧКА ИЗ ДВУХ: ответ в документ вечера, причина — в свой.
///
/// **Одной пачкой, а не двумя записями**: сорвись вторая, человек вышел бы
/// без причины, которую написал, и не узнал бы об этом; сорвись первая —
/// причина лежала бы о выходе, которого не было. Здесь стояло «одной записью
/// в документ вечера»; после выноса причины в свой документ атомарность
/// держит пачка, а правило причины проверяет ответ ПОСЛЕ пачки (`getAfter`).
///
/// Пустая причина документа не заводит ([LeaveWrites.note] — `null`): не
/// написал и не сказал — владелец получает только выход.
///
/// Возвращаются карты, а не пишется в Firestore: правило должно быть
/// проверяемо тестом (тот же приём, что у `eventEditUpdate`).
class LeaveWrites {
  const LeaveWrites({required this.eventUpdate, required this.note});

  /// Обновление документа вечера — только свой ответ.
  final Map<String, dynamic> eventUpdate;

  /// Документ причины `leaveNotes/{uid}`; `null` — причины нет.
  final Map<String, dynamic>? note;
}

LeaveWrites leaveEventWrites({required String uid, required LeaveNote? note}) =>
    LeaveWrites(
      eventUpdate: {'answers.$uid': kAnswerLeft},
      note: note == null || note.isEmpty ? null : note.toMap(),
    );

/// Показывать ли «?» и причину у строки вышедшего.
///
/// **ТОЛЬКО ВЛАДЕЛЬЦУ** (решение 13.09): остальной состав видит красное имя и
/// «İşdən çıxdı» без знака — кто не придёт, знать должны все, почему — нет.
///
/// С 17.09 это уже не единственный замок: чужую причину участнику не отдаёт
/// сервер. Правило показа остаётся — оно решает, у какой строки и когда.
///
/// Не на самом себе и только у вышедшего: причина говорится про уход, и у
/// вернувшегося её показывать не о чем. Пустая причина знака не даёт — «?»,
/// раскрывающий пустоту, обещает то, чего нет.
///
/// Условие живёт здесь, а не в разметке, потому что его можно прогнать
/// тестом, а разметку — нет (I32).
bool offersLeaveNote({
  required String viewerUid,
  required String memberUid,
  required String ownerUid,
  required String? answer,
  required LeaveNote? note,
}) =>
    viewerUid.isNotEmpty &&
    memberUid.isNotEmpty &&
    viewerUid == ownerUid &&
    viewerUid != memberUid &&
    answer == kAnswerLeft &&
    note != null &&
    !note.isEmpty;

/// Запрашивать ли причины вечера вовсе — только владельцу.
///
/// **Не украшение, а условие работы запроса:** сервер отдаёт подколлекцию
/// запросом только владельцу вечера. Участник, пославший тот же запрос,
/// получил бы `permission-denied` — поток отказов на каждое открытие вечера.
bool requestsLeaveNotes({
  required String viewerUid,
  required String ownerUid,
}) => viewerUid.isNotEmpty && viewerUid == ownerUid;

/// Где лежит запись голоса причины — `event_leave_notes/{eventId}/{uid}`.
///
/// **СВОЯ ПАПКА, А НЕ ПАПКА ЧАТА — решение владельца 13.09, с доводом:**
/// голосовое в чате — сообщение переписки, у него свои правила, своё
/// удаление, свой показ; причина выхода — часть вечера. Одна корзина на две
/// разные вещи однажды унесёт причину вместе с чатом, а круги читателей у
/// чата и у вечера совпадают сегодня случайно.
///
/// Один файл на человека в вечере: повторная запись ложится на то же место.
String leaveNoteVoicePath({required String eventId, required String uid}) =>
    'event_leave_notes/$eventId/$uid';

/// Имя файла причины НА ДИСКЕ телефона — скачанная копия для проигрывания
/// (N232, шаг 2).
///
/// **Выводится из тех же двух значений, что и адрес в хранилище**, поэтому
/// хранить путь не нужно вовсе: `eventId` и `uid` и так известны показу.
///
/// Плоское имя, а не подпапки: уборка кэшей при смене учётки сносит
/// содержимое временной папки перечислением (`media_cache_cleanup.dart`), и
/// лишняя вложенность ей ничего не даёт.
String leaveNoteVoiceFileName({required String eventId, required String uid}) =>
    'leave_note_${eventId}_$uid.m4a';

/// Чьи причины удалить при правке состава — тех, кто из состава УБРАН.
///
/// Нужна крестику: он убирает вышедшего из `musicians` и `answers`, и его
/// причина обязана уйти той же пачкой, иначе удалённый оставил бы при вечере
/// слова, которые больше некому показывать.
///
/// **Здесь стояло `leaveNotesForParticipants` — правка ПЕРЕСОБИРАЛА причины
/// оставшихся через `toMap()`, и в этом жила N237:** сборка, не понимающая
/// формы, стирала причину, которой не касалась. Теперь правка причин
/// оставшихся не трогает вовсе — она только удаляет документы убранных, и
/// потерять чужую форму ей нечем.
///
/// Удаление несуществующего документа в Firestore — не ошибка, поэтому
/// список не сверяется с тем, у кого причина есть: читать ради этого незачем.
List<String> removedLeaveNoteUids({
  required List<String> previousParticipants,
  required List<String> participants,
}) {
  final kept = participants.toSet();
  return [
    for (final uid in previousParticipants)
      if (uid.isNotEmpty && !kept.contains(uid)) uid,
  ];
}
