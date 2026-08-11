/// ПОМЕТКИ МЕСЯЦА — цвет, три буквы имени и форма статуса.
///
/// Взято из макета `docs/design/mugam-8-teqvim.html` **дословно**, а не из
/// головы: первый заход шага 5 придумал переключатель «Hamısı | Müqavilələr»,
/// которого в макете нет вовсе, и был снят.
///
/// **ЧТО ГОВОРИТ МАКЕТ, значениями:**
///
///   • три буквы — ПЕРВЫЕ ТРИ буквы имени владельца, заглавными: `RAF`, `TEY`.
///     (В дневном списке аватарки берут ДВЕ — `TE`, `RA`, `AL`. Разные места,
///     разные правила, и путать их нельзя.)
///   • **залито — точно, рамка — под вопросом.** Заливка = цвет человека с
///     альфой 0.18; «под вопросом» = рамка 1.5px тем же цветом, без заливки;
///   • пустой день не помечен ничем.
///
/// **АРИФМЕТИКА СЧЁТА, проверенная на самом макете:** `Rafael 8` + `Teymur 6`
/// = 14 занятых, `Boş 17`, и 14 + 17 = 31 — все дни августа. **`Şübhəli 2` —
/// ПОДМНОЖЕСТВО, а не отдельная доля:** дни 4 и 11 нарисованы рамкой и
/// посчитаны и в людях, и в «под вопросом». Сложи их отдельно — выйдет 33 из
/// 31, то есть счёт соврёт на два дня.
library;

import '../../firebase/models.dart';

/// Форма пометки — то, чем «точно» отличается от «под вопросом».
enum DayMarkShape {
  /// Залито: вечер в силе.
  filled,

  /// Рамка: `unsettled` — под вопросом.
  outlined,
}

/// Пометка одного дня.
class DayMark {
  const DayMark({
    required this.ownerUid,
    required this.initials,
    required this.shape,
  });

  /// Чей вечер занял день. По нему берётся цвет — экран знает, кто «я», а
  /// правило нет и знать не должно.
  final String ownerUid;

  /// Три буквы имени владельца, заглавными.
  final String initials;

  final DayMarkShape shape;
}

/// Три буквы имени — правило одно на весь проект.
///
/// Короткое имя не дополняется ничем: «Əli» так и остаётся «ƏLİ», а
/// двухбуквенное — двумя буквами. Дополнять нечем, а придумывать третью букву
/// значит показать человеку имя, которого у него нет.
///
/// **Заглавные берутся по-турецки неверно, и это надо знать:** в Dart
/// `'i'.toUpperCase()` даёт `I`, а не `İ`. Для азербайджанского это чужая
/// буква. Поэтому `i` заменяется на `İ` явно — остальные буквы алфавита
/// (`ə`, `ç`, `ş`, `ğ`, `ö`, `ü`) переводятся верно сами.
String initialsOf(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '';
  final take = trimmed.length < 3 ? trimmed.length : 3;
  return trimmed.substring(0, take).replaceAll('i', 'İ').toUpperCase();
}

/// Что показать на дне — или `null`, если день пуст.
///
/// **Берётся ОДИН вечер, и это решение, а не упрощение.** В клетке помещаются
/// три буквы; при двух вечерах разных людей показать обоих нечем. Берётся
/// самый ранний по времени — тот же порядок, которым живёт список под сеткой,
/// так что клетка и список называют одного и того же человека.
///
/// **Отменённые сюда не доходят вовсе** — их выбрасывает `liveEvents` до
/// раскладки по дням. Здесь это не проверяется второй раз: два места, решающих
/// одно, разошлись бы молча.
DayMark? dayMarkOf(List<PersonalEvent> dayEvents, Map<String, String> names) {
  if (dayEvents.isEmpty) return null;
  final sorted = [...dayEvents]..sort((a, b) => a.date.compareTo(b.date));
  final first = sorted.first;
  // «Под вопросом» показывается, если ХОТЬ ОДИН вечер дня под вопросом:
  // рамка — предупреждение, и терять его из-за того, что рядом стоит целый
  // вечер, нельзя.
  final anyUnsettled = dayEvents.any((e) => e.status == 'unsettled');
  return DayMark(
    ownerUid: first.ownerUid,
    initials: initialsOf(names[first.ownerUid] ?? ''),
    shape: anyUnsettled ? DayMarkShape.outlined : DayMarkShape.filled,
  );
}

/// Строка счёта под сеткой.
class MonthTally {
  const MonthTally({
    required this.byOwner,
    required this.unsettledDays,
    required this.freeDays,
    required this.daysInMonth,
  });

  /// uid владельца → сколько ДНЕЙ он занял. Дни, а не вечера: два вечера
  /// одного человека в один день — это один занятый день.
  final Map<String, int> byOwner;

  /// Сколько дней под вопросом. **Подмножество [byOwner]** — эти дни уже
  /// посчитаны в нём (см. арифметику макета в шапке файла).
  final int unsettledDays;

  final int freeDays;
  final int daysInMonth;

  /// Занятых дней всего. Отдельным именем, потому что на нём стоит сверка:
  /// занятые плюс свободные обязаны дать все дни месяца.
  int get busyDays => byOwner.values.fold(0, (a, b) => a + b);
}

/// Счёт по месяцу из уже готовых пометок: день → пометка.
MonthTally monthTally({
  required Map<int, DayMark> marks,
  required int daysInMonth,
}) {
  final byOwner = <String, int>{};
  var unsettled = 0;
  for (final m in marks.values) {
    byOwner[m.ownerUid] = (byOwner[m.ownerUid] ?? 0) + 1;
    if (m.shape == DayMarkShape.outlined) unsettled++;
  }
  return MonthTally(
    byOwner: byOwner,
    unsettledDays: unsettled,
    freeDays: daysInMonth - marks.length,
    daysInMonth: daysInMonth,
  );
}
