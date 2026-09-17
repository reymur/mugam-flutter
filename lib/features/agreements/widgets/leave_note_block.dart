import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../navigation/app_tabs.dart';

/// Раскрытая причина выхода у строки вышедшего: текст, голос и дверь в
/// переписку с этим человеком.
///
/// Вынесена из `_PartyMemberRow` 17.09 — чтобы положение двери в переписку
/// проверялось раскладкой в тесте, а не чтением разметки: порядок и
/// выравнивание виджетов текстом не выражаются (I32).
class LeaveNoteBlock extends StatelessWidget {
  const LeaveNoteBlock({
    super.key,
    required this.text,
    required this.voice,
    required this.onOpenChat,
  });

  /// Сказанное словами; пустая строка — текста нет.
  final String text;

  /// Готовый проигрыватель голоса; `null` — голоса нет.
  final Widget? voice;

  /// Дверь в переписку с вышедшим; `null` — двери нет.
  final VoidCallback? onOpenChat;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: kBg3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (text.isNotEmpty)
            Text(
              text,
              style: const TextStyle(fontSize: 14, color: kTextSecondary),
            ),
          if (voice != null) ...[
            if (text.isNotEmpty) const SizedBox(height: 8),
            voice!,
          ],
          // ДВЕРЬ В ПЕРЕПИСКУ — ПОСЛЕДНЕЙ СТРОКОЙ БЛОКА, СПРАВА (17.09,
          // решение владельца, вариант А).
          //
          // Значок ведёт в переписку с ЧЕЛОВЕКОМ, то есть относится ко всему
          // блоку, а не к тексту и не к голосу. Здесь он стоял справа в `Row`
          // с `crossAxisAlignment.start` — вровень с первой строкой колонки и
          // в своей пустой полосе на всю высоту; при тексте и голосе висел у
          // текста, оторванный от записи. Замер старой раскладки в тесте:
          // отступ значка от нижнего края 11 / 11 / 59 по трём наборам.
          //
          // Значок — тот же, что у вкладки «MESAJ» (`kChatEmoji`), размер 20.
          // Цель нажатия 44×44: меньше пальцем берётся плохо (Apple HIG).
          if (onOpenChat != null)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                onPressed: onOpenChat,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 44,
                  height: 44,
                ),
                icon: const Text(kChatEmoji, style: TextStyle(fontSize: 20)),
              ),
            ),
        ],
      ),
    );
  }
}
