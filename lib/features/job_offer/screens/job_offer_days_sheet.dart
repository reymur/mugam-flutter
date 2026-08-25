import 'package:flutter/material.dart';

import '../../../core/job_offer/day_details.dart';
import '../../../core/job_offer/offer_draft.dart';
import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';
import '../busy_days.dart';

// ЛИСТ ВЫБОРА ДНЕЙ — макет `docs/design/mugam-14-secim`, положен 14.08.
//
// Он ЗАМЕНЯЕТ прежнюю редакцию: автор посмотрел её на трубке и назвал три
// вещи неверными — заголовок занимал место зря, сетка была тусклой, три
// пустых поля висели внизу всегда. Все три сняты.
//
// ТРИ ЯРУСА, из них двигается один:
//   ВЕРХ (закреплён)    — месяц со стрелками и подписи дней недели. Без
//                         заголовка: он не сообщал ничего, чего не видно;
//   СЕРЕДИНА (крутится) — сетка, строка «N gün · …», строка последнего
//                         тапнутого дня и его детали;
//   НИЗ (закреплён)     — выбор типа работы и «Göndər».
//
// СВОЙ НЕПРОЗРАЧНЫЙ ФОН ОБЯЗАТЕЛЕН: точка вызова открывает лист прозрачным
// (так было заведено под прежний лист, рисовавший себя сам). Без заливки
// сквозь лист видна переписка — снято с устройства 14.08.
//
// ДЕТАЛИ У КАЖДОГО ДНЯ СВОИ. Общих полей нет вовсе, и это главное отличие
// от прежней редакции: раньше одно время уходило на все пять вечеров.

/// Типы работы. Три из макета плюс «Digər» со своим полем.
///
/// **ЗАМЕР ПРОДА 14.08** (`personalEvents`, 91 документ, без типа ноль):
/// различных типов **два** — `Toy` 89, `Konsert` 2. `Məclis` не встречается
/// ни разу. То есть трёх кнопок хватает с запасом, а «Digər» нужен не ради
/// частоты, а ради того, чтобы человек с нестандартным поводом мог вообще
/// отправить предложение.
const List<String> kOfferTypes = ['Toy', 'Konsert', 'Məclis'];

class JobOfferDaysSheet extends StatefulWidget {
  const JobOfferDaysSheet({
    super.key,
    required this.onSend,
    this.initialMonth,
    this.busyDays = const {},
    this.busyUnknown = false,
    this.initialDates = const [],
    this.now,
    this.onRecordVoice,
    this.onDiscardVoiceFiles,
  });

  /// Отдаёт набор дней, тип и детали КАЖДОГО дня. Лист сам ничего не пишет:
  /// запись — дело хода, у которого своё правило.
  final void Function({
    required List<String> dates,
    required String eventType,
    required Map<String, DayDetails> details,
  })
  onSend;

  /// Записать голос для дня. Возвращает запись либо `null`, если человек
  /// передумал. Сеанс записи общий (`VoiceRecordingSession`), и лист про
  /// него ничего не знает — только просит.
  final Future<DayDetails?> Function(String isoDay)? onRecordVoice;

  /// Удалить временные файлы записей: лист закрыт без отправки, и записи
  /// обязаны пропасть.
  final void Function(Set<String> paths)? onDiscardVoiceFiles;

  final DateTime? initialMonth;

  /// Свои занятые дни. **ВИДНЫ, НО ВЫБРАТЬ ИХ МОЖНО** — приложение помнит и
  /// показывает, решает человек: две работы в один вечер бывают законны.
  ///
  /// **ПОДКЛЮЧЕНО 25.08**, вместе с листом ответа и по тому же доводу
  /// владельца: работодатель набирал дни так же вслепую, как музыкант их
  /// отмечал. Поставщик общий — `busyDaysProvider`
  /// (`features/job_offer/busy_days.dart`), передаётся из точки вызова
  /// (`job_offer_entry.dart`).
  final Set<String> busyDays;

