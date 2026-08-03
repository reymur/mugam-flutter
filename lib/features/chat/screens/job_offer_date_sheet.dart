import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/theme/colors.dart';
import '../../../shared/widgets/wheel_date_time_picker.dart';

// "Tarix seç/dəyiş" sheet for the "İş təklif et" negotiation banner
// (chat_screen.dart) — date+type+location+notes for a proposed job, saved
// straight to the chat doc (FirestoreService.saveChatEventDate) via onSave,
// not yet a real PersonalEvent (that only happens once the recipient
// accepts — see the onChatUpdated Cloud Function).
//
// Deliberately NOT built on agreements_screen.dart's _EventFormModal: that
// one carries multi-participant search/selection and cross-calendar
// conflict-checking neither useful nor meaningful for this fixed 2-party
// negotiation. Only the wheel date/time picker was worth sharing (see
// shared/widgets/wheel_date_time_picker.dart).
//
// Лист служит ДВУМ моментам, и различает их только подписями (пункт 3
// плана):
//   - создание предложения — «İş təklifi» / «Təklifi göndər»;
//   - правка уже отправленного — «Tədbir tarixi» / «Yadda saxla».
// Разными виджетами их разводить нечего: поля, умолчания и проверки
// совпадают полностью, различается только то, что человек делает этим
// действием. Подписи обязаны быть разными: «сохранить дату» и «отправить
// предложение» — не одно и то же, и в первом случае человек должен
// понимать, что нажатие уйдёт другому человеку.
class JobOfferDateSheet extends StatefulWidget {
  final DateTime? initialDate;
  final String? initialType;
  final String? initialLocation;
  final String? initialNotes;
  final String title;
  final String submitLabel;
  final void Function(
    DateTime date,
    String type,
    String location,
    String notes,
  )
  onSave;

  const JobOfferDateSheet({
    super.key,
    this.initialDate,
    this.initialType,
    this.initialLocation,
    this.initialNotes,
    this.title = 'Tədbir tarixi',
    this.submitLabel = 'Yadda saxla',
    required this.onSave,
  });

  @override
  State<JobOfferDateSheet> createState() => _JobOfferDateSheetState();
}

class _JobOfferDateSheetState extends State<JobOfferDateSheet> {
  static const _eventTypes = ['Toy', 'Konsert', 'Bayram', 'Digər'];

  late DateTime _selectedDate;
  late String _selectedType;
  late final TextEditingController _locationController;
  late final TextEditingController _notesController;

  // Снимок начального состояния — по нему и только по нему решается,
  // спрашивать ли при закрытии. Хранится отдельно от widget.initial*,
  // потому что там половина значений null, а сравнивать надо с тем, что
  // человек реально увидел открытым, включая умолчания.
  late final DateTime _openedWithDate;
  late final String _openedWithType;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate =
        widget.initialDate ??
        DateTime(now.year, now.month, now.day + 1, 19, 0);
    _selectedType = widget.initialType ?? _eventTypes.first;
    _locationController = TextEditingController(
      text: widget.initialLocation ?? '',
    );
    _notesController = TextEditingController(text: widget.initialNotes ?? '');
    _openedWithDate = _selectedDate;
    _openedWithType = _selectedType;
  }

  // «Лист трогали» — любое отличие от того, с чем он открылся. Пустой
  // лист закрывается молча: вопрос на пустом месте раздражает не меньше,
  // чем потеря введённого, и быстро приучает жать «да» не глядя.
  bool get _isDirty =>
      _selectedDate != _openedWithDate ||
      _selectedType != _openedWithType ||
      _locationController.text.trim() != (widget.initialLocation ?? '').trim() ||
      _notesController.text.trim() != (widget.initialNotes ?? '').trim();

  // Дата в прошлом. Проверка на отправке, а не запретом в колесе:
  // WheelDateTimePicker общий с календарём договоров, где прошлая дата
  // осмысленна (событие можно записать задним числом), и сужать его ради
  // этого экрана значило бы менять поведение там, куда мы не смотрим.
  //
  // Запрещается именно ВЫБОР прошлой даты, а не сохранение вообще: если
  // лист открыли на давно отправленном предложении, чья дата уже прошла,
  // и правят в нём только место — запрет на сохранение запер бы человека
  // в углу, требуя сдвинуть дату ради правки соседнего поля. Поэтому
  // сравнение с тем, с чем лист открылся, а не голое `isBefore(now)`.
  bool get _pastDatePicked =>
      _selectedDate != _openedWithDate && _selectedDate.isBefore(DateTime.now());

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text('Dəyişikliklər itəcək', style: TextStyle(color: kText)),
        content: const Text(
          'Yazdıqlarınız saxlanılmayacaq. Çıxmaq istəyirsiniz?',
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Geri', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Çıx', style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _submit() {
    if (_pastDatePicked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Keçmiş tarix seçilə bilməz'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    widget.onSave(
      _selectedDate,
      _selectedType,
      _locationController.text.trim(),
      _notesController.text.trim(),
    );
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _locationController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: kMuted),
    filled: true,
    fillColor: kBg3,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
  );

  @override
  Widget build(BuildContext context) {
    // canPop: false плюс ручной pop — единственный способ перехватить и
    // свайп вниз, и системную «назад» одинаково. Без этого свайп уносит
    // введённое молча, что и записано в плане как отдельное раздражение.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Навигатор берётся ДО await: после диалога ссылаться на context
        // этого build уже нельзя, а State.mounted про него ничего не
        // говорит.
        final navigator = Navigator.of(context);
        if (_isDirty && !await _confirmDiscard()) return;
        if (mounted) navigator.pop();
      },
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.title,
                style: GoogleFonts.nunito(
                  fontSize: 18,
                  color: kText,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              WheelDateTimePicker(
                value: _selectedDate,
                onChanged: (d) => setState(() => _selectedDate = d),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _eventTypes.map((type) {
                  final selected = type == _selectedType;
                  return ChoiceChip(
                    label: Text(type),
                    selected: selected,
                    onSelected: (_) => setState(() => _selectedType = type),
                    selectedColor: kGold.withAlpha(56),
                    labelStyle: TextStyle(color: selected ? kGold : kText),
                    backgroundColor: kBg3,
                    side: BorderSide(color: selected ? kGold : kBorder),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              // «vacib deyil» в подсказке — прямым текстом. Раньше о том,
              // что эти два поля можно пропустить, не было сказано нигде, и
              // человек не знал, обязан он их заполнить или нет. Дата и тип
              // такой пометки не несут намеренно: пустыми они не бывают по
              // устройству контролов, значит и вопроса не возникает.
              TextField(
                controller: _locationController,
                style: const TextStyle(color: kText),
                onChanged: (_) => setState(() {}),
                decoration: _fieldDecoration('Yer (vacib deyil)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesController,
                style: const TextStyle(color: kText),
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                decoration: _fieldDecoration('Qeydlər (vacib deyil)'),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kGold,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _submit,
                  child: Text(
                    widget.submitLabel,
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
