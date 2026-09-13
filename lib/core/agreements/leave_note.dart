/// ПРИЧИНА ВЫХОДА ИЗ ВЕЧЕРА — «почему не приду», сказанное при уходе.
///
/// **Решение владельца 13.09, окончательное:** причина хранится В САМОМ
/// ВЕЧЕРЕ, полем `leaveNotes.<uid>`, и показывается ТОЛЬКО ВЛАДЕЛЬЦУ. Чат для
/// хранения не нужен — ни заводить, ни искать. Прежнее решение 12.09
/// («сообщением в переписке двоих») отменено, пометка — `docs/handoff.md`.
///
/// **ОГРАНИЧЕНИЕ, СКАЗАННОЕ ПРЯМО:** документ вечера читают владелец и весь
/// состав (`isParty` в `firestore.rules`), включая вышедшего, а Firestore
/// отдаёт документ целиком. Значит «только владельцу» держится на ПОКАЗЕ —
/// на правиле [offersLeaveNote] ниже. Любой из состава достанет поле, обойдя
/// экран. Безопасно, пока состав — позванные владельцем люди.
///
/// **Текст и голос лежат РЯДОМ, одной картой**, как у голоса в деталях дня
/// предложения работы (`core/job_offer/day_details.dart`): строка, ссылка на
/// запись и волна. Файла на телефоне здесь нет — в вечер уходит только
/// ссылка на уже загруженную запись.
library;

import 'event_answers.dart';

/// Имя поля на документе вечера.
const String kLeaveNotesField = 'leaveNotes';

class LeaveNote {
  const LeaveNote({
    this.text = '',
    this.voiceUrl,
    this.voiceWaveform = const [],
  });

  final String text;

  /// Ссылка на запись в хранилище, `null` — голоса нет.
  final String? voiceUrl;

  /// Волна записи для показа. Без голоса смысла не имеет и не пишется.
  final List<int> voiceWaveform;

  /// Нечего сказать — ни слова, ни записи.
  ///
  /// Пробелы словом не считаются: поле, в котором человек нажал пробел и
  /// передумал, причиной не является.
  bool get isEmpty => text.trim().isEmpty && voiceUrl == null;

  Map<String, dynamic> toMap() => {
        if (text.trim().isNotEmpty) 'text': text.trim(),
        if (voiceUrl != null) 'voiceUrl': voiceUrl,
        if (voiceUrl != null && voiceWaveform.isNotEmpty)
          'voiceWaveform': voiceWaveform,
      };

  /// Разбор ОДНОЙ причины. `null` — причины нет либо она пустая.
  ///
  /// ЧТЕНИЕ ЗАЩИТНОЕ (I49): документ вечера правят ещё сервер мимо правил и
  /// рука в консоли, а падение здесь роняет не поле, а весь календарь —
  /// `fromFirestore` зовётся на каждый документ каждого потока. Чужой тип
  /// читается как отсутствие, и это законно ровно потому, что решается «что
  /// показать» (I47).
  static LeaveNote? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    final url = raw['voiceUrl'];
    final wave = raw['voiceWaveform'];
    final note = LeaveNote(
      text: text is String ? text : '',
      voiceUrl: url is String && url.isNotEmpty ? url : null,
      voiceWaveform: wave is List
          ? wave.whereType<num>().map((n) => n.toInt()).toList(growable: false)
          : const [],
    );
    return note.isEmpty ? null : note;
  }
}

/// Разбор всего поля. `null` — поля в документе НЕТ, `{}` — поле есть, но
/// причин в нём нет.
///
/// **Эти два ответа РАЗНЫЕ, и сведены быть не должны** (I47): правка
/// состава переписывает поле только там, где оно уже есть
/// ([leaveNotesForParticipants]), и `null` говорит ей «не трогай ключ вовсе».
Map<String, LeaveNote>? leaveNotesFromFirestore(Object? raw) {
  if (raw is! Map) return null;
  final out = <String, LeaveNote>{};
  raw.forEach((key, value) {
    if (key is! String || key.isEmpty) return;
    final note = LeaveNote.fromMap(value);
    if (note != null) out[key] = note;
  });
  return out;
}

/// Запись выхода — ОДНОЙ записью ответ и причина.
///
/// **Одной, а не двумя**: сорвись вторая, человек вышел бы без причины,
/// которую написал, и не узнал бы об этом; сорвись первая — причина лежала
/// бы о выходе, которого не было.
///
/// Пустая причина ключа не заводит: не написал и не сказал — владелец
/// получает только выход, ничего за человека не выдумывается.
///
/// Возвращается карта, а не пишется в Firestore: правило должно быть
/// проверяемо тестом (тот же приём, что у `eventEditUpdate`).
Map<String, dynamic> leaveEventUpdate({
  required String uid,
  required LeaveNote? note,
}) =>
    {
      'answers.$uid': kAnswerLeft,
      if (note != null && !note.isEmpty)
        '$kLeaveNotesField.$uid': note.toMap(),
    };

/// Показывать ли «?» и причину у строки вышедшего.
///
/// **ТОЛЬКО ВЛАДЕЛЬЦУ** (решение 13.09): остальной состав видит красное имя и
/// «İşdən çıxdı» без знака — кто не придёт, знать должны все, почему — нет.
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

/// Причины после правки состава — только тех, кто в составе ОСТАЛСЯ.
///
/// Нужна крестику: он убирает вышедшего из `musicians` и `answers` разом, и
/// причина обязана уйти вместе с ними, иначе удалённый оставил бы в
/// документе вечера слова, которые больше некому показывать.
///
/// `null` — поля в документе не было, и правка его не заводит.
Map<String, dynamic>? leaveNotesForParticipants(
  List<String> participantUids,
  Map<String, LeaveNote>? previous,
) {
  if (previous == null) return null;
  return {
    for (final uid in participantUids)
      if (previous[uid] case final LeaveNote note) uid: note.toMap(),
  };
}
