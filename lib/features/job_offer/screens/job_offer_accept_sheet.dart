import 'package:flutter/material.dart';

import '../../../core/job_offer/job_offer.dart';
import '../../../core/text/az_case.dart';
import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';
import '../widgets/offer_month_grid.dart';

// ЭКРАН ПРИЁМА — инициатор смотрит ответ и решает.
//
// Третий экран цепочки. От экрана ответа отличается не «правами на кнопку»,
// а тем, что здесь НИЧЕГО НЕ ВЫБИРАЮТ: сетка только показывает. Инициатору
// править отметки музыканта запрещено правилом — иначе «он согласился на
// 9-е» перестало бы значить «решил он».
//
// ЧТО КРУПНО, А ЧТО ТИШЕ — требование автора 14.08:
//   крупно  — на сколько дней согласился и на какие («3 gün», даты);
//   тише    — на какие не согласился.
// Отказ не поступок, а СВЕДЕНИЯ: он остаток выбора, а не действие. Выдели
// его наравне — и экран прочтётся как «вам отказали», хотя вам согласились.

class JobOfferAcceptSheet extends StatelessWidget {
  const JobOfferAcceptSheet({
    super.key,
    required this.offer,
    required this.recipientUid,
    required this.recipientName,
    required this.onAccept,
    this.onWithdraw,
    this.now,
  });

  final JobOffer offer;
  final String recipientUid;
  final String recipientName;
  final VoidCallback onAccept;
  final VoidCallback? onWithdraw;
  final DateTime? now;

  DateTime get _month {
    final dates = offer.dates.toList()..sort();
    final first = dates.isEmpty ? null : DateTime.tryParse(dates.first);
    final n = now ?? DateTime.now();
    return DateTime(first?.year ?? n.year, first?.month ?? n.month);
  }

  String _dayList(List<String> iso) {
    final parsed = (iso.toList()..sort())
        .map(DateTime.tryParse)
        .whereType<DateTime>()
        .toList();
    if (parsed.isEmpty) return '';
    final days = parsed.map((d) => '${d.day}').join(', ');
    return '$days ${azMonthFull(parsed.first.month).toLowerCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final picked = offer.pickedBy(recipientUid);
    final declined = offer.declinedBy(recipientUid);
    final answered = offer.hasAnswered(recipientUid);

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
                    // ТА ЖЕ ФРАЗА, ЧТО В КАРТОЧКЕ, И СЧИТАЕТСЯ ТЕМ ЖЕ
                    // СПОСОБОМ. До 19.08 она была написана здесь и там
                    // ПО-РАЗНОМУ — `-in` против `un`, — и оба варианта
                    // неверны: ждут ответа ОТ человека, то есть исходный
                    // падеж, а окончание зависит от последней гласной
                    // имени.
                    azUpperCase(
                      answered
                          ? '$recipientName cavab verdi'
                          : azAwaitingAnswerFrom(recipientName),
                    ),
                    style: const TextStyle(
                      color: kMuted,
                      fontSize: 12,
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // КРУПНО: на сколько дней согласились.
                    Text(
                      '${picked.length} gün',
                      key: const ValueKey('accept-count'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (picked.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        _dayList(picked),
                        key: const ValueKey('accept-days'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                        ),
                      ),
                    ],
                    // ТИШЕ: на какие не согласились. Мелко и серо — сведения,
                    // не действие.
                    if (declined.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${_dayList(declined)} — yox',
                        key: const ValueKey('accept-declined'),
                        style: const TextStyle(color: kMuted, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 16),
                    // Сетка только показывает: выбирать здесь нечего.
                    // `onTapDay` не передан вовсе — не «передан и
                    // игнорируется», а отсутствует, и клетки мертвы.
                    OfferMonthGrid(
                      month: _month,
                      picked: picked.toSet(),
                      now: now,
                    ),
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
                  // ПРИНИМАТЬ НЕЧЕГО В ДВУХ СЛУЧАЯХ, и второй заметить
                  // труднее первого.
                  //
                  //   до ответа        — согласие с пустотой;
                  //   ОТВЕТ НУЛЁМ ДНЕЙ — кнопка создала бы НОЛЬ вечеров.
                  //
                  // Второй хуже: кнопка есть, нажимается, и после неё не
                  // происходит ничего. Человек остаётся гадать, сработало
                  // или нет, — а «Qəbul edirəm» обещало действие.
                  //
                  // Решает `canAcceptAnswer`, у неё тесты.
                  if (canAcceptAnswer(offer, recipientUid: recipientUid))
                    GestureDetector(
                      key: const ValueKey('accept-confirm'),
                      onTap: onAccept,
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: kGold,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Qəbul edirəm',
                          style: TextStyle(
                            color: kOnGold,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  // ПРИ ОТКАЗЕ ОТЗЫВ — ЕДИНСТВЕННЫЙ ХОД, и потому рядом
                  // сказано, ЧТО ПОСЛЕ НЕГО БУДЕТ.
                  //
                  // Иначе человек нажмёт и не поймёт, куда всё делось:
                  // предложение закрывается насовсем, отметки больше не
                  // принимаются, и позвать заново — значит отправить НОВОЕ
                  // предложение. Кнопка без этой строки выглядит как
                  // «убрать с глаз», а убирает она ход целиком.
                  if (onWithdraw != null) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      key: const ValueKey('accept-withdraw'),
                      onTap: onWithdraw,
                      child: const Text(
                        'Təklifi geri götür',
                        style: TextStyle(color: kMuted, fontSize: 14),
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
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
