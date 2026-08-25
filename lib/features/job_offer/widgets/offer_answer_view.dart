import 'package:flutter/material.dart';

import '../../../core/job_offer/day_details.dart';
import '../../../core/job_offer/job_offer.dart';
import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';

// ОТВЕТ МУЗЫКАНТА, КАК ЕГО ЧИТАЮТ ОБЕ СТОРОНЫ.
//
// Пришло на смену `JobOfferAcceptSheet` 25.08, по макету владельца. Меняется
// не только вид: прежний экран был ЛИСТОМ ПРИЁМА — отдельной модалкой поверх
// карточки, открывавшейся кнопкой «Cavaba bax». Теперь это ВИД, который
// рисует сама дверь (`JobOfferSheet`), и промежуточной карточки между лентой
// и ответом больше нет.
//
// **ПОЧЕМУ ВИД, А НЕ ЛИСТ, И ЭТО ГЛАВНОЕ В ФАЙЛЕ.** В `job_offer_sheet.dart`
// записан довод владельца от 22.08 против того, чтобы вести из ленты прямо в
// приём: тогда лист пришлось бы либо питать СНИМКОМ из ленты — и потерять
// живое обновление, ради которого делалась N143, — либо завести второй
// источник тех же данных. Довод не отменён, он **обойдён**: содержимое
// осталось за дверью, у живого потока, и снимок сюда по-прежнему не подаётся.
// Своей обёртки — высоты, скруглений, ручки — у этого виджета нет намеренно:
// всё это уже есть у двери, и вторая копия разошлась бы с первой.
//
// **Второй довод того же абзаца снят макетом:** там сказано, что инициатор,
// уведённый прямо в приём, потеряет «Ətraflı» — в листе приёма его не было
// (замер 22.08: `grep -c "Ətraflı"` по тому файлу — 0). Теперь подробности
// здесь есть, и лежат они ПО ДНЯМ — так же, как хранятся.
//
// --- ПОРЯДОК СВЕРХУ ВНИЗ, И КАЖДАЯ ПЕРЕСТАНОВКА ИМЕЕТ ПРИЧИНУ ---
//
//   имя отвечавшего     — крупно. Прежде здесь было мелкое серое
//                         «TEYMUR ORUCOV CAVAB VERDİ» в разрядку: имя и
//                         состояние делили одну строку и мешали друг другу.
//                         Теперь имя отвечает на «кто», подпись под ним — на
//                         «что», и они не спорят;
//   месяц               — по центру, один раз на группу дней. Раньше месяц
//                         повторялся при каждом числе («29 avqust, şənbə»);
//   только числа        — дни недели сняты, слова сняты. Отказ помечен
//                         красным ✕ и больше ничем: значок говорит сам,
//                         подписи «Gələ bilmir» нет (решение владельца);
//   числа и подпись     — «29, 30 · Gələ bilirəm» одной строкой;
//   итог                — «2 gün · Toy» мелко ВНИЗУ. Прежде «2 gün» стояло
//                         крупным белым СВЕРХУ, то есть самое заметное место
//                         отдавалось числу, которое и так видно по клеткам.
//
// --- ЧЕГО ЭТОТ ВИД НЕ ДЕЛАЕТ ---
//
//   1. НЕ ПОЗВОЛЯЕТ ПРАВИТЬ ОТМЕТКИ. Инициатору менять ответ музыканта
//      запрещено правилом, иначе «он согласился на 29-е» перестало бы значить
//      «решил он». Нажатие на день открывает подробности, и только;
//   2. НЕ РИСУЕТ СЕТКУ МЕСЯЦА. Показаны ровно предложенные дни — по макету.
//      `OfferMonthGrid` остаётся жить в листе ответа, где дни ВЫБИРАЮТ;
//   3. НЕ РЕШАЕТ, КОМУ ЧТО ПРЕДЛОЖЕНО. Кнопки рисуются по тому, какие
//      обработчики переданы, — правило живёт у двери.

/// Одна группа дней: месяц и его числа, в календарном порядке.
typedef _MonthGroup = ({DateTime month, List<String> isoDays});

class OfferAnswerView extends StatelessWidget {
  const OfferAnswerView({
    super.key,
    required this.offer,
    required this.viewerUid,
    required this.recipientUid,
    required this.recipientName,
    this.onAccept,
    this.onWithdraw,
    this.onChangeAnswer,
  });

  final JobOffer offer;

  /// Чей это экран. Нужен ровно для одного: сказать отвечавшему «Sən», а не
  /// назвать его по имени в третьем лице (N141, I64).
  final String viewerUid;

