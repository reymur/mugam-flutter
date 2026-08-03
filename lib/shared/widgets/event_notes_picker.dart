import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';

// Форма одежды («GEYİM») и свободные заметки события — один виджет на два
// места: календарное окно создания/правки договора
// (agreements_screen.dart → _EventFormModal) и лист предложения работы
// (chat/screens/job_offer_date_sheet.dart).
//
// ПОЧЕМУ ОБЩИЙ, А НЕ ДВЕ КОПИИ. Заметки хранятся ОДНОЙ строкой, склеенной
// через `', '`, и разбираются обратно в галочки тем же разделителем и по
// тому же списку пунктов. Договор создаётся из предложения работы, а
// правится в календаре — то есть строку пишет один экран, а разбирает
// другой. Разойдись список пунктов или разделитель хотя бы на один
// символ, и «Qara kostyum və ağ köynək», выбранный в предложении, в
// карточке договора перестал бы опознаваться как галочка и молча уехал бы
// в свободный текст. Ошибка при этом не возникает нигде — ровно тот класс
// молчаливого расхождения, за который в реестре уже наказано дублирование
// превью (`previewText` в TS против `_previewTextFor` в Dart, B16).
//
// Отсюда правило: список пунктов и склейка/разбор живут ЗДЕСЬ и только
// здесь. Понадобился шестой пункт — добавлять сюда, оба экрана получат его
// одновременно.

/// Готовые пункты формы одежды. Ровно эти строки лежат в базе — значит
/// правка любой из них перестаёт опознавать уже сохранённые заметки и
/// роняет их в свободный текст. Менять только осознанно.
const dressCodeChoices = [
  'Qara kostyum və ağ köynək',
  'Qara köynək sərbəst',
  'Qalstuk',
  'Baboçka',
  'Yumru boğaz köynək sərbəst',
];

/// Разделитель, которым заметки склеиваются в одну строку и разбираются
/// обратно. Вынесен константой, чтобы склейка и разбор не могли разъехаться
/// даже внутри этого файла.
const _notesSeparator = ', ';

/// Разобранное состояние заметок. Владеет им родитель — так оба экрана
/// отдают строку в свою запись сами (календарь в `personalEvents`, лист
/// предложения в документ чата), а виджет не знает ни про одну из них.
class EventNotesValue {
  final List<String> options;
  final bool otherExpanded;
  final String otherNote;
  final String freeNote;

  const EventNotesValue({
    this.options = const [],
    this.otherExpanded = false,
    this.otherNote = '',
    this.freeNote = '',
  });

  /// То, что уходит в базу. Порядок частей — галочки, потом «Digər…»,
  /// потом свободная заметка; он же и восстанавливается при разборе, чтобы
  /// сохранение без единой правки не переставляло строку местами.
  String get joined {
    final parts = <String>[
      ...options,
      if (otherExpanded && otherNote.isNotEmpty) otherNote,
      if (freeNote.isNotEmpty) freeNote,
    ];
    return parts.join(_notesSeparator);
  }

  /// Разбор строки из базы. Всё, что не совпало с готовым пунктом,
  /// собирается в свободную заметку — в том числе текст, введённый когда-то
  /// через «Digər…».
  ///
  /// Различить их обратно нельзя и не нужно: в базе лежит одна строка без
  /// пометок о происхождении частей, а человеку важно видеть свой текст, а
  /// не то, в какое поле он его когда-то ввёл. Поэтому `otherExpanded`
  /// после разбора всегда false — это поведение календаря с самого начала,
  /// и оно перенесено сюда как есть.
  factory EventNotesValue.parse(String raw) {
    if (raw.isEmpty) return const EventNotesValue();
    final options = <String>[];
    var free = '';
    for (final part in raw.split(_notesSeparator)) {
      if (dressCodeChoices.contains(part)) {
        options.add(part);
      } else if (part.isNotEmpty) {
        free = free.isEmpty ? part : '$free$_notesSeparator$part';
      }
    }
    return EventNotesValue(options: options, freeNote: free);
  }

