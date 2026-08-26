import 'package:flutter/material.dart';

import '../../../core/job_offer/job_offer.dart';
import '../../../core/job_offer/offer_draft.dart';
import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';
import '../busy_days.dart';
import '../widgets/busy_day_notice.dart';
import '../widgets/offer_month_grid.dart';

// ЭКРАН ОТВЕТА — приглашённый отмечает, на какие дни может.
//
// Открывается НАЖАТИЕМ на строку предложения в ленте, а не разворачивается
// в переписке (решение автора 14.08 после прогона): лента не забивается
// списками на двадцать дат, а человек, нажав, видит всё сразу и со своими
// занятыми днями.
//
// ОТДЕЛЬНЫЙ ЭКРАН, А НЕ ВЕТКА ЛИСТА СОСТАВЛЕНИЯ. Общая у них только сетка
// (`OfferMonthGrid`). Здесь нельзя тронуть ни дни предложения, ни тип, ни
// детали — правило это запрещает, и экран запрещает то же самое.

class JobOfferAnswerSheet extends StatefulWidget {
  const JobOfferAnswerSheet({
    super.key,
    required this.offer,
    required this.myUid,
    required this.initiatorName,
    required this.onSend,
    this.busy = const BusyDays.unknown(),
    this.onOpenBusyEvent,
    this.now,
    this.embedded = false,
  });

  final JobOffer offer;
  final String myUid;
  final String initiatorName;

  /// Отдаёт отмеченные дни. **Пустой список — законный ответ**, а не отказ
  /// от ответа.
  final void Function(List<String> picked) onSend;

  /// Своя занятость — ПРЕДУПРЕЖДЕНИЕ, не запрет: выбрать занятый день можно,
  /// решает человек.
  ///
  /// **ОДИН ОБЪЕКТ, А НЕ ТРИ ПОЛЯ РЯДОМ, и это не аккуратность.** Здесь
  /// стояли `busyDays` и `busyUnknown` по отдельности; с 25.08 к ним
  /// понадобились ещё и сами вечера — чтобы сказать, ЧЕМ занят день. Три поля
  /// рядом расходятся молча: набор говорит «занято», список вечеров пуст,
  /// признак говорит «не знаем» — и каждое выглядит правильным порознь.
  /// [BusyDays] держит их вместе, потому что они и есть один ответ.
  ///
  /// **УМОЛЧАНИЕ — «НЕ ЗНАЕМ», и это тоже правка 25.08.** Прежнее умолчание
  /// (пустой набор плюс `busyUnknown: false`) означало «мы посмотрели, у тебя
  /// всё свободно» — утверждение, которого никто не делал. Виджет, которому
  /// занятость не подали, обязан молчать о ней честно.
  final BusyDays busy;

  /// Открыть карточку вечера, занявшего день. `null` — открывать некуда, и
  /// тогда надпись про занятость не рисуется нажимаемой (правило «кнопка без
  /// адресата не рисуется», N146/I64).
  final void Function(String eventId)? onOpenBusyEvent;

  final DateTime? now;

  /// Встроен ли лист в чужое окно.
  ///
  /// `false` — лист сам себе модалка: несёт высоту, заливку, скругление и
  /// ручку. `true` — его рисует дверь предложения, и всё это уже есть у неё.
  final bool embedded;

  @override
  State<JobOfferAnswerSheet> createState() => _JobOfferAnswerSheetState();
}

class _JobOfferAnswerSheetState extends State<JobOfferAnswerSheet> {
  late final Set<String> _picked = widget.offer.pickedBy(widget.myUid).toSet();

  /// Последний нажатый день — тот, про который говорит надпись о занятости.
  /// **Не «выбранный»:** выбор здесь набор, а спрашивают всегда про один день.
  String? _openDay;
  late DateTime _month = _monthOfFirstDate();

