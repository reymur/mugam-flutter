import 'package:flutter/material.dart';

import '../../../core/job_offer/day_details.dart';
import '../../../core/job_offer/job_offer.dart';
import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';
import 'offer_month_grid.dart';

// ОТВЕТ МУЗЫКАНТА, КАК ЕГО ЧИТАЮТ ОБЕ СТОРОНЫ.
//
// Пришло на смену `JobOfferAcceptSheet` 25.08, по макету владельца. Меняется
// не только вид: прежний экран был ЛИСТОМ ПРИЁМА — отдельной модалкой поверх
// карточки, открывавшейся кнопкой «Cavaba bax». Теперь это ВИД, который
// рисует сама дверь (`JobOfferSheet`), и промежуточной карточки между лентой
// и ответом больше нет.
//
// **ПОЧЕМУ ВИД, А НЕ ЛИСТ.** В `job_offer_sheet.dart` записан довод владельца
// от 22.08 против того, чтобы вести из ленты прямо в приём: тогда лист
// пришлось бы либо питать СНИМКОМ из ленты — и потерять живое обновление,
// ради которого делалась N143, — либо завести второй источник тех же данных.
// Довод не отменён, он **обойдён**: содержимое осталось за дверью, у живого
// потока. Своей обёртки — высоты, скруглений, ручки — у этого виджета нет
// намеренно: всё это уже есть у двери, и вторая копия разошлась бы с первой.
//
// --- ВТОРАЯ РЕДАКЦИЯ, 25.08: КАЛЕНДАРЬ ВЕРНУЛСЯ ---
//
// Первая редакция показывала согласованные дни отдельными квадратиками, без
// сетки месяца. Владелец поправил: **ответ должен приходить на тот же
// календарь, на котором предложение отправляли.** Человек узнаёт экран, и
// «31, 1» под одним заголовком больше не может обмануть — недели на месте.
//
// Сетка взята ОБЩАЯ (`OfferMonthGrid`), а не написана заново: у неё уже есть
// занятость, обводка открытого дня, карандаш подробностей и правило «ни
// одного лишнего дня нажимаемым». Ей дописаны ровно две вещи — красный ✕ для
// отказа и `allowPastTaps` (здесь дни ЧИТАЮТ, а не выбирают, и прошлое
// обязано открываться).
//
// --- ПОРЯДОК СВЕРХУ ВНИЗ ---
//
//   имя отвечавшего   — крупно. Прежде было мелкое серое «TEYMUR ORUCOV
//                       CAVAB VERDİ» в разрядку: имя и состояние делили одну
//                       строку и мешали друг другу;
//   месяц со стрелками — дни предложения могут лежать в двух месяцах, и без
//                       стрелок вторую половину не увидеть;
//   сетка месяца      — золотое «согласился», ✕ «не может», заливка «занят»;
//   СРЕДНИЙ БЛОК      — одно место на две вещи (см. ниже);
//   кнопки            — через увеличенный отступ.
//
// --- СРЕДНИЙ БЛОК: ОДНО МЕСТО, ДВЕ ВЕЩИ (владелец, 25.08) ---
//
// Пока день не открыт — итог ответа: «Gələ bilirəm», числа, «N gün · тип».
// Нажали согласованный день — НА ТОМ ЖЕ МЕСТЕ его подробности.
//
// **Подробности не выезжают снизу, и это решение, а не упрощение.**
// Выезжающий лист накрывает календарь, то есть прячет ровно то, к чему
// относится. Здесь календарь остаётся на виду, и у открытого дня стоит
// обводка — видно, чей это день.
//
// **У блока задан нижний предел высоты**, иначе кнопки прыгали бы при каждом
// переключении, а под ними — необратимое «Qəbul edirəm».

class OfferAnswerView extends StatefulWidget {
  const OfferAnswerView({
    super.key,
    required this.offer,
    required this.viewerUid,
    required this.recipientUid,
    required this.recipientName,
    this.busyDates = const {},
    this.onAccept,
    this.onWithdraw,
    this.onChangeAnswer,
    this.now,
  });

  final JobOffer offer;

  /// Чей это экран. Нужен ровно для одного: сказать отвечавшему «Sən», а не
  /// назвать его по имени в третьем лице (N141, I64).
  final String viewerUid;

