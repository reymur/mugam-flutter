import 'package:flutter/material.dart';

import '../../core/time/az_date_format.dart';
import '../../firebase/models.dart';

// Предупреждение о занятом времени — ОДИН виджет на оба места, где оно
// показывается: лист «İş təklif et» (job_offer_date_sheet.dart) и окно
// создания/правки мероприятия в календаре (agreements_screen.dart).
//
// Почему общий, а не по копии на экран. Это третий общий кусок между
// этими двумя окнами, после формы одежды (event_notes_picker.dart) и
// самого диалога конфликта (event_conflict_dialog.dart), и причина та же:
// вопрос у человека один и тот же, откуда бы он в него ни пришёл. Копии
// расходятся молча — ровно так календарь и остался с однострочным
// предупреждением через эмодзи ⚠️, когда лист уже переделали на две
// строки, и заметил это владелец глазами, а не код.
//
// ---------------------------------------------------------------------------
// ЦВЕТА — почему свои, а не `kRed` с прозрачностью
// ---------------------------------------------------------------------------
// Фон обоих окон почти чёрный (`kBg2` = 0xFF131009), а сам `kRed`
// (0xFFC0392B) — тёмная кирпичная краска. Прежняя заливка `kRed`
// прозрачностью 22 давала панель, неотличимую от фона, а подпись
// `kRed.withAlpha(200)` на ней была нечитаема — замечено владельцем на
// устройстве 03.08 («немножко черноватая, не очень читабельно»).
//
// Осветлять прозрачностью здесь нечего в принципе: она смешивает с ЧЁРНЫМ
// фоном, то есть чем «легче» альфа, тем ближе к фону, а не к белому.
// Поэтому взяты явные светлые тона.
//
// Разделение ролей: заголовок красный — это предупреждение; строка
// мероприятия почти белая и крупная — это факт, который надо прочитать, а
// не сигнал тревоги. Красным по чёрному фактические данные читаются хуже
// всего, и именно эта строка на устройстве не читалась.
const Color kWarnBg = Color(0x33C0392B);
const Color kWarnBorder = Color(0x99C0392B);
const Color kWarnTitle = Color(0xFFF08A7A);
const Color kWarnHint = Color(0xFFDDA79E);
const Color kWarnFact = Color(0xFFE9D9D3);
const Color kWarnIconBg = Color(0x59C0392B);

/// Строка мероприятия внутри предупреждения. Крупная и почти белая:
/// прежние 12,5 пункта приходилось разглядывать, а прочитать её нужно
/// одним взглядом — это единственное место, где сказано, ЧЕМ занято время.
const TextStyle kWarnFactStyle = TextStyle(
  color: kWarnFact,
  fontSize: 15,
  fontWeight: FontWeight.w700,
  height: 1.25,
);

/// «Toy · 17:20 · Bakı» — из того, что у мероприятия вообще заполнено.
/// Пустые части не оставляют висящих разделителей.
String eventConflictSummary(PersonalEvent e) => [
  if (e.type.isNotEmpty) e.type,
  if (fmtEventTime(e.date).isNotEmpty) fmtEventTime(e.date),
  if (e.location.isNotEmpty) e.location,
].join(' · ');

// ---------------------------------------------------------------------------
// ЛОГИКА КОНФЛИКТА — тоже общая, а не только вид
// ---------------------------------------------------------------------------
// Требование владельца 03.08: «пусть будет одно и то же в обоих местах».
// Одного общего виджета для этого мало — он отвечает лишь за то, КАК
// плашка выглядит, а разойтись экраны могут в том, КОГДА она появляется и
// что считается конфликтом. Ровно так они и разошлись в прошлый раз:
// лист предупреждал живьём при выборе времени, а календарь молчал до
// самого сохранения, и заметить это можно было только глазами.
//
// Поэтому здесь лежат и правила: что считать занятым, в каком порядке
// показывать и когда запрет снимается.

