import 'package:flutter/material.dart';

import '../../../core/job_offer/job_offer.dart';
import '../../../core/theme/colors.dart';

/// СТРОКА ПРЕДЛОЖЕНИЯ В ЛЕНТЕ — то, что заменило развёрнутую карточку.
///
/// **ВЫНЕСЕНА ИЗ `chat_screen` 25.08, и не ради порядка в файлах.** Пока она
/// жила методом внутри состояния экрана, её нельзя было поднять в тесте: чат
/// тянет Firestore, Auth и роутер. Значит ни подпись автора (N164), ни
/// перенос длинной строки проверить было нечем — а обе правки как раз про то,
/// что видно на экране.
///
/// --- ДВЕ СТРОКИ, И ВЕРХНЯЯ ОТВЕЧАЕТ НА «ЧЬЁ ЭТО» (N164) ---
///
/// До 25.08 строка рисовалась во всю ширину, одинаковой заливкой, без стороны
/// и без имени: **своё и чужое предложение выглядели одинаково**. Обычные
/// сообщения в той же ленте различаются стороной, предложения — ничем.
/// Слово вместо стороны — довод `offerAuthorLine`.
///
/// --- ДЛИННАЯ СТРОКА ПЕРЕНОСИТСЯ, А НЕ ОБРЕЗАЕТСЯ ---
///
/// `maxLines` и `overflow` здесь **не задаются намеренно**: умолчание — перенос
/// без предела строк. Обрезка съела бы ровно конец, где стоит состояние, а
/// самый длинный набор в проде — 18 дат (14–31 августа) при типе до 24 знаков
/// по правилам. Замер 25.08: ширина под текст 295 pt, 6,84 pt на знак —
/// **43 знака**; отрезками не влезает 1 набор из 19, и он обязан перенестись,
/// а не потерять хвост.
class OfferFeedRow extends StatelessWidget {
  const OfferFeedRow({
    super.key,
    required this.offer,
    required this.viewerUid,
    required this.recipientUid,
    required this.initiatorName,
    this.onTap,
  });

  final JobOffer offer;

  /// Кто смотрит. По нему решается, своё предложение или чужое.
  final String viewerUid;

  /// Кому предложено — по нему читается ответ (`pickedBy`). Считает
  /// вызывающий: он знает состав чата, а строка — нет.
  final String recipientUid;

  /// Имя предложившего. Пустое даёт «Naməlum» — правило в `offerAuthorLine`.
  final String initiatorName;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      child: InkWell(
        key: ValueKey('offer-line-${offer.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: kBg3,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.work_outline, size: 18, color: kGold),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offerAuthorLine(
                        offer,
                        viewerUid: viewerUid,
                        initiatorName: initiatorName,
                      ),
                      key: const ValueKey('offer-line-author'),
                      style: const TextStyle(
                        color: kGold,
                        fontSize: 12,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      offerFeedLine(offer, recipientUid: recipientUid),
                      style: const TextStyle(color: kText, fontSize: 14),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.chevron_right, size: 18, color: kMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
