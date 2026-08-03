import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/colors.dart';
import '../../core/time/az_date_format.dart';
import '../../firebase/models.dart';

// Диалог «на это время у вас уже есть мероприятие» — один на календарь
// (agreements_screen.dart → _EventFormModal) и на лист предложения работы
// (chat/screens/job_offer_date_sheet.dart).
//
// Вынесен из agreements_screen.dart, когда проверку конфликта завели в
// предложении работы. Второй такой диалог не изобретался намеренно:
// вопрос у человека один и тот же («у меня занято, что делать»), и три
// ответа на него обязаны быть одинаковыми в обоих местах — иначе одно и
// то же затруднение выглядит по-разному в зависимости от того, откуда в
// него пришли.
//
// Возвращает через `Navigator.pop` одно из трёх, `null` при закрытии
// мимо кнопок:
//   'view'    — посмотреть конфликтующее мероприятие;
//   'replace' — всё равно оставить выбранное время;
//   'new'     — вернуться и выбрать другое время.
//
// Показ самого конфликтующего мероприятия НЕ живёт здесь: он тянет за
// собой карточку события и экран подробностей, которые остаются частью
// экрана договоров. Поэтому 'view' — это ответ диалога, а что по нему
// открыть, решает вызывающая сторона (в календаре — свой приватный экран,
// в чате — `agreementConflictEventRoute`).
class EventConflictDialog extends StatelessWidget {
  final PersonalEvent conflict;

  const EventConflictDialog({super.key, required this.conflict});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kBg2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '⚠️ Bu tarixdə tədbir var',
              style: GoogleFonts.nunito(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: kRed,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kBg3,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kGold.withAlpha(60)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (conflict.type.isNotEmpty) ...[
                    Text(
                      conflict.type,
                      style: GoogleFonts.nunito(
                        color: kGold,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    const Divider(color: kBorder, height: 1),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (conflict.location.isNotEmpty) ...[
                        const Text('📍', style: TextStyle(fontSize: 13)),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            conflict.location,
                            style: const TextStyle(
                              color: kText,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (conflict.date.isNotEmpty) const SizedBox(width: 12),
                      ],
                      if (conflict.date.isNotEmpty) ...[
                        const Text('🕐', style: TextStyle(fontSize: 13)),
                        const SizedBox(width: 4),
                        Text(
                          '${fmtEventDate(conflict.date)}  '
                          '${fmtEventTime(conflict.date)}',
                          style: const TextStyle(
                            color: kText,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop('view'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kGold,
                      side: const BorderSide(color: kGold),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('Bax'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop('replace'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      foregroundColor: const Color(0xFF1A0E00),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      'Əvəz et',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop('new'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kBg3,
                      foregroundColor: kMuted,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: const BorderSide(color: kBorder),
                      ),
                    ),
                    child: const Text('Yeni tədbir'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
