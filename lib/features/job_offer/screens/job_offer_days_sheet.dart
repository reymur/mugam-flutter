import 'package:flutter/material.dart';

import '../../../core/job_offer/offer_draft.dart';
import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';

// ЛИСТ ВЫБОРА ДНЕЙ — шаг 1 цепочки, макет `docs/design/mugam-10-secim`,
// первый экран.
//
// ВСЁ В ОДНОМ ЛИСТЕ: дни, тип, время, место, заметка. Не мастером из
// нескольких шагов — предложение уходит одной записью, и человек должен
// видеть целиком то, что отправляет.
//
// ВРЕМЯ, МЕСТО И ЗАМЕТКА НЕОБЯЗАТЕЛЬНЫ. Обязательны день и тип, и это
// проверяет `canSendOffer`, у которой есть тест. Сделай их обязательными —
// и предложение на пять дней отправить станет нельзя: на много дат деталей
// обычно нет, их говорят голосом за день-два.
//
// СЕТКОЙ МЕСЯЦА, А НЕ СПИСКОМ. Список не показывает, что 9-е и 15-е стоят
// по разным концам месяца, а именно это человек и держит в голове, когда
// зовёт на работу.

class JobOfferDaysSheet extends StatefulWidget {
  const JobOfferDaysSheet({
    super.key,
    required this.onSend,
    this.initialMonth,
    this.busyDays = const {},
    this.initialDates = const [],
    this.now,
  });

  /// «Сегодня» — прибивается снаружи только в тестах.
  ///
  /// Без него набор, тыкающий в конкретные числа, зависит от календарной
  /// даты прогона: написанный сегодня, он через неделю тыкает в прошлое,
  /// лист законно перестаёт принимать нажатие, и тест краснеет **не
  /// потому, что код сломался**. Поймано ровно так, в первый же прогон.
  final DateTime? now;

  /// Отдаёт набор дней и детали. Лист сам ничего не пишет: запись — дело
  /// хода, у которого своё правило (`JobOfferRepository.createOffer`).
  final void Function({
    required List<String> dates,
    required String eventType,
    required String eventTime,
    required String eventLocation,
    required String eventNotes,
  })
  onSend;

  final DateTime? initialMonth;

  /// Свои занятые дни. **ВИДНЫ, НО ВЫБРАТЬ ИХ МОЖНО** — приложение помнит и
  /// показывает, а решает человек. Запретить значило бы решать за него в
  /// случае, который он знает лучше нас: две работы в один вечер бывают
  /// законны.
  final Set<String> busyDays;

  final List<String> initialDates;

  @override
  State<JobOfferDaysSheet> createState() => _JobOfferDaysSheetState();
}

class _JobOfferDaysSheetState extends State<JobOfferDaysSheet> {
  late DateTime _month =
      widget.initialMonth ?? DateTime(DateTime.now().year, DateTime.now().month);
  late final Set<String> _picked = widget.initialDates.toSet();

  final _typeController = TextEditingController();
  final _timeController = TextEditingController();
  final _locationController = TextEditingController();
  final _notesController = TextEditingController();