  /// **ЗАНЯТОСТИ МЫ НЕ ЗНАЕМ — и лист обязан сказать это, а не промолчать.**
  ///
  /// Ровно тот же признак и ровно та же причина, что у листа ответа
  /// (`JobOfferAnswerSheet.busyUnknown`): пустая сетка утверждает «всё
  /// свободно», а из готового набора дней «мы не смотрели» не выводится.
  /// Умолчание `false` — виджет показывает то, что подали.
  final bool busyUnknown;

  final List<String> initialDates;

  /// «Сегодня» — прибивается снаружи только в тестах, иначе набор, тыкающий
  /// в конкретные числа, через неделю бьёт в прошлое и краснеет не потому,
  /// что код сломался.
  final DateTime? now;

  @override
  State<JobOfferDaysSheet> createState() => _JobOfferDaysSheetState();
}

class _JobOfferDaysSheetState extends State<JobOfferDaysSheet> {
  late DateTime _month =
      widget.initialMonth ??
      DateTime(DateTime.now().year, DateTime.now().month);
  late final Set<String> _picked = widget.initialDates.toSet();

  /// Детали по дням. **Источник правды — эта карта, а не контроллеры
  /// полей.** Контроллеры перезаполняются при смене дня; держи правду в
  /// них — вписанное 14-му перетекло бы на 20-й, и человек не заметил бы:
  /// поля выглядят одинаково.
  final Map<String, DayDetails> _details = {};

  /// Последний тапнутый день — тот, чью строку и детали видно. Всегда один.
  String? _openDay;

  bool _detailsOpen = false;
  bool _sent = false;

  String _type = kOfferTypes.first;
  bool _customType = false;

