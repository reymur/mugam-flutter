// ЧЕРНОВИК ПРЕДЛОЖЕНИЯ — то, что человек набрал в листе до отправки.
//
// Вынесено из листа по той же причине, что и таблица действий у карточки
// (I32): решение «можно ли отправлять» и строка «что именно отправляем»
// внутри `build()` непроверяемы, а здесь у них тесты.

/// Дни месяца для сетки: сам месяц плюс хвосты соседних, чтобы недели были
/// полными. Неделя начинается с понедельника — как в макете
/// `mugam-10-secim` (B.e · Ç.a · Ç · C.a · C · Ş · B).
List<DateTime> monthGridDays(DateTime month) {
  final first = DateTime(month.year, month.month, 1);
  // `weekday`: 1 — понедельник, 7 — воскресенье. Отступ до понедельника.
  final lead = first.weekday - 1;
  final start = first.subtract(Duration(days: lead));
  // Шесть недель покрывают любой месяц: 31 день, начавшийся в воскресенье,
  // занимает 37 клеток. Пять недель (35) для такого месяца не хватило бы, и
  // последние дни ушли бы за край молча.
  return List.generate(42, (i) => DateTime(start.year, start.month, start.day + i));
}

String isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Строка под сеткой: «5 gün · 9, 10, 11, 12, 15».
///
/// **Человек должен видеть, что отправляет, ДО нажатия.** Сетка показывает
/// выбор пятнами по месяцу, и пересчитать их глазами — работа; строка
/// называет и число, и сами дни.
///
/// Дни идут по возрастанию независимо от того, в каком порядке их тыкали:
/// «9, 15, 10» читалось бы как ошибка ввода.
String offerSummaryLine(Iterable<String> isoDates) {
  final sorted = isoDates.toList()..sort();
  if (sorted.isEmpty) return '';
  final days = sorted.map((iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? iso : '${d.day}';
  }).join(', ');
  return '${sorted.length} gün · $days';
}

/// Можно ли отправлять.
///
/// **ВРЕМЯ, МЕСТО И ЗАМЕТКА НЕОБЯЗАТЕЛЬНЫ, И ЭТО НЕ ПОСЛАБЛЕНИЕ.** «Много
/// дат — деталей обычно нет: договариваются только о днях, а время говорят
/// за день-два голосом. Одна дата — детали обычно есть сразу»
/// (`docs/plan.md`). Потребуй их — и предложение на пять дней отправить
/// станет нельзя, то есть запретим ровно тот случай, ради которого работа и
/// делалась.
///
/// Обязательны ровно двое: хотя бы один день и тип работы.
bool canSendOffer({required Iterable<String> dates, required String eventType}) {
  return dates.isNotEmpty && eventType.trim().isNotEmpty;
}

/// Прошлые дни выбирать нельзя — тот же запрет, что и у прежнего листа
/// (N91), только теперь он про каждый день набора, а не про один.
bool isPastDay(DateTime day, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final d = DateTime(day.year, day.month, day.day);
  return d.isBefore(DateTime(today.year, today.month, today.day));
}