  final String recipientUid;
  final String recipientName;

  /// Занятые дни СМОТРЯЩЕГО — заливкой на сетке.
  ///
  /// У каждого свои: предложивший видит свой календарь, отвечавший — свой.
  /// Показывать чужую занятость нельзя не из вежливости, а потому, что чужого
  /// календаря у нас на руках нет — это отдельная работа с отдельными
  /// разрешениями.
  final Set<String> busyDates;

  /// «Qəbul edirəm» — предложившему. Рисуется только вместе с
  /// `canAcceptAnswer`: принимать нечего и до ответа, и при ответе нулём
  /// дней, а кнопка, после которой не происходит ничего, обещала действие.
  final VoidCallback? onAccept;

  /// «Təklifi geri götür» — предложившему.
  final VoidCallback? onWithdraw;

  /// «Cavabı dəyiş» — отвечавшему. Переответ разрешён, пока раунд открыт.
  final VoidCallback? onChangeAnswer;

  /// Прибитое «сегодня» для теста — уходит в сетку.
  final DateTime? now;

  @override
  State<OfferAnswerView> createState() => _OfferAnswerViewState();
}

class _OfferAnswerViewState extends State<OfferAnswerView> {
  /// Показываемый месяц. Начинаем с того, где лежит ПЕРВЫЙ день предложения,
  /// а не с текущего: человек открыл ответ, чтобы увидеть ответ.
  late DateTime _month = _firstMonth();

  /// День, чьи подробности сейчас стоят в среднем блоке. `null` — там итог.
  String? _openDay;

  DateTime _firstMonth() {
    final sorted = widget.offer.dates.toList()..sort();
    for (final iso in sorted) {
      final d = DateTime.tryParse(iso);
      if (d != null) return DateTime(d.year, d.month);
    }
    final n = widget.now ?? DateTime.now();
    return DateTime(n.year, n.month);
  }

  Set<String> get _picked => widget.offer.pickedBy(widget.recipientUid).toSet();
  Set<String> get _declined =>
      widget.offer.declinedBy(widget.recipientUid).toSet();

  bool _hasDetails(String iso) =>
      widget.offer.details[iso]?.isNotEmpty ?? false;

  /// Согласованные дни, у которых есть что показать. Только они нажимаются:
  /// обещать «Ətraflı» над пустотой значит завести нажимаемое без адресата
  /// (N146), а карандаш на клетке говорит, у каких дней это есть.
  Set<String> get _readable => _picked.where(_hasDetails).toSet();

  bool get _viewerAnswered => widget.viewerUid == widget.recipientUid;

  /// Перелистывание месяца НЕ закрывает открытый день намеренно: он мог
  /// лежать в соседнем месяце, и захлопывать подробности из-за листания
  /// значило бы терять прочитанное на ровном месте.
  void _shiftMonth(int by) =>
      setState(() => _month = DateTime(_month.year, _month.month + by));

