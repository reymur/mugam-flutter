import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';

// Extracted out of agreements_screen.dart's own private _WheelDateTimePicker
// so the chat screen's job-offer date picker (see chat_screen.dart) can
// reuse it too, instead of duplicating this wheel-scroll UI — the original
// had a plain value/onChanged interface with no PersonalEvent/FirestoreService
// coupling, unlike agreements_screen.dart's own _EventFormModal, so it
// extracted cleanly.
const azMonthsShort = [
  'Yan', 'Fev', 'Mar', 'Apr', 'May', 'İyn',
  'İyl', 'Avq', 'Sen', 'Okt', 'Noy', 'Dek',
];

class WheelDateTimePicker extends StatefulWidget {
  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  const WheelDateTimePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<WheelDateTimePicker> createState() => _WheelDateTimePickerState();
}

class _WheelDateTimePickerState extends State<WheelDateTimePicker> {
  static const _yearStart = 2024;
  static const _yearEnd = 2030;
  static const _itemExtent = 44.0;

  late final FixedExtentScrollController _dayController;
  late final FixedExtentScrollController _monthController;
  late final FixedExtentScrollController _yearController;
  late final FixedExtentScrollController _hourController;
  late final FixedExtentScrollController _minuteController;

  @override
  void initState() {
    super.initState();
    _dayController = FixedExtentScrollController(initialItem: widget.value.day - 1);
    _monthController = FixedExtentScrollController(initialItem: widget.value.month - 1);
    _yearController = FixedExtentScrollController(initialItem: widget.value.year - _yearStart);
    _hourController = FixedExtentScrollController(initialItem: widget.value.hour);
    _minuteController = FixedExtentScrollController(initialItem: widget.value.minute);
  }

  @override
  void dispose() {
    _dayController.dispose();
    _monthController.dispose();
    _yearController.dispose();
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  void _update({int? day, int? month, int? year, int? hour, int? minute}) {
    final newYear = year ?? widget.value.year;
    final newMonth = month ?? widget.value.month;
    final maxDay = _daysInMonth(newYear, newMonth);
    var newDay = day ?? widget.value.day;
    if (newDay > maxDay) {
      newDay = maxDay;
      _dayController.jumpToItem(newDay - 1);
    }
    final newHour = hour ?? widget.value.hour;
    final newMinute = minute ?? widget.value.minute;
    widget.onChanged(DateTime(newYear, newMonth, newDay, newHour, newMinute));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _itemExtent * 3,
      decoration: BoxDecoration(
        color: const Color(0xFF161210),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(15)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            child: Container(
              height: _itemExtent,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(18),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kGold.withAlpha(128)),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                flex: 1,
                child: _wheel(
                  controller: _dayController,
                  // Bounded to the currently selected month/year (not a
                  // flat 31) — otherwise e.g. February shows scrollable
                  // 29-31 entries that don't exist, silently snapping back
                  // once picked (_update's own clamp+jump below still made
                  // that safe, but showing them at all was misleading).
                  itemCount: _daysInMonth(widget.value.year, widget.value.month),
                  labelBuilder: (i) => (i + 1).toString().padLeft(2, '0'),
                  onChanged: (i) => _update(day: i + 1),
                ),
              ),
              Expanded(
                flex: 2,
                child: _wheel(
                  controller: _monthController,
                  itemCount: 12,
                  labelBuilder: (i) => azMonthsShort[i],
                  onChanged: (i) => _update(month: i + 1),
                ),
              ),
              Expanded(
                flex: 2,
                child: _wheel(
                  controller: _yearController,
                  itemCount: _yearEnd - _yearStart + 1,
                  labelBuilder: (i) => (_yearStart + i).toString(),
                  onChanged: (i) => _update(year: _yearStart + i),
                ),
              ),
              const Text(
                ':',
                style: TextStyle(color: kGold, fontSize: 28, fontWeight: FontWeight.bold),
              ),
              Expanded(
                flex: 1,
                child: _wheel(
                  controller: _hourController,
                  itemCount: 24,
                  labelBuilder: (i) => i.toString().padLeft(2, '0'),
                  onChanged: (i) => _update(hour: i),
                ),
              ),
              Expanded(
                flex: 1,
                child: _wheel(
                  controller: _minuteController,
                  itemCount: 60,
                  labelBuilder: (i) => i.toString().padLeft(2, '0'),
                  onChanged: (i) => _update(minute: i),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _wheel({
    required FixedExtentScrollController controller,
    required int itemCount,
    required String Function(int) labelBuilder,
    required ValueChanged<int> onChanged,
  }) {
    return ListWheelScrollView.useDelegate(
      controller: controller,
      itemExtent: _itemExtent,
      diameterRatio: 1.5,
      physics: const FixedExtentScrollPhysics(),
      squeeze: 1.0,
      overAndUnderCenterOpacity: 0.4,
      perspective: 0.003,
      onSelectedItemChanged: onChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: itemCount,
        builder: (context, index) {
          final selected = controller.selectedItem == index;
          return Center(
            child: Text(
              labelBuilder(index),
              style: TextStyle(
                color: selected ? Colors.white : kMuted,
                fontSize: selected ? 20 : 15,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          );
        },
      ),
    );
  }
}
