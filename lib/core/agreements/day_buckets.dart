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

  /// Следующие семь дней после завтра — то есть окно «что впереди».
  ///
  /// **Семь дней вперёд, а НЕ до конца календарной недели** (решение
  /// владельца 07.08): «до субботы» означает, что в воскресенье экран
  /// пустеет при полном календаре. Музыканту нужно «что впереди», а не
  /// «что до выходных».
  final List<PersonalEvent> week;

  /// Ближайшее мероприятие ЗА пределами всех трёх окон — чтобы пустой
  /// экран мог сказать «следующее 9 сентября», а не просто «пусто».
  final PersonalEvent? next;

  bool get isEmpty =>
      today.isEmpty && tomorrow.isEmpty && week.isEmpty && next == null;
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
  final inWeek = <PersonalEvent>[];
  final later = <PersonalEvent>[];

  for (final e in byId.values) {
    final day = eventDay(e.date)!;
    if (day.isBefore(today)) continue; // прошедшее на дневном экране не место
    if (day == today) {
      inToday.add(e);
    } else if (day == tomorrow) {
      inTomorrow.add(e);
    } else if (!day.isAfter(weekEnd)) {
      inWeek.add(e);
    } else {
      later.add(e);
    }
  }

  int byTime(PersonalEvent a, PersonalEvent b) =>
      eventLocalDateTime(a.date)!.compareTo(eventLocalDateTime(b.date)!);

  inToday.sort(byTime);
  inTomorrow.sort(byTime);
  inWeek.sort(byTime);
  later.sort(byTime);

  return DayBuckets(
    today: inToday,
    tomorrow: inTomorrow,
    week: inWeek,
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
  if (b.week.isNotEmpty || b.next != null) return EmptyDayAnswer.freeBothDays;
  return EmptyDayAnswer.calendarEmpty;
}
