// Азербайджанские названия месяцев и разбор ISO-строки события в
// показываемые дату и время.
//
// Вынесено из agreements_screen.dart, когда лист предложения работы
// (job_offer/screens/job_offer_date_sheet.dart) начал показывать тот же
// диалог конфликта:
// иначе форматирование даты в диалоге зависело бы от того, из какого
// экрана его позвали, а расходиться такие копии умеют молча.
//
// Это НЕ отметка момента (N4): на вход идёт «плавающее» гражданское
// время события — тədbir в 20:00 остаётся в 20:00 там, где он проходит.
// Поэтому здесь нет ни `toLocal()`, ни приведения к UTC: строка
// разбирается как есть и показывается как есть.
const azMonthsFull = [
  'Yanvar', 'Fevral', 'Mart', 'Aprel', 'May', 'İyun',
  'İyul', 'Avqust', 'Sentyabr', 'Oktyabr', 'Noyabr', 'Dekabr',
];

String azMonthFull(int month) => azMonthsFull[month - 1];

/// ЗАГЛАВНЫЕ ПО-АЗЕРБАЙДЖАНСКИ — одно правило на всех, кто их делает.
///
/// В Dart `'i'.toUpperCase()` даёт латинскую `I`, а это ДРУГАЯ БУКВА: здесь
/// `i ↔ İ` и `ı ↔ I` — две разные пары. «İyun», переведённое обычным
/// `toUpperCase`, стало бы «IYUN», то есть словом с чужой буквой.
///
/// Заглавная `I` НЕ трогается: имя или слово, написанное через неё, уже
/// содержит именно её, и «исправить» её на `İ` значило бы переписать чужое
/// написание.
///
/// Вынесено 12.08, когда правило понадобилось второму читателю — заголовку
/// месяца в календаре; первым был `initialsOf` (три буквы имени на дне). Два
/// места, делающие одно, обязаны звать одну функцию (I23).
String azUpperCase(String s) => s.replaceAll('i', 'İ').toUpperCase();

/// `2026-08-08T19:00:00.000` → `8 Avqust 2026`.
/// Неразбираемая строка возвращается как есть, а не пустой: показать
/// сырое значение честнее, чем сделать вид, что даты нет.
String fmtEventDate(String iso) {
  if (iso.isEmpty) return '';
  try {
    final d = DateTime.parse(iso);
    return '${d.day} ${azMonthFull(d.month)} ${d.year}';
  } catch (_) {
    return iso;
  }
}

/// `2026-08-08T19:00:00.000` → `19:00`. Здесь, в отличие от даты,
/// неразбираемая строка даёт пустоту: сырой ISO на месте времени
/// выглядит поломкой, а не значением.
String fmtEventTime(String iso) {
  if (iso.isEmpty) return '';
  try {
    final d = DateTime.parse(iso);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  } catch (_) {
    return '';
  }
}

// Дни недели по-азербайджански. Нужны дневному экрану: он открывается
// строкой «5 avqust, çərşənbə» — дата словами, а не числом, потому что
// человек читает её в первую секунду и не должен переводить.
//
// Порядок совпадает с DateTime.weekday: 1 — понедельник, 7 —
// воскресенье. Индексируется `weekday - 1`.
const azWeekdays = [
  'bazar ertəsi',
  'çərşənbə axşamı',
  'çərşənbə',
  'cümə axşamı',
  'cümə',
  'şənbə',
  'bazar',
];

String azWeekday(int weekday) => azWeekdays[weekday - 1];

/// `2026-08-05` → `5 avqust, çərşənbə`. Строка-шапка дневного экрана.
String fmtDayHeader(DateTime day) =>
    '${day.day} ${azMonthFull(day.month).toLowerCase()}, ${azWeekday(day.weekday)}';

/// `2026-08-08` → `8 avqust`. Строка недельного списка: год не нужен —
/// все семь дней в пределах недели от сегодня.
String fmtWeekRowDate(DateTime day) =>
    '${day.day} ${azMonthFull(day.month).toLowerCase()}';
