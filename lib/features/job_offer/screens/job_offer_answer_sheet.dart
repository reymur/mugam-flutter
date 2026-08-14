import 'package:flutter/material.dart';

import '../../../core/job_offer/job_offer.dart';
import '../../../core/job_offer/offer_draft.dart';
import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';
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
    this.busyDays = const {},
    this.now,
  });

  final JobOffer offer;
  final String myUid;
  final String initiatorName;

  /// Отдаёт отмеченные дни. **Пустой список — законный ответ**, а не отказ
  /// от ответа.
  final void Function(List<String> picked) onSend;

  /// Свои занятые дни — ПРЕДУПРЕЖДЕНИЕ, не запрет: выбрать их можно,
  /// решает человек (см. `OfferMonthGrid.busy`).
  final Set<String> busyDays;

  final DateTime? now;

  @override
  State<JobOfferAnswerSheet> createState() => _JobOfferAnswerSheetState();
}

class _JobOfferAnswerSheetState extends State<JobOfferAnswerSheet> {
  late final Set<String> _picked = widget.offer.pickedBy(widget.myUid).toSet();
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
                  Text(
                    azUpperCase(
                      '${widget.initiatorName} təklif edir · '
                      '${widget.offer.eventType}',
                    ),
                    style: const TextStyle(
                      color: kGold,
                      fontSize: 12,
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
                      busy: widget.busyDays,
                      // НАЖИМАЕМЫ ТОЛЬКО ПРЕДЛОЖЕННЫЕ ДНИ, ни одного
                      // лишнего. Требование автора и вторая половина
                      // правила `answerFitsOffer`.
                      selectable: offered,
                      now: widget.now,
                      onTapDay: (iso) => setState(() {
                        if (!_picked.remove(iso)) _picked.add(iso);
                      }),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _picked.isEmpty
                          ? 'Gələ bildiyin günləri seç'
                          : offerSummaryLine(_picked),
                      key: const ValueKey('answer-summary'),
                      style: TextStyle(
                        color: _picked.isEmpty ? kMuted : kGold,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (widget.busyDays.intersection(offered).isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        // Занятость — сведения, а не преграда. Сказано и на
                        // экране, чтобы человек не думал, будто ему не дают.
                        'məşğul günləri də seçə bilərsən',
                        style: TextStyle(color: kMuted, fontSize: 12),
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
      ),
    );
  }

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