  @override
  Widget build(BuildContext context) {
    final picked = _picked;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _viewerAnswered ? 'Sən' : widget.recipientName,
            key: const ValueKey('answer-who'),
            style: const TextStyle(
              color: kText,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _viewerAnswered ? 'cavab verdin' : 'cavab verdi',
            style: const TextStyle(color: kMuted, fontSize: 12),
          ),

          const SizedBox(height: 10),
          _monthHeader(),
          const SizedBox(height: 4),
          OfferMonthGrid(
            month: _month,
            picked: picked,
            declined: _declined,
            busy: widget.busyDates,
            withDetails: _readable,
            // Нажимаются только те, у кого есть что показать.
            selectable: _readable,
            // Здесь дни ЧИТАЮТ, а не выбирают: подробности состоявшейся
            // работы должны открываться и на следующий день после неё.
            allowPastTaps: true,
            openDay: _openDay,
            onTapDay: (iso) => setState(() {
              // Тот же день второй раз — возврат к итогу.
              _openDay = _openDay == iso ? null : iso;
            }),
            now: widget.now,
          ),

          if (_readable.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'günə toxun → Ətraflı',
                key: ValueKey('answer-tap-hint'),
                style: TextStyle(color: kTextDim, fontSize: 11),
              ),
            ),
          ],

          const SizedBox(height: 13),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 112),
            padding: const EdgeInsets.only(top: 12),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: kBorder)),
            ),
            child: _openDay == null ? _summary(picked) : _details(_openDay!),
          ),

          // ОТСТУП ДО КНОПКИ — ВОЗДУХ, А НЕ УКРАШЕНИЕ (владелец, 25.08).
          // «Qəbul edirəm» необратима: она создаёт вечера. Палец не должен
          // попадать в неё сразу после чтения времени и места.
          const SizedBox(height: 28),
          ..._actions(),
        ],
      ),
    );
  }

  Widget _monthHeader() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      IconButton(
        key: const ValueKey('answer-month-prev'),
        icon: const Icon(Icons.chevron_left, color: kMuted),
        onPressed: () => _shiftMonth(-1),
      ),
      Text(
        '${azMonthFull(_month.month)} ${_month.year}',
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
      IconButton(
        key: const ValueKey('answer-month-next'),
        icon: const Icon(Icons.chevron_right, color: kMuted),
        onPressed: () => _shiftMonth(1),
      ),
    ],
  );

  /// ИТОГ — три строки по центру, в порядке, заданном владельцем: что
  /// сказал, про какие дни, сколько их.
  Widget _summary(Set<String> picked) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      // Строка согласия — только когда согласованные дни есть. При ответе
      // нулём («ни на один не могу») «Gələ bilirəm» рядом с пустотой
      // прочлось бы прямо наоборот.
      // РАЗМЕРЫ ПОДНЯТЫ 26.08 ПО ВИДУ НА ТРУБКЕ, вслед за подробностями и по
      // той же причине: числа брались из браузерного макета, где телефон
      // нарисован шире настоящего.
      //
      // Держатся В ПАРЕ С ПОДРОБНОСТЯМИ, потому что стоят на ОДНОМ И ТОМ ЖЕ
      // месте и сменяют друг друга: разойдись кегли — блок при каждом
      // переключении менял бы не только содержимое, но и вес.
      //   «Gələ bilirəm» 18 = заголовок дня в подробностях;
      //   числа          20 — крупнее всего в блоке: за ними сюда и смотрят;
      //   «N gün · тип»  15 = подпись поля в подробностях, самая тихая строка.
      if (picked.isNotEmpty) ...[
        const Text(
          'Gələ bilirəm',
          style: TextStyle(
            color: kGold,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _numbers(picked),
          key: const ValueKey('answer-picked-numbers'),
          style: const TextStyle(
            color: kText,
            fontSize: 20,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 6),
      ],
      Text(
        '${picked.length} gün · ${widget.offer.eventType}',
        key: const ValueKey('answer-total'),
        style: const TextStyle(color: kMuted, fontSize: 15),
      ),
    ],
  );

  /// ПОДРОБНОСТИ ОДНОГО ДНЯ — на месте итога. Пустые поля не рисуются вовсе:
  /// строка «Yer —» обещала бы сведения, которых нет.
  Widget _details(String iso) {
    final d = widget.offer.details[iso] ?? const DayDetails();
    final rows = <(String, String)>[
      if (d.time.isNotEmpty) ('Saat', d.time),
      if (d.location.isNotEmpty) ('Yer', d.location),
      if (d.dress.isNotEmpty) ('Geyim', d.dress),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // РАЗМЕРЫ ПОДНЯТЫ 26.08 ПО ВИДУ НА ТРУБКЕ — макет ошибся, и вот чем.
        //
        // Числа брались из браузерного макета один в один: заголовок 14,
        // строки 13. В макете телефон нарисован ШИРЕ НАСТОЯЩЕГО и смотрят на
        // него с расстояния монитора, поэтому мелкость там не читалась как
        // мелкость. На устройстве владелец назвал подробности нечитаемыми.
        //
        // **Признак на будущее: размер шрифта — единственное, что макет в
        // браузере проверить не может.** Всё остальное — порядок, цвет,
        // состав — переносится один в один; кегль обязан проверяться глазами
        // на трубке, и до этого он не проверен ничем.
        //
        // Мера взята не с потолка: значение равно дню месяца в сетке (16), а
        // заголовок — имени вверху (20 у «Sən», здесь 18: он не главнее).
        //
        // **ЭТОТ РАЗМЕР ПРОВЕРЕН ГЛАЗАМИ НА ТРУБКЕ 26.08 и принят.** Следом
        // пробовали ещё +20% (22/20/18) — владелец остановил на этом. Не
        // поднимать «для читаемости» без взгляда на устройство: прошлый раз
        // и мелкость, и её мера появились от того, что кегль брали из
        // браузерного макета.
        Text(
          fmtEventDate(iso),
          key: const ValueKey('answer-details-day'),
          style: const TextStyle(
            color: kGold,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Column(
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      SizedBox(
                        width: 66,
                        child: Text(
                          r.$1,
                          style: const TextStyle(color: kMuted, fontSize: 15),
                        ),
                      ),
                      // ЗНАЧЕНИЕ КРУПНЕЕ ПОДПИСИ, а не вровень с ней: человек
                      // пришёл сюда за временем и местом, а не за словом
                      // «Saat». Подпись объясняет, значение отвечает.
                      Expanded(
                        child: Text(
                          r.$2,
                          style: const TextStyle(
                            color: kText,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // ВОЗВРАТ НАЗВАН СЛОВОМ, а не оставлен на догадку. Повторное нажатие
        // на день работает тоже, но о нём никто не знает: способ, который
        // нельзя увидеть, — это не способ.
        GestureDetector(
          key: const ValueKey('answer-details-back'),
          onTap: () => setState(() => _openDay = null),
          child: const Text(
            '← nəticəyə qayıt',
            style: TextStyle(color: kMuted, fontSize: 13),
          ),
        ),
      ],
    );
  }

  /// Числа согласованных дней через запятую, в календарном порядке.
  String _numbers(Set<String> picked) => (picked.toList()..sort())
      .map(DateTime.tryParse)
      .whereType<DateTime>()
      .map((d) => '${d.day}')
      .join(', ');

  List<Widget> _actions() {
    final out = <Widget>[];

    if (widget.onAccept != null &&
        canAcceptAnswer(widget.offer, recipientUid: widget.recipientUid)) {
      out.add(
        _GoldButton(
          key: const ValueKey('accept-confirm'),
          label: 'Qəbul edirəm',
          onTap: widget.onAccept!,
        ),
      );
    }

    if (widget.onChangeAnswer != null) {
      if (out.isNotEmpty) out.add(const SizedBox(height: 10));
      out.add(
        _GoldButton(
          key: const ValueKey('answer-change'),
          label: 'Cavabı dəyiş',
          onTap: widget.onChangeAnswer!,
        ),
      );
    }

    // ПРИ ОТКАЗЕ ОТЗЫВ — ЕДИНСТВЕННЫЙ ХОД, и потому рядом сказано, ЧТО ПОСЛЕ
    // НЕГО БУДЕТ. Иначе человек нажмёт и не поймёт, куда всё делось:
    // предложение закрывается насовсем, а позвать заново — значит отправить
    // НОВОЕ. Кнопка без этой строки выглядит как «убрать с глаз», а убирает
    // она ход целиком.
    if (widget.onWithdraw != null) {
      if (out.isNotEmpty) out.add(const SizedBox(height: 12));
      out.addAll([
        Center(
          // ВИД ДЕЙСТВИЯ — ОДИН С КАРТОЧКОЙ (N174, 27.08). Довод целиком
          // записан у второго места, `job_offer_card.dart` (у отзыва в
          // `_footer`), и повторять его здесь не надо — надо, чтобы эти два
          // места не разошлись. До сегодня они уже разошлись: `kMuted, 12`
          // там против `kMuted, 14` здесь, и заметить это было нечем, потому
          // что рядом их не видно никогда. Теперь оба — `kGold, 14, w600`.
          child: GestureDetector(
            key: const ValueKey('accept-withdraw'),
            onTap: widget.onWithdraw,
            child: const Text(
              'Təklifi geri götür',
              style: TextStyle(
                color: kGold,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Təklif bağlanacaq. Yenidən çağırmaq üçün yeni təklif '
          'göndərməlisən.',
          key: ValueKey('accept-withdraw-note'),
          textAlign: TextAlign.center,
          style: TextStyle(color: kMuted, fontSize: 11),
        ),
      ]);
    }

    return out;
  }
}

class _GoldButton extends StatelessWidget {
  const _GoldButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kGold,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: kOnGold,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
