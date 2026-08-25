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
/// --- ГДЕ НАЖИМАТЬ: ОДИН ВЕЧЕР И НЕСКОЛЬКО — РАЗНЫЕ СЛУЧАИ ---
///
/// **Один вечер — нажимается ВЕСЬ блок** (владелец, 25.08, по виду на
/// трубке). Цель у нажатия одна, значит и мишень одна: заставлять целиться в
/// строку, когда в блоке больше нечего нажать, — значит отнимать площадь без
/// причины. Стрелка при этом стоит **по центру блока**, а не вровень со
/// строкой: она про блок целиком.
///
/// **Несколько вечеров — нажимается КАЖДАЯ СТРОКА, и стрелка у каждой.**
/// Целей столько же, сколько вечеров, и свести их к одной нельзя: пришлось бы
/// либо открывать первый (`.first`, N51/I11), либо спрашивать «который?» —
/// вопрос, которого человек не задавал. Два вечера в один день — обычная
/// жизнь.
///
/// **СТРОКА БЕЗ АДРЕСАТА НЕ РИСУЕТСЯ НАЖИМАЕМОЙ.** Не передали
/// [onOpenEvent] — текст остаётся текстом, без обманчивого вида кнопки, и
/// стрелки нет вовсе. Это то самое правило, на котором 20.08 поймали микрофон
/// без обработчика (N146, I64).
class BusyDayNotice extends StatelessWidget {
  const BusyDayNotice({
    super.key,
    required this.events,
    this.onOpenEvent,
  });

  /// Вечера этого дня, уже по времени. Пусто — виджет не рисуется вовсе.
  final List<PersonalEvent> events;

  /// Открыть карточку вечера. `null` — открывать некуда, ничего не нажимаемо.
  final void Function(String eventId)? onOpenEvent;

  /// Стрелка. **Крупная намеренно** (владелец, 25.08): прежние 18 пунктов у
  /// края блока читались на трубке как украшение, а не как «сюда нажимают».
  static const double _chevronSize = 30;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const SizedBox.shrink();

    final single = events.length == 1;
    final wholeBoxOpens = single && onOpenEvent != null;

    final box = Container(
      key: const ValueKey('busy-day-notice'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: kWarnBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kWarnBorder),
      ),
      child: Row(
        // СТРЕЛКА ПО ЦЕНТРУ БЛОКА. Стоя вровень со строкой вечера, она
        // обещала бы, что нажимать надо именно там, — а нажимается всё.
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ЗАГОЛОВОК — СЛОВО ФИЧИ, а не второе название того же.
                // «məşğulsan» уже говорит карточка предложения; календарь про
                // то же говорит своими словами («Bu gün artıq tədbirin var»),
                // и сводить их в одну строку — отдельная работа, не эта (I51).
                const Text(
                  'Bu gün məşğulsan',
                  style: TextStyle(
                    color: kWarnTitle,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                for (final e in events) _eventRow(e, single: single),
              ],
            ),
          ),
          if (wholeBoxOpens) ...[
            const SizedBox(width: 6),
            const Icon(
              Icons.chevron_right,
              size: _chevronSize,
              color: kWarnHint,
            ),
          ],
        ],
      ),
    );

    if (!wholeBoxOpens) return box;
    return GestureDetector(
      key: ValueKey('busy-day-open-${events.single.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => onOpenEvent!(events.single.id),
      child: box,
    );
  }

  /// Одна строка «Toy · 17:20 · Bakı».
  ///
  /// [single] — вечер в блоке один, и нажимается блок целиком; тогда строка
  /// своей мишени не заводит. Иначе внутри одной нажимаемой области оказалась
  /// бы вторая, делающая ровно то же, — и промах пальцем по границе давал бы
  /// разный отклик на одно и то же намерение.
  Widget _eventRow(PersonalEvent e, {required bool single}) {
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
          if (!single && onOpenEvent != null) ...[
            const SizedBox(width: 6),
            const Icon(
              Icons.chevron_right,
              size: _chevronSize,
              color: kWarnHint,
            ),
          ],
        ],
      ),
    );

    if (single || onOpenEvent == null) return row;
    return GestureDetector(
      key: ValueKey('busy-day-open-${e.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => onOpenEvent!(e.id),
      child: row,
    );
  }
}