  final _customTypeController = TextEditingController();
  final _timeController = TextEditingController();
  final _locationController = TextEditingController();
  final _dressController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (_picked.isNotEmpty) {
      final first = _picked.toList()..sort();
      _selectDay(first.first, initial: true);
    }
  }

  @override
  void dispose() {
    // ЗАКРЫЛ ЛИСТ, НЕ ОТПРАВИВ — ЗАПИСИ ПРОПАДАЮТ, И ЭТО ПРАВИЛЬНО.
    //
    // Удаляем явно, а не надеемся на систему: iOS чистит временную папку
    // когда сочтёт нужным, и файл может пролежать неделю. Запись без
    // предложения найти и удалить потом будет нечем.
    if (!_sent) {
      widget.onDiscardVoiceFiles?.call(voiceFilesIn(_details));
    }
    _customTypeController.dispose();
    _timeController.dispose();
    _locationController.dispose();
    _dressController.dispose();
    super.dispose();
  }

  static const _weekdayLabels = ['B.e', 'Ç.a', 'Ç', 'C.a', 'C', 'Ş', 'B'];

  /// Смена показанного дня: детали читаются ИЗ КАРТЫ в контроллеры.
  ///
  /// «Ətraflı» раскрывается сразу, если у дня что-то вписано — человек
  /// видит вписанное без лишнего нажатия. Пустой день приходит свёрнутым.
  void _selectDay(String iso, {bool initial = false}) {
    final d = _details[iso] ?? const DayDetails();
    _openDay = iso;
    _timeController.text = d.time;
    _locationController.text = d.location;
    _dressController.text = d.dress;
    _detailsOpen = d.isNotEmpty;
    if (!initial) setState(() {});
  }

  /// Запись контроллеров обратно в карту — до всякой смены дня.
  void _stashOpenDay() {
    final iso = _openDay;
    if (iso == null) return;
    final was = _details[iso] ?? const DayDetails();
    _details[iso] = was.copyWith(
      time: _timeController.text.trim(),
      location: _locationController.text.trim(),
      dress: _dressController.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final canSend = canSendOffer(dates: _picked, eventType: _effectiveType);

    return Container(
      height: media.size.height * 0.92,
      decoration: const BoxDecoration(
        color: kBg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: kMuted.withAlpha(90),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _monthHeader(),
                  const SizedBox(height: 6),
                  _weekdayRow(),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 4,
                  bottom: media.viewInsets.bottom + 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _grid(),
                    // ЗАНЯТОСТЬ — СРАЗУ ПОД СЕТКОЙ, до строки выбора: она про
                    // то, что в сетке нарисовано, а не про то, что человек уже
                    // набрал.
                    //
                    // ВЗАИМНО ИСКЛЮЧАЮЩИЕ, и не случайно: первая говорит
                    // «занятые дни выбирать можно», вторая — «занятых дней мы
                    // не знаем». Показать обе разом значило бы сказать про одно
                    // и то же два разных.
                    if (_busyVisibleThisMonth) ...[
                      const SizedBox(height: 12),
                      const Text(
                        kBusyPickableLine,
                        key: ValueKey('offer-busy-pickable'),
                        style: TextStyle(color: kMuted, fontSize: 12),
                      ),
                    ] else if (widget.busyUnknown &&
                        widget.busyDays.isEmpty) ...[
                      const SizedBox(height: 12),
                      const Text(
                        kBusyUnknownLine,
                        key: ValueKey('offer-busy-unknown'),
                        style: TextStyle(color: kMuted, fontSize: 12),
                      ),
                    ],
                    if (_picked.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        offerSummaryLine(_picked),
                        key: const ValueKey('offer-summary'),
                        style: const TextStyle(
                          color: kGold,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (_openDay != null) ...[
                      const SizedBox(height: 12),
                      _dayLine(_openDay!),
                      if (_detailsOpen) _dayFields(_openDay!),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: kBorder)),
              ),
              child: Column(
                children: [
                  _typePicker(),
                  const SizedBox(height: 12),
                  _sendButton(canSend),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _effectiveType =>
      _customType ? _customTypeController.text.trim() : _type;

  Widget _monthHeader() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      IconButton(
        key: const ValueKey('offer-month-prev'),
        icon: const Icon(Icons.chevron_left, color: kMuted),
        onPressed: () =>
            setState(() => _month = DateTime(_month.year, _month.month - 1)),
      ),
      Text(
        '${azMonthFull(_month.month)} ${_month.year}',
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      IconButton(
        key: const ValueKey('offer-month-next'),
        icon: const Icon(Icons.chevron_right, color: kMuted),
        onPressed: () =>
            setState(() => _month = DateTime(_month.year, _month.month + 1)),
      ),
    ],
  );

  Widget _weekdayRow() => Row(
    children: _weekdayLabels
        .map(
          (l) => Expanded(
            child: Center(
              child: Text(
                l,
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
            ),
          ),
        )
        .toList(),
  );

  Widget _grid() {
    final days = monthGridDays(_month);
    return Column(
      children: List.generate(
        6,
        (week) => Row(
          children: List.generate(
            7,
            (i) => Expanded(child: _dayCell(days[week * 7 + i])),
          ),
        ),
      ),
    );
  }

  /// Видно ли на ПОКАЗАННОМ месяце хоть один занятый день.
  ///
  /// **Не `busyDays.isNotEmpty`:** занятость приходит на весь календарь сразу,
  /// и пояснение «занятые дни тоже можно выбрать» на месяце, где не покрашено
  /// ни одной клетки, объясняло бы то, чего человек не видит.
  ///
  /// У листа ответа гейт другой — пересечение с предложенными днями, — и это
  /// не разнобой: там сетка ограничена днями предложения, здесь месяцем. Гейт
  /// отвечает на один и тот же вопрос («видит ли человек занятое прямо
  /// сейчас»), а видит он в двух листах разное.
  bool get _busyVisibleThisMonth =>
      monthGridDays(_month).any((d) => widget.busyDays.contains(isoDay(d)));

  // ЦВЕТА ВЗЯТЫ ИЗ МАКЕТА, А НЕ ПОДОБРАНЫ НА ГЛАЗ. Занятый день там —
  // rgba(111,168,220,0.16), и это ровно `kOwnerOther` (0xFF6FA8DC), уже
  // живущий в палитре как «чужой владелец». Берётся ИМЕНЕМ, а не числом:
  // уедет палитра — уедет и здесь, а число осталось бы старым (N66).
  Widget _dayCell(DateTime day) {
    final inMonth = day.month == _month.month;
    final iso = isoDay(day);
    final past = isPastDay(day, now: widget.now);
    final picked = _picked.contains(iso);
    final busy = widget.busyDays.contains(iso);
    final hasDetails = (_details[iso] ?? const DayDetails()).isNotEmpty;
    final selectable = inMonth && !past;

    return GestureDetector(
      key: ValueKey('offer-cell-$iso'),
      onTap: selectable ? () => _tapDay(iso) : null,
      child: Container(
        height: 40,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: picked
              ? kGold
              : (busy ? kOwnerOther.withAlpha(41) : Colors.transparent),
          borderRadius: BorderRadius.circular(9),
          border: _openDay == iso && !picked
              ? Border.all(color: kGold, width: 1.5)
              : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: picked ? FontWeight.w500 : FontWeight.normal,
                // Прошлые и чужие месяцы приглушены, НО ЧИТАЕМЫ: человек
                // должен понимать, где он в месяце. Оттенок берётся от
                // `kMuted` прозрачностью, а не новым числом.
                color: picked
                    ? kOnGold
                    : (!inMonth || past ? kMuted.withAlpha(120) : Colors.white),
              ),
            ),
            // Карандаш в углу — у дня что-то вписано. Единственный признак,
            // по которому видно детали, не открывая день.
            if (hasDetails)
              Positioned(
                top: 2,
                right: 4,
                child: Icon(
                  // 9 пикселей из макета на трубке почти не видно — сказано
                  // владельцем 14.08 после прогона. Макет рисовался на
                  // экране шире телефонного, и размер оттуда переносить
                  // нельзя буквально.
                  Icons.edit,
                  size: 13,
                  color: picked ? kOnGold : kGold,
                  key: ValueKey('offer-pen-$iso'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Тап по дню делает ДВА дела: выбирает/снимает и открывает его строку.
  ///
  /// Снятие выбора НЕ стирает вписанное: человек мог ткнуть мимо. Детали
  /// снятого дня остаются в карте и уйдут только с отправкой, где берутся
  /// детали лишь выбранных.
  /// Тап по дню — ТРИ разных исхода, и различает их не день, а его
  /// состояние.
  ///
  ///   не выбран            → выбрать и открыть его строку;
  ///   выбран, но НЕ открыт → просто открыть, НЕ снимая;
  ///   выбран и открыт      → снять.
  ///
  /// ВТОРОЙ ИСХОД ЗАВЕДЁН ПОСЛЕ ТОГО, КАК ТЕСТ УПЁРСЯ В ДЫРУ ЗАМЫСЛА.
  /// Прежде тап всегда переключал выбор, и вернуться к деталям уже
  /// выбранного дня было НЕЧЕМ: тапнул 14-е, чтобы посмотреть вписанное, —
  /// и снял его с предложения. Человек при этом видит, что день погас, но
  /// не понимает, что заодно ушёл и его час с местом.
  ///
  /// Снять день по-прежнему можно, и это ровно один лишний тап: сперва
  /// открыть, потом снять. Цена мала, а прежнее поведение стоило бы тихой
  /// потери вписанного.
  void _tapDay(String iso) {
    _stashOpenDay();
    final isPicked = _picked.contains(iso);

    if (isPicked && _openDay != iso) {
      _selectDay(iso);
      return;
    }

    if (!isPicked) {
      setState(() => _picked.add(iso));
      _selectDay(iso);
      return;
    }

    // СНЯЛИ ДЕНЬ — ЕГО СТРОКА ОБЯЗАНА УЙТИ (найдено на трубке 14.08).
    //
    // Прежняя редакция оставляла внизу «14 avqust» с микрофоном и
    // «Ətraflı» после того, как 14-е уже снято с сетки. Экран показывал два
    // разных ответа на один вопрос: сетка говорила «этот день не выбран»,
    // строка под ней — «мы сейчас про этот день». Хуже того, микрофон в
    // такой строке записал бы голос дню, которого в предложении нет.
    //
    // Строка переходит на ПОСЛЕДНИЙ ОСТАВШИЙСЯ выбранный день, а если не
    // осталось ни одного — исчезает вовсе.
    //
    // ВПИСАННОЕ НЕ СТИРАЕТСЯ: человек мог ткнуть мимо и вернуть день
    // обратно. Детали живут в карте и уходят только с отправкой, где
    // берутся детали лишь выбранных дней.
    setState(() => _picked.remove(iso));
    final rest = _picked.toList()..sort();
    if (rest.isEmpty) {
      setState(() {
        _openDay = null;
        _detailsOpen = false;
      });
      return;
    }
    _selectDay(rest.last);
  }

  /// Строка последнего тапнутого дня: «14 avqust · 🎤 · Ətraflı».
  ///
  /// МИКРОФОН СТОИТ ЗДЕСЬ, СНАРУЖИ «Ətraflı», И ЭТО НЕ УКРАШЕНИЕ. Голос —
  /// быстрый путь: сказать словами быстрее, чем вписать время, место и
  /// одежду. Спрячь его внутрь — и до него станет два касания из свёрнутого
  /// состояния, то есть быстрый путь станет длиннее медленного.
  Widget _dayLine(String iso) {
    final d = DateTime.tryParse(iso);
    final label = d == null
        ? iso
        : '${d.day} ${azMonthFull(d.month).toLowerCase()}';
    final has = (_details[iso] ?? const DayDetails()).voicePath != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: kGold.withAlpha(120), width: 1.5),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          GestureDetector(
            key: ValueKey('offer-mic-$iso'),
            onTap: () => _recordFor(iso),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: has ? kGold : kGoldDim,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.mic, size: 20, color: has ? kOnGold : kGold),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            key: ValueKey('offer-details-toggle-$iso'),
            onTap: () {
              _stashOpenDay();
              setState(() => _detailsOpen = !_detailsOpen);
            },
            child: Row(
              children: [
                const Text(
                  'Ətraflı',
                  style: TextStyle(color: kGold, fontSize: 14),
                ),
                Icon(
                  _detailsOpen ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: kGold,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _recordFor(String iso) async {
    final rec = await widget.onRecordVoice?.call(iso);
    if (rec == null || !mounted) return;
    setState(() {
      final was = _details[iso] ?? const DayDetails();
      _details[iso] = was.copyWith(
        voicePath: rec.voicePath,
        voiceWaveform: rec.voiceWaveform,
      );
    });
  }

  Widget _dayFields(String iso) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 10),
      _field('SAAT', _timeController, key: 'offer-time', dayField: true),
      const SizedBox(height: 9),
      _field(
        'YER',
        _locationController,
        key: 'offer-location',
        dayField: true,
      ),
      const SizedBox(height: 9),
      _field('GEYİM', _dressController, key: 'offer-dress', dayField: true),
      if (_picked.length > 1) ...[
        const SizedBox(height: 10),
        GestureDetector(
          key: const ValueKey('offer-copy-all'),
          onTap: () => _askCopyToAll(iso),
          child: const Text(
            'Bütün günlərə köçür',
            style: TextStyle(color: kGold, fontSize: 14),
          ),
        ),
      ],
    ],
  );

  /// Копирование СПРАШИВАЕТ, И ВОПРОС НАЗЫВАЕТ ЧИСЛО.
  ///
  /// «Bu detallar 4 günə köçürüləcək. Davam?» — человек видит цифру ДО
  /// нажатия. Кнопка, которая молча меняет четыре дня, хуже вопроса: отказ
  /// без объяснения непонятнее самого вопроса.
  Future<void> _askCopyToAll(String iso) async {
    _stashOpenDay();
    final n = copyTargetCount(selectedDays: _picked, fromDay: iso);
    if (n == 0) return;

    // СПРАШИВАЕМ ТОЛЬКО ТОГДА, КОГДА ЕСТЬ ЧТО ЗАТИРАТЬ (решение автора
    // 14.08). Молчаливая замена ПУСТОГО — не потеря: человек ничего не
    // вписывал, терять нечего, и вопрос защищал бы от того, чего не
    // случилось.
    //
    // А вопрос, у которого ответ «нет» не имеет смысла, приучает жать «да»
    // не читая — и следующий, настоящий, человек проскочит тоже.
    if (_overwriteCount(iso) == 0) {
      setState(() => _applyCopy(iso));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBg3,
        content: Text(
          'Bu detallar $n günə köçürüləcək. Davam?',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Xeyr', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            key: const ValueKey('offer-copy-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Bəli', style: TextStyle(color: kGold)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _applyCopy(iso));
  }

  void _applyCopy(String iso) {
    final next = copyDetailsToDays(
      details: _details,
      fromDay: iso,
      selectedDays: _picked,
    );
    _details
      ..clear()
      ..addAll(next);
  }

  /// Сколько выбранных дней ПОТЕРЯЮТ вписанное, если скопировать сюда.
  ///
  /// Считается не «сколько дней тронем», а «сколько дней лишатся своего»:
  /// поле у источника заполнено И у дня оно тоже заполнено, но другим.
  /// Совпадающие значения не считаются — там ничего не меняется.
  int _overwriteCount(String from) {
    final src = _details[from];
    if (src == null || src.isEmpty) return 0;
    var n = 0;
    for (final day in _picked) {
      if (day == from) continue;
      final was = _details[day];
      if (was == null || was.isEmpty) continue;
      final loses =
          (src.time.isNotEmpty && was.time.isNotEmpty && was.time != src.time) ||
          (src.location.isNotEmpty &&
              was.location.isNotEmpty &&
              was.location != src.location) ||
          (src.dress.isNotEmpty &&
              was.dress.isNotEmpty &&
              was.dress != src.dress) ||
          (src.voicePath != null &&
              was.voicePath != null &&
              was.voicePath != src.voicePath);
      if (loses) n += 1;
    }
    return n;
  }

  /// [dayField] — поле принадлежит ДНЮ, а не листу.
  ///
  /// Такое поле складывается в карту деталей **на каждом нажатии клавиши**,
  /// а не при уходе с дня. Иначе карта отстаёт от экрана, и всё, что по ней
  /// считается, врёт до следующего тапа: карандаш в клетке не появляется,
  /// «Ətraflı» у дня с текстом открывается свёрнутым, копирование берёт
  /// вчерашнее. Поймано тестом, а не глазами.
  Widget _field(
    String label,
    TextEditingController controller, {
    required String key,
    bool dayField = false,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: kBorder),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: kMuted,
            fontSize: 11,
            letterSpacing: 1.2,
          ),
        ),
        TextField(
          key: ValueKey(key),
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 15),
          onChanged: (_) {
            if (dayField) _stashOpenDay();
            setState(() {});
          },
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: '—',
            hintStyle: TextStyle(color: kMuted.withAlpha(120)),
          ),
        ),
      ],
    ),
  );

  /// Тип работы — ВЫБОРОМ, а не пустым полем: три частых плюс «Digər».
  Widget _typePicker() => Column(
    children: [
      Row(
        children: [
          for (final t in kOfferTypes)
            Expanded(
              child: _typeButton(
                label: t,
                on: !_customType && _type == t,
                onTap: () => setState(() {
                  _customType = false;
                  _type = t;
                }),
                key: ValueKey('offer-type-$t'),
              ),
            ),
          Expanded(
            child: _typeButton(
              label: 'Digər',
              on: _customType,
              onTap: () => setState(() => _customType = true),
              key: const ValueKey('offer-type-other'),
            ),
          ),
        ],
      ),
      if (_customType) ...[
        const SizedBox(height: 9),
        _field('NÖV', _customTypeController, key: 'offer-type-custom'),
      ],
    ],
  );

  Widget _typeButton({
    required String label,
    required bool on,
    required VoidCallback onTap,
    required Key key,
  }) => GestureDetector(
    key: key,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: on ? kGold : Colors.transparent,
        border: Border.all(color: on ? kGold : kBorder),
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(color: on ? kOnGold : kMuted, fontSize: 14),
        ),
      ),
    ),
  );

  Widget _sendButton(bool canSend) => Opacity(
    opacity: canSend ? 1 : 0.4,
    child: GestureDetector(
      key: const ValueKey('offer-send-days'),
      onTap: canSend ? _send : null,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: kGold,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Göndər',
          style: TextStyle(
            color: kOnGold,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );

  void _send() {
    _stashOpenDay();
    _sent = true;
    final days = _picked.toList()..sort();
    // Уходят детали ТОЛЬКО выбранных дней: снятый день мог остаться в карте
    // со вписанным, и тащить его в предложение значило бы отправить день,
    // которого в наборе нет.
    final details = <String, DayDetails>{
      for (final d in days)
        if ((_details[d] ?? const DayDetails()).isNotEmpty) d: _details[d]!,
    };
    widget.onSend(dates: days, eventType: _effectiveType, details: details);
  }
}
