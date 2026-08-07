import '../../firebase/models.dart';
import '../time/event_local_time.dart';

/// Раскладка мероприятий по дням для главного экрана.
///
/// **Решение, из которого всё остальное следует:** главный экран — это
/// ДЕНЬ, а не витрина. Сегодня и завтра сверху, неделя ниже. Открыл —
/// увидел свой вечер за секунду, не листая.
///
/// Правило живёт здесь, а не в экране, по той же причине, по которой
/// туда уехали `agreementCardState` и `conflictEventsOnDay`: экран нельзя
/// проверить возвратом дешевле, чем функцию, а порченое правило внутри
/// `build` не видно ни одному тесту.
class DayBuckets {
  const DayBuckets({
    required this.today,
    required this.tomorrow,
    required this.week,
    required this.next,
  });

  /// Мероприятия сегодняшних суток, по времени.
  final List<PersonalEvent> today;

  /// Завтрашних.
  final List<PersonalEvent> tomorrow;

  /// Следующие семь дней после завтра — РОВНО СЕМЬ СТРОК, включая те, в
  /// которых ничего нет.
  ///
  /// **Семь дней вперёд, а НЕ до конца календарной недели** (решение
  /// владельца 07.08): «до субботы» означает, что в воскресенье экран
  /// пустеет при полном календаре. Музыканту нужно «что впереди», а не
  /// «что до выходных».
  ///
  /// **Список ДНЕЙ, а не мероприятий** — по макету
  /// (`docs/design/mugam-1-esas.html`): в нём есть строка «10 avqust —
  /// boş». Пустой день в списке мероприятий выразить нельзя вовсе: он
  /// там отсутствие элемента, а не элемент. Поэтому неделя — семь
  /// `DayRow`, и пустой день среди них такой же полноправный, как
  /// занятый.
  final List<DayRow> week;

  /// Ближайшее мероприятие ЗА пределами всех трёх окон — чтобы пустой
  /// экран мог сказать «следующее 9 сентября», а не просто «пусто».
  final PersonalEvent? next;

  /// В неделе нет НИ ОДНОГО мероприятия — состояние, названное отдельно.
  ///
  /// **Не собирается из семи пустых дней на месте применения** (решение
  /// владельца 07.08). Разница не косметическая: «этот день свободен» —
  /// сведение об одном дне, «впереди неделя пустая» — сведение о всей
  /// неделе, и отвечает экран на них по-разному. Семь строк «boş» подряд
  /// — это не ответ, а семикратно повторённое молчание.
  bool get weekHasNothing => week.every((d) => d.events.isEmpty);

  bool get isEmpty =>
      today.isEmpty && tomorrow.isEmpty && weekHasNothing && next == null;
}

/// Один день недельного списка. Пустой день — такой же элемент, как
/// занятый: без этого его нечем показать.
class DayRow {
  const DayRow({required this.day, required this.events});

  final DateTime day;
  final List<PersonalEvent> events;

  bool get isEmpty => events.isEmpty;
}

/// Собирает раскладку из двух потоков — своих мероприятий и тех, где
/// человек участник.
///
/// **Дедуп по `id` обязателен**, а не «на всякий случай»: хозяин попадает
/// в свой же список участников при некоторых способах создания, и без
/// дедупа один вечер показался бы дважды. То же правило и по той же
/// причине стоит в `conflictEventsOnDay`.
///
/// **Отменённые не показываются.** Отменённое мероприятие — не дело на
/// сегодня, а история; ему место в договорах, где видно, кто и когда
/// отменил.
///
/// **Мероприятие без разбираемой даты выбрасывается, а не падает в
/// «сегодня».** Иначе испорченная строка притворилась бы сегодняшним
/// вечером — то есть неправдой ровно на том экране, ради правдивости
/// которого всё это и делается.
DayBuckets buildDayBuckets({
  required List<PersonalEvent> own,
  required List<PersonalEvent> asParticipant,
  required DateTime now,
}) {
  final byId = <String, PersonalEvent>{};
  for (final e in [...own, ...asParticipant]) {
    if (e.status == 'cancelled') continue;
    if (eventDay(e.date) == null) continue;
    byId[e.id] = e;
  }

  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));
  // Граница окна «неделя»: семь суток после завтрашних, включительно.
  final weekEnd = tomorrow.add(const Duration(days: 7));

  final inToday = <PersonalEvent>[];
  final inTomorrow = <PersonalEvent>[];
  final later = <PersonalEvent>[];
  // Семь дней заводятся ЗАРАНЕЕ и пустыми, а не по мере находок: день без
  // мероприятий обязан оказаться в списке, а «добавить при первой
  // находке» его туда никогда не добавит.
  final weekDays = <DateTime, List<PersonalEvent>>{
    for (var i = 1; i <= 7; i++) tomorrow.add(Duration(days: i)): [],
  };

  for (final e in byId.values) {
    final day = eventDay(e.date)!;
    if (day.isBefore(today)) continue; // прошедшее на дневном экране не место
    if (day == today) {
      inToday.add(e);
    } else if (day == tomorrow) {
      inTomorrow.add(e);
    } else if (!day.isAfter(weekEnd)) {
      weekDays[day]!.add(e);
    } else {
      later.add(e);
    }
  }

  int byTime(PersonalEvent a, PersonalEvent b) =>
      eventLocalDateTime(a.date)!.compareTo(eventLocalDateTime(b.date)!);

  inToday.sort(byTime);
  inTomorrow.sort(byTime);
  later.sort(byTime);
  for (final list in weekDays.values) {
    list.sort(byTime);
  }

  final week = [
    for (final entry in weekDays.entries)
      DayRow(day: entry.key, events: entry.value),
  ]..sort((a, b) => a.day.compareTo(b.day));

  return DayBuckets(
    today: inToday,
    tomorrow: inTomorrow,
    week: week,
    next: later.isEmpty ? null : later.first,
  );
}

/// Что говорит экран, когда сегодня пусто.
///
/// **Пустой экран — это «сломалось». Ответ — это «я посмотрел, у тебя
/// свободно».** Поэтому состояний три, а не одно, и каждое называет не
/// отсутствие дел, а положение вещей.
enum EmptyDayAnswer {
  /// Сегодня свободно, но завтра есть: «Bu gün boşsunuz» — и завтрашнее
  /// сразу под ним.
  freeToday,

  /// Сегодня и завтра свободно, дальше что-то есть: «Bu gün və sabah
  /// boşsunuz» плюс строка про ближайшее.
  freeBothDays,

  /// Впереди нет вообще ничего: «Təqvim boşdur» и одно предложение
  /// действия. Одно, а не два — экран не торгуется с человеком.
  calendarEmpty,

  /// Сегодня есть дела — отвечать нечего.
  hasEventsToday,
}

EmptyDayAnswer emptyDayAnswer(DayBuckets b) {
  if (b.today.isNotEmpty) return EmptyDayAnswer.hasEventsToday;
  if (b.tomorrow.isNotEmpty) return EmptyDayAnswer.freeToday;
  if (!b.weekHasNothing || b.next != null) return EmptyDayAnswer.freeBothDays;
  return EmptyDayAnswer.calendarEmpty;
}