bool sameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Все мероприятия на выбранный ДЕНЬ, по возрастанию времени.
///
/// [excludeEventId] — мероприятие, которое сейчас правят: само с собой оно
/// конфликтовать не может. Нужно календарю (там правят существующее) и не
/// нужно листу предложения (он всегда создаёт новое).
///
/// Отменённые не считаются: договор со статусом `cancelled` времени
/// человека уже не занимает, и предупреждать о нём значило бы держать день
/// занятым навсегда.
///
/// ДЕДУП ПО ID ОБЯЗАТЕЛЕН, и он здесь, а не у вызывающего. Владелец
/// числится и в собственном массиве участников, поэтому его мероприятия
/// приходят ОБОИМИ потоками — «свои» и «где я участник», — и склеенный
/// список содержит каждое дважды.
///
/// Наблюдалось на устройстве 03.08: на одну и ту же дату календарь
/// показывал «6 tədbiriniz var», а лист предложения — «3», ровно вдвое.
/// Лист дедуплицировал у себя, календарь склеивал списки как есть
/// (`[...personalEvents, ...eventsAsParticipant]`, три места в
/// `agreements_screen.dart`).
///
/// Чинится именно тут, а не в календаре: правило обязано давать один и тот
/// же ответ, что бы ему ни передали. Иначе следующий экран, собравший
/// список так же, разойдётся с остальными — и опять молча, потому что
/// дубль не ошибка, а просто неверное число.
List<PersonalEvent> conflictEventsOnDay(
  DateTime when,
  List<PersonalEvent> events, {
  String? excludeEventId,
}) {
  final out = <({PersonalEvent event, DateTime at})>[];
  final seen = <String>{};
  for (final e in events) {
    if (e.id == excludeEventId) continue;
    if (!seen.add(e.id)) continue;
    if (e.date.isEmpty) continue;
    if (e.status == 'cancelled') continue;
    try {
      final d = DateTime.parse(e.date);
      if (sameCalendarDay(d, when)) out.add((event: e, at: d));
    } catch (_) {
      continue;
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out.map((x) => x.event).toList();
}

/// Совпадение с точностью до минуты.
PersonalEvent? exactConflictAt(
  DateTime when,
  List<PersonalEvent> events, {
  String? excludeEventId,
}) {
  for (final e in conflictEventsOnDay(when, events,
      excludeEventId: excludeEventId)) {
    try {
      final d = DateTime.parse(e.date);
      if (d.hour == when.hour && d.minute == when.minute) return e;
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// Что показать при текущем выборе — или `null`, если показывать нечего.
class ConflictBannerSpec {
  const ConflictBannerSpec({
    required this.title,
    required this.detail,
    required this.events,
  });

  final String title;
  final String detail;
  final List<PersonalEvent> events;
}

/// Случаи не равнозначны: прошлая дата старше всего, затем собственный
/// запрет человека, затем точное совпадение минуты, и последним занятый
/// день — точное совпадение говорит больше.
///
/// [blockedTime] — время, которое человек сам объявил занятым, ответив
/// «Yeni tədbir» на ТОЧНОЕ совпадение минуты. Запрета на целый день нет:
/// «Yeni tədbir» при занятом лишь дне просто сохраняет — два мероприятия
/// в одну дату это обычная жизнь (решение владельца 03.08).
ConflictBannerSpec? resolveConflictBanner({
  required DateTime selectedDate,
  required List<PersonalEvent> events,
  DateTime? blockedTime,
  String? excludeEventId,
  bool pastDate = false,
}) {
  // Прошлая дата — раньше всех остальных случаев: при ней нельзя ни
  // сохранить, ни отправить, и говорить в этот момент про занятость
  // значило бы называть не ту причину отказа.
  //
  // До 03.08 про прошлую дату человек узнавал только после нажатия
  // «отправить», всплывающей строчкой, а в календаре не узнавал вовсе.
  // Теперь предупреждение живое, как и остальные.
  if (pastDate) {
    return const ConflictBannerSpec(
      title: 'Keçmiş tarix seçilə bilməz',
      detail: 'Zəhmət olmasa gələcək bir vaxt seçin',
      events: <PersonalEvent>[],
    );
  }

  final onDay = conflictEventsOnDay(selectedDate, events,
      excludeEventId: excludeEventId);
  final exact = exactConflictAt(selectedDate, events,
      excludeEventId: excludeEventId);

  if (isConflictTimeBlocked(selectedDate, blockedTime)) {
    return ConflictBannerSpec(
      title:
          '${blockedTime!.hour.toString().padLeft(2, '0')}:'
          '${blockedTime.minute.toString().padLeft(2, '0')} artıq məşğuldur',
      detail: 'Zəhmət olmasa başqa vaxt seçin',
      events: exact != null ? [exact] : const <PersonalEvent>[],
    );
  }
  if (exact != null) {
    return ConflictBannerSpec(
      title: 'Bu vaxtda sizin tədbiriniz var',
      detail: '',
      events: [exact],
    );
  }
  if (onDay.isNotEmpty) {
    // Занятый день — то, чего в листе не было видно вовсе: совпадение
    // минута в минуту в жизни почти не случается, мешает второй тədbir в
    // тот же день.
    return ConflictBannerSpec(
      title: onDay.length == 1
          ? 'Bu gün sizin tədbiriniz var'
          : 'Bu gün sizin ${onDay.length} tədbiriniz var',
      detail: '',
      events: onDay,
    );
  }
  return null;
}

bool isConflictTimeBlocked(DateTime selected, DateTime? blockedTime) =>
    blockedTime != null &&
    selected.hour == blockedTime.hour &&
    selected.minute == blockedTime.minute;


/// Плашка предупреждения о конфликте.
///
/// [title] — «что не так», [detail] — необязательная подпись «что делать».
/// [events] — мероприятия, о которых предупреждение и говорит; каждое
/// открывается через [onOpenEvent]. Пустой список допустим: тогда плашка
/// только предупреждает и ни на что не ведёт.
class EventConflictBanner extends StatelessWidget {
  const EventConflictBanner({
    super.key,
    required this.title,
    this.detail = '',
    this.events = const <PersonalEvent>[],
    this.onOpenEvent,
  });

  final String title;
  final String detail;
  final List<PersonalEvent> events;
  final void Function(PersonalEvent event)? onOpenEvent;

  @override
  Widget build(BuildContext context) {
    // Одно мероприятие — нажимается ВСЯ плашка, и стрелка одна, большая,
    // во всю её высоту. Несколько — плашка целиком не нажимается, у
    // каждого своя строка со своей стрелкой.
    //
    // Разводится это не ради красоты. Общая кнопка на всю панель при
    // нескольких мероприятиях обязана выбрать одно из них — то есть
    // угадать за человека. Это тот же класс, что B29 (галочки показывали
    // случайного участника, потому что бралось `firstWhere`), и цена та
    // же: ошибки не возникает нигде, просто открывается не то.
    final openable = onOpenEvent != null;
    final single = openable && events.length == 1;

    final panel = Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
      decoration: BoxDecoration(
        color: kWarnBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kWarnBorder),
      ),
      child: Row(
        crossAxisAlignment:
            single ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          // Значок в своём кружке, а не эмодзи внутри строки: эмодзи
          // уезжает вместе с переносом и теряет смысл отметки на полях.
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: kWarnIconBg,
              shape: BoxShape.circle,
            ),
            child: const Text('!', style: TextStyle(
              color: kWarnTitle,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              height: 1.1,
            )),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: kWarnTitle,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: kWarnHint,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ],
                if (single)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      eventConflictSummary(events.first),
                      style: kWarnFactStyle,
                    ),
                  )
                else
                  for (final e in events) _row(e, openable),
              ],
            ),
          ),
          if (single) ...[
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, size: 34, color: kWarnTitle),
          ],
        ],
      ),
    );

    if (!single) return panel;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onOpenEvent!(events.first),
      child: panel,
    );
  }

  /// Строка мероприятия — для случая, когда их несколько, либо когда
  /// переход не задан вовсе (тогда без стрелки и без нажатия).
  ///
  /// Нажимается вся строка, не одна стрелка: попасть в мелкую цель на ходу
  /// трудно, а промах здесь ничего не портит — экран мероприятия
  /// открывается и закрывается без последствий.
  Widget _row(PersonalEvent e, bool openable) {
    final line = Row(
      children: [
        Expanded(child: Text(eventConflictSummary(e), style: kWarnFactStyle)),
        if (openable) ...[
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, size: 26, color: kWarnTitle),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: openable
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onOpenEvent!(e),
              child: line,
            )
          : line,
    );
  }
}
