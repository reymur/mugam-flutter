import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/event_conflict_banner.dart';

/// ЧЕМ ЗАНЯТ ДЕНЬ, НА КОТОРЫЙ ЧЕЛОВЕК ТОЛЬКО ЧТО НАЖАЛ.
///
/// Заведено 25.08 по указанию владельца, после того как занятость впервые
/// увидели на трубке: **предупредительный цвет говорит «осторожно», но не
/// говорит «чем»**. Человек, ткнув в закрашенный день, вправе спросить, что
/// там стоит, — и получить ответ, не выходя из листа.
///
/// **ОДНА НАДПИСЬ НА ОБА ЛИСТА** — ответа музыканта и набора дней
/// работодателя. Задача у них одна («сказать, чем занят этот день»), значит и
/// код один (I58: сводить по задаче). Расходятся листы в том, КОГДА день
/// считается выбранным, и это остаётся у них.
///
/// **ВЕЧЕРА ПЕРЕЧИСЛЯЮТСЯ ВСЕ, каждый своей строкой, и каждая ведёт в свой.**
/// Два вечера в один день — обычная жизнь; показать один значило бы спрятать
/// второй молча (N51/I11), а спросить «который из двух?» окошком — задать
/// вопрос там, где человек его не задавал. Строк столько, сколько вечеров.
///
/// **СТРОКА БЕЗ АДРЕСАТА НЕ РИСУЕТСЯ НАЖИМАЕМОЙ.** Не передали
/// [onOpenEvent] — текст остаётся текстом, без обманчивого вида кнопки. Это
/// то самое правило, на котором 20.08 поймали микрофон без обработчика
/// (N146, I64).
class BusyDayNotice extends StatelessWidget {
  const BusyDayNotice({
    super.key,
    required this.events,
    this.onOpenEvent,
  });

  /// Вечера этого дня, уже по времени. Пусто — виджет не рисуется вовсе.
  final List<PersonalEvent> events;

  /// Открыть карточку вечера. `null` — открывать некуда, строки не нажимаемы.
  final void Function(String eventId)? onOpenEvent;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const SizedBox.shrink();

    return Container(
      key: const ValueKey('busy-day-notice'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kWarnBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kWarnBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ЗАГОЛОВОК — СЛОВО ФИЧИ, а не второе название того же.
          // «məşğulsan» уже говорит карточка предложения; календарь про то же
          // говорит своими словами («Bu gün artıq tədbirin var»), и сводить их
          // в одну строку — отдельная работа, не эта (I51).
          const Text(
            'Bu gün məşğulsan',
            style: TextStyle(
              color: kWarnTitle,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          for (final e in events) _eventRow(e),
        ],
      ),
    );
  }

  Widget _eventRow(PersonalEvent e) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            // Чем именно занято время — тем же правилом, каким это говорит
            // красная плашка в карточке вечера (`eventConflictSummary`).
            // Второго способа собрать «Toy · 17:20 · Bakı» в проекте быть не
            // должно: разойдись они, один экран назвал бы вечер иначе, чем
            // другой.
            child: Text(
              eventConflictSummary(e),
              style: kWarnFactStyle,
            ),
          ),
          if (onOpenEvent != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, size: 18, color: kWarnHint),
          ],
        ],
      ),
    );

    if (onOpenEvent == null) return row;
    return GestureDetector(
      key: ValueKey('busy-day-open-${e.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => onOpenEvent!(e.id),
      child: row,
    );
  }
}