  @override
  void dispose() {
    _typeController.dispose();
    _timeController.dispose();
    _locationController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  static const _weekdayLabels = ['B.e', 'Ç.a', 'Ç', 'C.a', 'C', 'Ş', 'B'];

  @override
  Widget build(BuildContext context) {
    final canSend = canSendOffer(
      dates: _picked,
      eventType: _typeController.text,
    );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                azUpperCase('günləri seç'),
                style: const TextStyle(
                  color: kGold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              _monthHeader(),
              const SizedBox(height: 8),
              _weekdayRow(),
              _grid(),
              const SizedBox(height: 12),
              // ТРЕБОВАНИЕ: человек видит, что отправляет, ДО нажатия.
              if (_picked.isNotEmpty)
                Text(
                  offerSummaryLine(_picked),
                  key: const ValueKey('offer-summary'),
                  style: const TextStyle(
                    color: kGold,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(height: 14),
              _field('NÖV', _typeController, key: 'offer-type'),
              const SizedBox(height: 10),
              // Три необязательных. Подпись говорит это словом, а не
              // умолчанием: пустое поле само по себе не сообщает, обязано
              // оно быть заполненным или нет.
              _field(
                'SAAT (məcburi deyil)',
                _timeController,
                key: 'offer-time',
              ),
              const SizedBox(height: 10),
              _field(
                'YER (məcburi deyil)',
                _locationController,
                key: 'offer-location',
              ),
              const SizedBox(height: 10),
              _field(
                'QEYD (məcburi deyil)',
                _notesController,
                key: 'offer-notes',
              ),
              const SizedBox(height: 18),
              _sendButton(canSend),
            ],
          ),
        ),
      ),
    );
  }

  Widget _monthHeader() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      IconButton(
        key: const ValueKey('offer-month-prev'),
        icon: const Icon(Icons.chevron_left, color: kMuted),
        onPressed: () => setState(
          () => _month = DateTime(_month.year, _month.month - 1),
        ),
      ),
      Text(
        '${azMonthFull(_month.month)} ${_month.year}',
        style: const TextStyle(color: Colors.white, fontSize: 17),
      ),
      IconButton(
        key: const ValueKey('offer-month-next'),
        icon: const Icon(Icons.chevron_right, color: kMuted),
        onPressed: () => setState(
          () => _month = DateTime(_month.year, _month.month + 1),
        ),
      ),
    ],
  );

  Widget _weekdayRow() => Row(
    children: _weekdayLabels
        .map(
          (l) => Expanded(
            child: Center(
              child: Text(
                l,
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
            ),
          ),
        )
        .toList(),
  );

  Widget _grid() {
    final days = monthGridDays(_month);
    return Column(
      children: List.generate(6, (week) {
        return Row(
          children: List.generate(7, (i) {
            final day = days[week * 7 + i];
            return Expanded(child: _dayCell(day));
          }),
        );
      }),
    );
  }

  Widget _dayCell(DateTime day) {
    final inMonth = day.month == _month.month;
    final iso = isoDay(day);
    final past = isPastDay(day, now: widget.now);
    final picked = _picked.contains(iso);
    final busy = widget.busyDays.contains(iso);

    // Прошлые дни и чужие месяцы не выбираются. Занятые — выбираются:
    // приложение помнит и показывает, решает человек.
    final selectable = inMonth && !past;

    return GestureDetector(
      key: ValueKey('offer-cell-$iso'),
      onTap: selectable
          ? () => setState(() {
              if (!_picked.remove(iso)) _picked.add(iso);
            })
          : null,
      child: Container(
        height: 42,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: picked ? kGold : (busy ? kGoldDim : Colors.transparent),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          '${day.day}',
          style: TextStyle(
            fontSize: 15,
            color: picked
                ? kOnGold
                : !inMonth || past
                ? kMuted.withAlpha(110)
                : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    required String key,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: kBorder),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: kMuted, fontSize: 11, letterSpacing: 1),
        ),
        TextField(
          key: ValueKey(key),
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 15),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
          ),
          // Тип решает, можно ли отправлять, поэтому кнопка обязана
          // ожить в тот же миг, когда его начали набирать.
          onChanged: (_) => setState(() {}),
        ),
      ],
    ),
  );

  Widget _sendButton(bool canSend) => Opacity(
    opacity: canSend ? 1 : 0.4,
    child: GestureDetector(
      key: const ValueKey('offer-send-days'),
      onTap: canSend
          ? () => widget.onSend(
              dates: _picked.toList()..sort(),
              eventType: _typeController.text.trim(),
              eventTime: _timeController.text.trim(),
              eventLocation: _locationController.text.trim(),
              eventNotes: _notesController.text.trim(),
            )
          : null,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: kGold,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Göndər',
          style: TextStyle(
            color: kOnGold,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );
}