  final String recipientUid;
  final String recipientName;

  /// «Qəbul edirəm» — инициатору. Рисуется только вместе с
  /// `canAcceptAnswer`: принимать нечего и до ответа, и при ответе нулём
  /// дней, а кнопка, после которой не происходит ничего, обещала действие.
  final VoidCallback? onAccept;

  /// «Təklifi geri götür» — инициатору.
  final VoidCallback? onWithdraw;

  /// «Cavabı dəyiş» — отвечавшему. Переответ разрешён, пока раунд открыт.
  final VoidCallback? onChangeAnswer;

  bool get _viewerAnswered => viewerUid == recipientUid;

  /// Дни предложения, разложенные по месяцам, в календарном порядке.
  ///
  /// **ГРУПП МОЖЕТ БЫТЬ БОЛЬШЕ ОДНОЙ, и это не запас на будущее.** Позвать
  /// на 31 августа и 1 сентября — обычное дело, а месяц в макете назван
  /// ОДИН РАЗ над числами. Свали такие дни в одну кучу — и «31, 1» под
  /// заголовком «Avqust» назовёт сентябрьский день августовским.
  ///
  /// Сортировка по ISO-строке и есть хронологический порядок: `YYYY-MM-DD`
  /// лексикографически совпадает с временным.
  ///
  /// Неразбираемые даты отбрасываются — тем же способом, каким их отбрасывал
  /// прежний экран (`whereType<DateTime>()`). Заводить здесь своё поведение
  /// значило бы развести два ответа на один вопрос.
  List<_MonthGroup> get _groups {
    final out = <_MonthGroup>[];
    for (final iso in offer.dates.toList()..sort()) {
      final d = DateTime.tryParse(iso);
      if (d == null) continue;
      final m = DateTime(d.year, d.month);
      if (out.isNotEmpty && out.last.month == m) {
        out.last.isoDays.add(iso);
      } else {
        out.add((month: m, isoDays: <String>[iso]));
      }
    }
    return out;
  }

  bool _hasDetails(String iso) => offer.details[iso]?.isNotEmpty ?? false;

  @override
  Widget build(BuildContext context) {
    final picked = offer.pickedBy(recipientUid).toSet();
    final groups = _groups;
    // Подсказка про нажатие — только когда нажимать есть на что. Обещать
    // «günə toxun» там, где ни у одного согласованного дня подробностей нет,
    // значило бы звать в пустоту.
    final anyTappable = picked.any(_hasDetails);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _viewerAnswered ? 'Sən' : recipientName,
            key: const ValueKey('answer-who'),
            style: const TextStyle(
              color: kText,
              fontSize: 21,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _viewerAnswered ? 'cavab verdin' : 'cavab verdi',
            style: const TextStyle(color: kMuted, fontSize: 12),
          ),

          for (final g in groups) ...[
            const SizedBox(height: 18),
            Center(
              child: Text(
                azUpperCase(azMonthFull(g.month.month)),
                style: const TextStyle(
                  color: kGold,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Wrap(
                spacing: 10,
                runSpacing: 14,
                alignment: WrapAlignment.center,
                children: [
                  for (final iso in g.isoDays)
                    _DayChip(
                      iso: iso,
                      day: DateTime.parse(iso).day,
                      agreed: picked.contains(iso),
                      onTap: picked.contains(iso) && _hasDetails(iso)
                          ? () => _openDetails(context, iso)
                          : null,
                    ),
                ],
              ),
            ),
          ],

          if (anyTappable) ...[
            const SizedBox(height: 9),
            const Center(
              child: Text(
                'günə toxun → Ətraflı',
                key: ValueKey('answer-tap-hint'),
                style: TextStyle(color: kTextDim, fontSize: 11),
              ),
            ),
          ],

          // ЧИСЛА И ПОДПИСЬ — только когда согласованные дни есть. При
          // ответе нулём («ни на один не могу») строка «— Gələ bilirəm»
          // рядом с пустотой прочлась бы прямо наоборот.
          if (picked.isNotEmpty) ...[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.only(top: 14),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: kBorder)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      _numbers(picked),
                      key: const ValueKey('answer-picked-numbers'),
                      style: const TextStyle(
                        color: kText,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Gələ bilirəm',
                    style: TextStyle(color: kGold, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 8),
          Text(
            '${picked.length} gün · ${offer.eventType}',
            key: const ValueKey('answer-total'),
            style: const TextStyle(color: kMuted, fontSize: 12),
          ),

          const SizedBox(height: 20),
          ..._actions(),
        ],
      ),
    );
  }