  EventNotesValue copyWith({
    List<String>? options,
    bool? otherExpanded,
    String? otherNote,
    String? freeNote,
  }) => EventNotesValue(
    options: options ?? this.options,
    otherExpanded: otherExpanded ?? this.otherExpanded,
    otherNote: otherNote ?? this.otherNote,
    freeNote: freeNote ?? this.freeNote,
  );
}

class EventNotesPicker extends StatefulWidget {
  final EventNotesValue value;
  final ValueChanged<EventNotesValue> onChanged;

  /// Показывать ли отдельное поле «ƏLAVƏ QEYDLƏR». В календаре оно есть
  /// только в режиме с участниками; лист предложения показывает его всегда
  /// — там это единственное место, куда можно написать то, чего нет в
  /// готовых пунктах, и именно его отсутствие гнало людей в голосовые.
  final bool showFreeNote;

  const EventNotesPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.showFreeNote = true,
  });

  @override
  State<EventNotesPicker> createState() => _EventNotesPickerState();
}

class _EventNotesPickerState extends State<EventNotesPicker> {
  // Контроллеры создаются один раз из начального значения и НЕ
  // пересоздаются на каждое обновление родителя: перезапись `text` при
  // живом наборе уносит курсор в конец строки на каждой букве.
  late final TextEditingController _otherController;
  late final TextEditingController _freeController;

  @override
  void initState() {
    super.initState();
    _otherController = TextEditingController(text: widget.value.otherNote);
    _freeController = TextEditingController(text: widget.value.freeNote);
  }

  @override
  void dispose() {
    _otherController.dispose();
    _freeController.dispose();
    super.dispose();
  }

  static const _sectionLabel = TextStyle(
    fontSize: 11,
    letterSpacing: 0.8,
    color: kMuted,
    fontWeight: FontWeight.w600,
  );

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: kMuted),
    filled: true,
    fillColor: kBg3,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: kBorder),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: kBorder),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: kGold),
    ),
  );

  Widget _row({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      decoration: BoxDecoration(
        color: selected ? kGold.withAlpha(25) : kBg3,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: selected ? kGold : kBorder),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: selected ? kGold : kText,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (selected)
            const Text('✓', style: TextStyle(color: kGold, fontSize: 14)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('GEYİM', style: _sectionLabel),
        const SizedBox(height: 8),
        ...dressCodeChoices.map((choice) {
          final selected = v.options.contains(choice);
          return _row(
            label: choice,
            selected: selected,
            onTap: () {
              final next = List<String>.from(v.options);
              if (selected) {
                next.remove(choice);
              } else {
                next.add(choice);
              }
              widget.onChanged(v.copyWith(options: next));
            },
          );
        }),
        _row(
          label: 'Digər...',
          selected: v.otherExpanded,
          onTap: () => widget.onChanged(
            v.copyWith(otherExpanded: !v.otherExpanded),
          ),
        ),
        if (v.otherExpanded) ...[
          const SizedBox(height: 6),
          TextField(
            controller: _otherController,
            onChanged: (t) => widget.onChanged(v.copyWith(otherNote: t)),
            style: const TextStyle(color: kText, fontSize: 14),
            decoration: _fieldDecoration('Digər əlavə...'),
          ),
        ],
        if (widget.showFreeNote) ...[
          const SizedBox(height: 16),
          const Text('ƏLAVƏ QEYDLƏR', style: _sectionLabel),
          const SizedBox(height: 8),
          TextField(
            controller: _freeController,
            onChanged: (t) => widget.onChanged(v.copyWith(freeNote: t)),
            style: const TextStyle(color: kText, fontSize: 14),
            maxLines: 3,
            decoration: _fieldDecoration('Əlavə qeyd (vacib deyil)'),
          ),
        ],
      ],
    );
  }
}