  DateTime _monthOfFirstDate() {
    final dates = widget.offer.dates.toList()..sort();
    final first = dates.isEmpty ? null : DateTime.tryParse(dates.first);
    final now = widget.now ?? DateTime.now();
    return DateTime(first?.year ?? now.year, first?.month ?? now.month);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final offered = widget.offer.dates.toSet();

    final content = SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  // Ручка — только когда лист сам себе окно. Встроенный в
                  // дверь получает её от двери, и вторая была бы второй же
                  // копией одного украшения.
                  if (!widget.embedded) ...[
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
                  ],
                  Text(
                    azUpperCase(
                      '${widget.initiatorName} təklif edir · '
                      '${widget.offer.eventType}',
                    ),
                    style: const TextStyle(
                      color: kGold,
                      fontSize: 14,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _monthHeader(),
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
                    OfferMonthGrid(
                      month: _month,
                      picked: _picked,
                      busy: widget.busy.days,
                      // НАЖИМАЕМЫ ТОЛЬКО ПРЕДЛОЖЕННЫЕ ДНИ, ни одного
                      // лишнего. Требование автора и вторая половина
                      // правила `answerFitsOffer`.
                      selectable: offered,
                      // КАРАНДАШ НА ДНЯХ, КУДА ЧТО-ТО ВПИСАНО — 26.08, вместе
                      // с переездом подробностей сюда. Без него нажатие на
                      // день обещает одинаково, а показывает по-разному: у
                      // одного время и место, у другого «ничего не вписано».
                      withDetails: {
                        for (final e in widget.offer.details.entries)
                          if (e.value.isNotEmpty) e.key,
                      },
                      // КАРАНДАШ НА ДНЯХ, КУДА ЧТО-ТО ВПИСАНО — 26.08, вместе
                      // с переездом подробностей сюда. Без него нажатие на
                      // день обещает одинаково, а показывает по-разному: у
                      // одного время и место, у другого «ничего не вписано».
                      // Обведён тот день, о котором говорит надпись про
                      // занятость ниже: иначе «Bu gün məşğulsan» висит в
                      // воздухе и не называет, про какой день оно.
                      openDay: _openDay,
                      now: widget.now,
                      onTapDay: (iso) => setState(() {
                        if (!_picked.remove(iso)) _picked.add(iso);
                        _openDay = iso;
                      }),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _picked.isEmpty
                          ? 'Gələ bildiyin günləri seç'
                          : offerSummaryLine(_picked),
                      key: const ValueKey('answer-summary'),
                      // РАЗМЕР ПОДНЯТ 26.08 ПО ВИДУ НА ТРУБКЕ, вместе со всем
                      // текстом под сеткой. Кегль равен заголовку в виде
                      // ответа (18): это одна и та же строка по смыслу —
                      // «что сейчас выбрано», — и в двух местах она обязана
                      // весить одинаково.
                      style: TextStyle(
                        color: _picked.isEmpty ? kMuted : kGold,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    // ПОДРОБНОСТИ НАЖАТОГО ДНЯ — переехали сюда 26.08 с
                    // промежуточной карточки, и это сняло последнее, что её
                    // держало.
                    //
                    // **ПОЧЕМУ КАРТОЧКУ НЕЛЬЗЯ БЫЛО УБРАТЬ РАНЬШЕ.** Решение
                    // владельца 20.08 звучало так: «подробности остаются жить
                    // ЗДЕСЬ… порядок „сперва читаю, что предлагают, потом
                    // отвечаю" — не лишнее нажатие, а сам смысл». Довод верен
                    // и не отменён: убери карточку тогда — музыкант отмечал бы
                    // дни, НЕ ЗНАЯ времени и места, а это не нехватка удобства,
                    // а неверный ответ. Замер 26.08 подтвердил цену:
                    // `grep -c "Ətraflı"` давал **2 в карточке и 0 здесь**.
                    //
                    // Теперь подробности здесь, и довод исполнен на том же
                    // экране, где отвечают, — а не этажом выше.
                    //
                    // **ТЕМ ЖЕ НАЖАТИЕМ, ЧТО И ВЫБОР, и второго жеста не
                    // заводится.** `_openDay` уже существовал: на нём висит
                    // врезка занятости ниже. День, нажатый последним, и есть
                    // тот, о котором говорят обе строки.
                    _dayDetails(),
                    // ЧЕМ ЗАНЯТ ТОЛЬКО ЧТО НАЖАТЫЙ ДЕНЬ. Цвет говорит
                    // «осторожно», надпись — «чем именно», и по ней
                    // открывается сам вечер.
                    //
                    // СТОИТ ПОСЛЕ ПОДРОБНОСТЕЙ, а не до: сперва чужое
                    // предложение, потом своё расписание. Человек читает, на
                    // что зовут, и лишь затем — что этому мешает.
                    BusyDayNotice(
                      events: _openDay == null
                          ? const []
                          : widget.busy.on(_openDay!),
                      onOpenEvent: widget.onOpenBusyEvent,
                    ),
                    if (_busyOfferedAhead(offered).isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        // Занятость — сведения, а не преграда. Сказано и на
                        // экране, чтобы человек не думал, будто ему не дают.
                        //
                        // Строка взята ИМЕНЕМ: та же самая стоит в листе
                        // набора дней, и две копии разошлись бы в первой же
                        // правке (N66).
                        //
                        // ЦВЕТ И РАЗМЕР ПОДНЯТЫ 25.08: владелец назвал строку
                        // нечитаемой на трубке — она стояла `kMuted` в 12
                        // пунктов. Пояснение к предупреждению обязано
                        // читаться, иначе предупреждение остаётся без
                        // объяснения и выглядит запретом.
                        kBusyPickableLine,
                        style: TextStyle(color: kWarnHint, fontSize: 15),
                      ),
                    ],
                    // ВЗАИМНО ИСКЛЮЧАЮЩЕ С ПРЕДЫДУЩЕЙ, И НЕ СЛУЧАЙНО: та
                    // говорит «занятые дни выбирать можно», эта — «занятых
                    // дней мы не знаем». Показать обе разом значило бы
                    // сказать про одно и то же два разных.
                    if (!widget.busy.known) ...[
                      const SizedBox(height: 8),
                      const Text(
                        kBusyUnknownLine,
                        key: ValueKey('answer-busy-unknown'),
                        style: TextStyle(color: kWarnHint, fontSize: 15),
                      ),
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
              child: _sendButton(),
            ),
          ],
        ),
      );

    // ВСТРОЕННЫЙ В ДВЕРЬ ЛИСТ НЕ НЕСЁТ СВОЕЙ ОБЁРТКИ (26.08).
    //
    // Высоту, заливку и скругление даёт дверь (`JobOfferSheet`); вторая копия
    // разошлась бы с первой при первой же правке — ровно то, чего избегали у
    // вида ответа.
    //
    // **Это переключатель ОФОРМЛЕНИЯ, а не задачи, и потому он законен
    // (I58).** Дело у обоих одно — отметить дни и отправить; расходятся они
    // лишь тем, окно это или часть окна. Переключателя вида «а этому не
    // отправлять» здесь нет ни одного.
    if (widget.embedded) return content;

    return Container(
      height: media.size.height * 0.92,
      decoration: const BoxDecoration(
        color: kBg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: content,
    );
  }

  /// Занятые дни ПРЕДЛОЖЕНИЯ, которые человек ещё может выбрать.
  ///
  /// **Прошедшие исключены, и это не мелочь.** С 25.08 сетка прошедшую
  /// занятость не заливает (решение владельца: заливка предупреждает о
  /// выборе, а на прошедшем дне выбора нет). Оставь здесь голое пересечение —
  /// и строка «занятые дни тоже можно выбрать» встала бы под сеткой, где не
  /// покрашено ни одной клетки. Случай не выдуманный: предложение с
  /// прошедшими датами в проекте есть и записано находкой N153.
  ///
  /// **«Сегодня» — то же `isPastDay` и тот же `widget.now`**, что у клетки;
  /// второго источника даты не заводится. Разбор строки нужен потому, что
  /// занятость приходит записью `2026-08-25`, а `isPastDay` спрашивает
  /// `DateTime`; нечитаемая строка сюда попасть не может — набор собран
  /// `isoDay`, — но ответ на неё дан явно: не показывать.
  Set<String> _busyOfferedAhead(Set<String> offered) => {
    for (final iso in widget.busy.days.intersection(offered))
      if (!(DateTime.tryParse(iso) == null ||
          isPastDay(DateTime.parse(iso), now: widget.now)))
        iso,
  };

  Widget _monthHeader() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      IconButton(
        key: const ValueKey('answer-month-prev'),
        icon: const Icon(Icons.chevron_left, color: kMuted),
        onPressed: () =>
            setState(() => _month = DateTime(_month.year, _month.month - 1)),
      ),
      Text(
        '${azMonthFull(_month.month)} ${_month.year}',
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      IconButton(
        key: const ValueKey('answer-month-next'),
        icon: const Icon(Icons.chevron_right, color: kMuted),
        onPressed: () =>
            setState(() => _month = DateTime(_month.year, _month.month + 1)),
      ),
    ],
  );