  /// Числа согласованных дней через запятую, в календарном порядке.
  String _numbers(Set<String> picked) {
    final days = (picked.toList()..sort())
        .map(DateTime.tryParse)
        .whereType<DateTime>()
        .map((d) => '${d.day}')
        .join(', ');
    return days;
  }

  List<Widget> _actions() {
    final out = <Widget>[];

    if (onAccept != null &&
        canAcceptAnswer(offer, recipientUid: recipientUid)) {
      out.add(
        _GoldButton(
          key: const ValueKey('accept-confirm'),
          label: 'Qəbul edirəm',
          onTap: onAccept!,
        ),
      );
    }

    if (onChangeAnswer != null) {
      if (out.isNotEmpty) out.add(const SizedBox(height: 10));
      out.add(
        _GoldButton(
          key: const ValueKey('answer-change'),
          label: 'Cavabı dəyiş',
          onTap: onChangeAnswer!,
        ),
      );
    }

    // ПРИ ОТКАЗЕ ОТЗЫВ — ЕДИНСТВЕННЫЙ ХОД, и потому рядом сказано, ЧТО
    // ПОСЛЕ НЕГО БУДЕТ. Иначе человек нажмёт и не поймёт, куда всё делось:
    // предложение закрывается насовсем, а позвать заново — значит отправить
    // НОВОЕ предложение. Кнопка без этой строки выглядит как «убрать с
    // глаз», а убирает она ход целиком.
    if (onWithdraw != null) {
      if (out.isNotEmpty) out.add(const SizedBox(height: 12));
      out.addAll([
        Center(
          child: GestureDetector(
            key: const ValueKey('accept-withdraw'),
            onTap: onWithdraw,
            child: const Text(
              'Təklifi geri götür',
              style: TextStyle(color: kMuted, fontSize: 14),
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

  /// ПОДРОБНОСТИ ОДНОГО ДНЯ — снизу, поверх этого вида.
  ///
  /// Поверх, а не вместо: человек смотрит время и место и возвращается к
  /// ответу, ничего не потеряв. Тот же приём, что у листа ответа и у
  /// карточки вечера.
  void _openDetails(BuildContext context, String iso) {
    final d = offer.details[iso];
    if (d == null || d.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _DayDetailsSheet(iso: iso, details: d),
    );
  }
}

/// ОДИН ДЕНЬ — ТОЛЬКО ЧИСЛО, и знак отказа при нём.
///
/// Три вида, и они различаются не оттенком, а формой сообщения:
///   согласован             — золотой, нажимается, если есть подробности;
///   отказ                  — тусклый, и красный ✕ в углу;
///   предложен без ответа    — тусклый, без значка.
class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.iso,
    required this.day,
    required this.agreed,
    this.onTap,
  });

  final String iso;
  final int day;
  final bool agreed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: 52,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: agreed ? kGold.withAlpha(36) : kBg3,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: agreed ? kGold : Colors.transparent),
      ),
      child: Text(
        '$day',
        style: TextStyle(
          color: agreed ? kGold2 : kTextDim,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );

    return Stack(
      // Значок заходит за угол клетки, поэтому обрезать его нельзя.
      clipBehavior: Clip.none,
      children: [
        onTap == null
            ? box
            : GestureDetector(
                key: ValueKey('answer-day-$iso'),
                onTap: onTap,
                child: box,
              ),
        if (!agreed)
          Positioned(
            top: -4,
            right: -4,
            child: Container(
              key: ValueKey('answer-day-no-$iso'),
              width: 19,
              height: 19,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: kRed,
                shape: BoxShape.circle,
                border: Border.all(color: kBg2, width: 2),
              ),
              child: const Text(
                '✕',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Подробности дня — время, место, одежда. Пустые поля не рисуются вовсе:
/// строка «Yer —» обещала бы сведения, которых нет.
class _DayDetailsSheet extends StatelessWidget {
  const _DayDetailsSheet({required this.iso, required this.details});

  final String iso;
  final DayDetails details;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      if (details.time.isNotEmpty) ('Saat', details.time),
      if (details.location.isNotEmpty) ('Yer', details.location),
      if (details.dress.isNotEmpty) ('Geyim', details.dress),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: kBg3,
        border: Border(top: BorderSide(color: kBorder)),
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
              const SizedBox(height: 12),
              Text(
                fmtEventDate(iso),
                key: const ValueKey('answer-details-day'),
                style: const TextStyle(
                  color: kGold,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 56,
                        child: Text(
                          r.$1,
                          style: const TextStyle(color: kMuted, fontSize: 13),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          r.$2,
                          style: const TextStyle(color: kText, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
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
