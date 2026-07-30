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
class JobOfferDateSheet extends StatefulWidget {
  final DateTime? initialDate;
  final String? initialType;
  final String? initialLocation;
  final String? initialNotes;
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
    return Padding(
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
              'Tədbir tarixi',
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
            TextField(
              controller: _locationController,
              style: const TextStyle(color: kText),
              decoration: _fieldDecoration('Yer'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notesController,
              style: const TextStyle(color: kText),
              maxLines: 3,
              decoration: _fieldDecoration('Qeydlər'),
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
                onPressed: () {
                  widget.onSave(
                    _selectedDate,
                    _selectedType,
                    _locationController.text.trim(),
                    _notesController.text.trim(),
                  );
                  Navigator.pop(context);
                },
                child: const Text(
                  'Yadda saxla',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