  /// КНОПКА ПРИ НУЛЕ МЕНЯЕТ ПОДПИСЬ, А НЕ ГАСНЕТ.
  ///
  /// «Heç birinə gələ bilmirəm» — «ни на один не могу». Ноль отмеченных дней
  /// это законный ОТВЕТ: отдельного отказа в этой работе нет, неотмеченные
  /// дни и значат «нет».
  ///
  /// Серая кнопка сказала бы обратное — что ответить отказом нельзя, — и
  /// человек, который не может ни на один день, остался бы без хода вовсе.
  /// Подпись при этом обязана меняться: «Göndər» при пустом наборе выглядит
  /// как «отправить ничего», и человек не нажмёт, побоявшись, что не понял.
  /// ПОДРОБНОСТИ НАЖАТОГО ДНЯ — время, место, одежда.
  ///
  /// **День без вписанного говорит об этом СЛОВОМ, а не пустотой.** Пустое
  /// место на экране, где только что был текст, читается как «не
  /// загрузилось», и человек ждёт. Строка «ничего не вписано» — ответ, и его
  /// видно.
  ///
  /// **Пустые поля внутри дня не рисуются вовсе:** строка «Yer —» обещала бы
  /// сведения, которых нет. Отсутствие поля и пустое поле здесь одно и то же
  /// — так их пишет `createOffer` (дни без единой подробности в карту не
  /// попадают).
  ///
  /// Ничего не нажато — пусто: говорить не о чем, и место под сеткой не
  /// занимается зря.
  Widget _dayDetails() {
    final iso = _openDay;
    if (iso == null) return const SizedBox.shrink();
    final d = widget.offer.details[iso];
    final rows = <(String, String)>[
      if (d != null && d.time.isNotEmpty) ('Saat', d.time),
      if (d != null && d.location.isNotEmpty) ('Yer', d.location),
      if (d != null && d.dress.isNotEmpty) ('Geyim', d.dress),
    ];

    return Container(
      key: const ValueKey('answer-day-details'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 11),
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: kGold.withAlpha(13),
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fmtEventDate(iso),
            key: const ValueKey('answer-day-details-title'),
            style: const TextStyle(
              color: kGold,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 7),
          if (rows.isEmpty)
            const Text(
              'Bu günə əlavə məlumat yoxdur',
              key: ValueKey('answer-day-details-empty'),
              style: TextStyle(color: kTextDim, fontSize: 14),
            )
          else
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 62,
                      child: Text(
                        r.$1,
                        style: const TextStyle(color: kMuted, fontSize: 15),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        r.$2,
                        style: const TextStyle(
                          color: kText,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _sendButton() => GestureDetector(
    key: const ValueKey('answer-send'),
    onTap: () => widget.onSend(_picked.toList()..sort()),
    child: Container(
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kGold,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _picked.isEmpty ? 'Heç birinə gələ bilmirəm' : 'Göndər',
        style: const TextStyle(
          color: kOnGold,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
