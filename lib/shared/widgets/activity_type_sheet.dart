import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants/musician_options.dart';
import '../../core/models/activity_type.dart';
import '../../core/theme/colors.dart';
import 'activity_type_icons.dart';

const Color _kOnGold = Color(0xFF1A0E00);

// Bottom sheet for picking "Fəaliyyət növü" — a single top-level category
// (radio) with its own checkbox-level sub-structure, some nested a level
// further (Şanson, Sintezator). Unlike the city picker (auto-pops per tap),
// this needs an explicit confirm button since a selection may involve
// several checkboxes/text fields before it's "done".
class ActivityTypeSheet extends StatefulWidget {
  final ActivityType? initial;

  const ActivityTypeSheet({super.key, this.initial});

  static Future<ActivityType?> show(
    BuildContext context, {
    ActivityType? initial,
  }) {
    return showModalBottomSheet<ActivityType>(
      context: context,
      backgroundColor: kBg2,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ActivityTypeSheet(initial: initial),
    );
  }

  @override
  State<ActivityTypeSheet> createState() => _ActivityTypeSheetState();
}

class _ActivityTypeSheetState extends State<ActivityTypeSheet> {
  ActivityCategory? _category;

  final Set<String> _simliInstruments = {};
  final Set<String> _gitaraSub = {};
  final Set<String> _sazSub = {};
  final Set<String> _nefesInstruments = {};

  bool _sintezator = false;
  final Set<String> _sintezatorRoles = {};
  bool _qarmon = false;
  bool _qarmonSoloSintez = false;

  final Set<String> _muganniRoles = {};
  late final TextEditingController _muganniDigerController;
  final Set<String> _sansonSub = {};
  late final TextEditingController _sansonDigerController;

  final Set<String> _zerbInstruments = {};
  late final TextEditingController _zerbDigerController;

  bool _sesDiger = false;
  late final TextEditingController _sesDigerController;

  bool _videoDiger = false;
  late final TextEditingController _videoDigerController;

  bool _sekilDiger = false;
  late final TextEditingController _sekilDigerController;

  bool _isiqDiger = false;
  late final TextEditingController _isiqDigerController;

  @override
  void initState() {
    super.initState();
    _muganniDigerController = TextEditingController();
    _sansonDigerController = TextEditingController();
    _zerbDigerController = TextEditingController();
    _sesDigerController = TextEditingController();
    _videoDigerController = TextEditingController();
    _sekilDigerController = TextEditingController();
    _isiqDigerController = TextEditingController();

    final initial = widget.initial;
    if (initial == null) return;
    _category = initial.category;
    switch (initial.category) {
      case ActivityCategory.simli:
        _simliInstruments.addAll(initial.simli!.instruments);
        _gitaraSub.addAll(initial.simli!.gitaraSub);
        _sazSub.addAll(initial.simli!.sazSub);
      case ActivityCategory.nefes:
        _nefesInstruments.addAll(initial.nefes!.instruments);
      case ActivityCategory.klavish:
        final k = initial.klavish!;
        _sintezator = k.sintezator;
        _sintezatorRoles.addAll(k.sintezatorRoles);
        _qarmon = k.qarmon;
        _qarmonSoloSintez = k.qarmonSoloSintez;
      case ActivityCategory.muganni:
        final m = initial.muganni!;
        _muganniRoles.addAll(m.roles);
        _muganniDigerController.text = m.digerNote.note;
        _sansonSub.addAll(m.sansonSub);
        _sansonDigerController.text = m.sansonDigerNote.note;
      case ActivityCategory.zerb:
        final z = initial.zerb!;
        _zerbInstruments.addAll(z.instruments);
        _zerbDigerController.text = z.digerNote.note;
      case ActivityCategory.sesSistemleri:
        final d = initial.sesSistemleri!.digerNote;
        _sesDiger = d.selected;
        _sesDigerController.text = d.note;
      case ActivityCategory.videoCekilis:
        final d = initial.videoCekilis!.digerNote;
        _videoDiger = d.selected;
        _videoDigerController.text = d.note;
      case ActivityCategory.sekil:
        final d = initial.sekil!.digerNote;
        _sekilDiger = d.selected;
        _sekilDigerController.text = d.note;
      case ActivityCategory.isiqSistemleri:
        final d = initial.isiqSistemleri!.digerNote;
        _isiqDiger = d.selected;
        _isiqDigerController.text = d.note;
    }
  }

  @override
  void dispose() {
    _muganniDigerController.dispose();
    _sansonDigerController.dispose();
    _zerbDigerController.dispose();
    _sesDigerController.dispose();
    _videoDigerController.dispose();
    _sekilDigerController.dispose();
    _isiqDigerController.dispose();
    super.dispose();
  }

  ActivityType? _buildResult() {
    switch (_category) {
      case null:
        return null;
      case ActivityCategory.simli:
        return ActivityType.simliOf(
          SimliDetails(
            instruments: _simliInstruments,
            gitaraSub: _gitaraSub,
            sazSub: _sazSub,
          ),
        );
      case ActivityCategory.nefes:
        return ActivityType.nefesOf(
          NefesDetails(instruments: _nefesInstruments),
        );
      case ActivityCategory.klavish:
        return ActivityType.klavishOf(
          KlavishDetails(
            sintezator: _sintezator,
            sintezatorRoles: _sintezatorRoles,
            qarmon: _qarmon,
            qarmonSoloSintez: _qarmonSoloSintez,
          ),
        );
      case ActivityCategory.muganni:
        return ActivityType.muganniOf(
          MuganniDetails(
            roles: _muganniRoles,
            digerNote: DigerNote(
              selected: _muganniRoles.contains('Digər'),
              note: _muganniDigerController.text.trim(),
            ),
            sansonSub: _sansonSub,
            sansonDigerNote: DigerNote(
              selected: _sansonSub.contains('Digər'),
              note: _sansonDigerController.text.trim(),
            ),
          ),
        );
      case ActivityCategory.zerb:
        return ActivityType.zerbOf(
          ZerbDetails(
            instruments: _zerbInstruments,
            digerNote: DigerNote(
              selected: _zerbInstruments.contains('Digər'),
              note: _zerbDigerController.text.trim(),
            ),
          ),
        );
      case ActivityCategory.sesSistemleri:
        return ActivityType.sesSistemleriOf(
          SingleDigerDetails(
            digerNote: DigerNote(
              selected: _sesDiger,
              note: _sesDigerController.text.trim(),
            ),
          ),
        );
      case ActivityCategory.videoCekilis:
        return ActivityType.videoCekilisOf(
          SingleDigerDetails(
            digerNote: DigerNote(
              selected: _videoDiger,
              note: _videoDigerController.text.trim(),
            ),
          ),
        );
      case ActivityCategory.sekil:
        return ActivityType.sekilOf(
          SingleDigerDetails(
            digerNote: DigerNote(
              selected: _sekilDiger,
              note: _sekilDigerController.text.trim(),
            ),
          ),
        );
      case ActivityCategory.isiqSistemleri:
        return ActivityType.isiqSistemleriOf(
          SingleDigerDetails(
            digerNote: DigerNote(
              selected: _isiqDiger,
              note: _isiqDigerController.text.trim(),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: const BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 24,
              offset: Offset(0, -6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 3.5,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Fəaliyyət növü',
                    style: GoogleFonts.nunito(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: kText,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'KATEQORİYANI SEÇİN',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.8,
                      color: kMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: kBorder.withValues(alpha: 0.6)),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final cat in ActivityCategory.values)
                      _buildCategoryBlock(
                        cat,
                        isLast: cat == ActivityCategory.values.last,
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: _category == null
                        ? const []
                        : [
                            BoxShadow(
                              color: kGold.withValues(alpha: 0.25),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                  ),
                  child: ElevatedButton(
                    onPressed: _category == null
                        ? null
                        : () => Navigator.of(context).pop(_buildResult()),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      disabledBackgroundColor: kGold.withValues(alpha: 0.3),
                      foregroundColor: _kOnGold,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Təsdiqlə',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryBlock(ActivityCategory cat, {required bool isLast}) {
    final selected = _category == cat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: selected ? Border.all(color: kGold, width: 2) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(14),
                // Selection is already shown by the block/icon border — the
                // default gold-tinted splash just reads as a smear over the
                // photo when a screenshot lands mid-fade.
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                onTap: () => setState(() => _category = selected ? null : cat),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      _iconChip(cat, selected),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          ActivityType.categoryLabels[cat]!,
                          style: TextStyle(
                            fontSize: 15.5,
                            color: selected ? kGold : kText,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _radioIndicator(selected),
                    ],
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: selected
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                        child: _contentFor(cat),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
        if (!isLast)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Divider(
              height: 1,
              thickness: 1,
              color: kBorder.withValues(alpha: 0.4),
            ),
          ),
      ],
    );
  }

  Widget _iconChip(ActivityCategory cat, bool selected) {
    // The glyph is a full-bleed photo now (not a small icon on a filled
    // background), so selection shows as a border around it rather than a
    // background-color swap — the photo itself covers the whole chip.
    //
    // The clip and the border are deliberately two separate layers (not one
    // AnimatedContainer with both `clipBehavior` and a rounded `border`) —
    // that combination renders with a soft glow bleeding past the corners
    // under Impeller (iOS), even though it's pixel-perfect on Skia/web.
    return SizedBox(
      width: 34,
      height: 34,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(color: kCard, child: categoryGlyph(cat, size: 34)),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? kGold : kBorder, width: selected ? 2 : 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _radioIndicator(bool selected) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? kGold : kBorder, width: 1.6),
      ),
      alignment: Alignment.center,
      child: AnimatedScale(
        scale: selected ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: Container(
          width: 11,
          height: 11,
          decoration: const BoxDecoration(
            color: kGold,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Widget _contentFor(ActivityCategory cat) {
    switch (cat) {
      case ActivityCategory.simli:
        return _simliContent();
      case ActivityCategory.nefes:
        return _multiSelectColumn(kNefesInstruments, _nefesInstruments);
      case ActivityCategory.klavish:
        return _klavishContent();
      case ActivityCategory.muganni:
        return _muganniContent();
      case ActivityCategory.zerb:
        return _zerbContent();
      case ActivityCategory.sesSistemleri:
        return _singleDigerContent(
          selected: _sesDiger,
          controller: _sesDigerController,
          onChanged: (v) => setState(() {
            _sesDiger = v;
            if (!v) _sesDigerController.clear();
          }),
        );
      case ActivityCategory.videoCekilis:
        return _singleDigerContent(
          selected: _videoDiger,
          controller: _videoDigerController,
          onChanged: (v) => setState(() {
            _videoDiger = v;
            if (!v) _videoDigerController.clear();
          }),
        );
      case ActivityCategory.sekil:
        return _singleDigerContent(
          selected: _sekilDiger,
          controller: _sekilDigerController,
          onChanged: (v) => setState(() {
            _sekilDiger = v;
            if (!v) _sekilDigerController.clear();
          }),
        );
      case ActivityCategory.isiqSistemleri:
        return _singleDigerContent(
          selected: _isiqDiger,
          controller: _isiqDigerController,
          onChanged: (v) => setState(() {
            _isiqDiger = v;
            if (!v) _isiqDigerController.clear();
          }),
        );
    }
  }

  Widget _multiSelectColumn(List<String> options, Set<String> selectedSet) {
    return Column(
      children: options
          .map(
            (o) => _checkboxRow(
              label: o,
              value: selectedSet.contains(o),
              onChanged: (v) => setState(() {
                if (v) {
                  selectedSet.add(o);
                } else {
                  selectedSet.remove(o);
                }
              }),
            ),
          )
          .toList(),
    );
  }

  // instr == 'Gitara'/'Saz' are the two Simli leaves with their own nested
  // sub-options (kGitaraSubOptions/kSazSubOptions) — everything else in
  // kSimliInstruments is a plain leaf.
  static const Map<String, List<String>> _simliSubOptions = {
    'Gitara': kGitaraSubOptions,
    'Saz': kSazSubOptions,
  };

  Set<String> _simliSubSetFor(String instr) =>
      instr == 'Gitara' ? _gitaraSub : _sazSub;

  Widget _simliContent() {
    return Column(
      children: [
        for (final instr in kSimliInstruments) ...[
          _checkboxRow(
            label: instr,
            value: _simliInstruments.contains(instr),
            onChanged: (v) => setState(() {
              if (v) {
                _simliInstruments.add(instr);
              } else {
                _simliInstruments.remove(instr);
                if (_simliSubOptions.containsKey(instr)) {
                  _simliSubSetFor(instr).clear();
                }
              }
            }),
          ),
          _revealChildren(
            _simliSubOptions.containsKey(instr) &&
                _simliInstruments.contains(instr),
            (_simliSubOptions[instr] ?? const []).map((s) {
              final subSet = _simliSubSetFor(instr);
              return _checkboxRow(
                label: s,
                value: subSet.contains(s),
                indent: 28,
                nested: true,
                onChanged: (v) => setState(() {
                  if (v) {
                    subSet.add(s);
                  } else {
                    subSet.remove(s);
                  }
                }),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  Widget _klavishContent() {
    return Column(
      children: [
        _checkboxRow(
          label: 'Sintezator',
          value: _sintezator,
          onChanged: (v) => setState(() {
            _sintezator = v;
            if (!v) _sintezatorRoles.clear();
          }),
        ),
        _revealChildren(
          _sintezator,
          kSintezatorRoles
              .map(
                (r) => _checkboxRow(
                  label: r,
                  value: _sintezatorRoles.contains(r),
                  indent: 28,
                  nested: true,
                  onChanged: (v) => setState(() {
                    if (v) {
                      _sintezatorRoles.add(r);
                    } else {
                      _sintezatorRoles.remove(r);
                    }
                  }),
                ),
              )
              .toList(),
        ),
        _checkboxRow(
          label: 'Qarmon',
          value: _qarmon,
          onChanged: (v) => setState(() {
            _qarmon = v;
            if (!v) _qarmonSoloSintez = false;
          }),
        ),
        _revealChildren(_qarmon, [
          _checkboxRow(
            label: 'Solo sintez',
            value: _qarmonSoloSintez,
            indent: 28,
            nested: true,
            onChanged: (v) => setState(() => _qarmonSoloSintez = v),
          ),
        ]),
      ],
    );
  }

  Widget _muganniContent() {
    return Column(
      children: [
        for (final role in kMuganniRoles) ...[
          _checkboxRow(
            label: role,
            value: _muganniRoles.contains(role),
            onChanged: (v) => setState(() {
              if (v) {
                _muganniRoles.add(role);
              } else {
                _muganniRoles.remove(role);
                if (role == 'Şanson') {
                  _sansonSub.clear();
                  _sansonDigerController.clear();
                }
                if (role == 'Digər') _muganniDigerController.clear();
              }
            }),
          ),
          if (role == 'Şanson')
            _revealChildren(_muganniRoles.contains('Şanson'), [
              for (final s in kSansonSubOptions) ...[
                _checkboxRow(
                  label: s,
                  value: _sansonSub.contains(s),
                  indent: 28,
                  nested: true,
                  onChanged: (v) => setState(() {
                    if (v) {
                      _sansonSub.add(s);
                    } else {
                      _sansonSub.remove(s);
                      if (s == 'Digər') _sansonDigerController.clear();
                    }
                  }),
                ),
                _revealChildren(
                  s == 'Digər' && _sansonSub.contains('Digər'),
                  [_digerField(_sansonDigerController, indent: 48)],
                ),
              ],
            ]),
          if (role == 'Digər')
            _revealChildren(_muganniRoles.contains('Digər'), [
              _digerField(_muganniDigerController, indent: 28),
            ]),
        ],
      ],
    );
  }

  Widget _zerbContent() {
    return Column(
      children: [
        for (final instr in kZerbInstruments) ...[
          _checkboxRow(
            label: instr,
            value: _zerbInstruments.contains(instr),
            onChanged: (v) => setState(() {
              if (v) {
                _zerbInstruments.add(instr);
              } else {
                _zerbInstruments.remove(instr);
                if (instr == 'Digər') _zerbDigerController.clear();
              }
            }),
          ),
          if (instr == 'Digər')
            _revealChildren(_zerbInstruments.contains('Digər'), [
              _digerField(_zerbDigerController, indent: 28),
            ]),
        ],
      ],
    );
  }

  Widget _singleDigerContent({
    required bool selected,
    required TextEditingController controller,
    required ValueChanged<bool> onChanged,
  }) {
    return Column(
      children: [
        _checkboxRow(label: 'Digər', value: selected, onChanged: onChanged),
        _revealChildren(selected, [_digerField(controller, indent: 28)]),
      ],
    );
  }

  // Persists the AnimatedSize node across rebuilds (only its inner child
  // swaps between real content and an empty placeholder) so every
  // expand/collapse at any nesting level animates, not just the top-level
  // category.
  Widget _revealChildren(bool visible, List<Widget> children) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: visible
          ? Column(children: children)
          : const SizedBox(width: double.infinity),
    );
  }

  Widget _checkboxRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    double indent = 0,
    bool nested = false,
  }) {
    final row = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: Row(
          children: [
            _checkboxIndicator(value),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: nested ? 13 : 14,
                  color: value ? kGold : (nested ? kMuted : kText),
                  fontWeight: value ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return _withGuide(indent, row);
  }

  Widget _checkboxIndicator(bool value) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: value ? kGold : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: value ? kGold : kBorder, width: 1.4),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 140),
        transitionBuilder: (child, anim) => ScaleTransition(
          scale: anim,
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: value
            ? const Icon(
                Icons.check_rounded,
                key: ValueKey('checked'),
                size: 13,
                color: _kOnGold,
              )
            : const SizedBox.shrink(key: ValueKey('unchecked')),
      ),
    );
  }

  // Wraps nested (indent > 0) content with a thin tree-connector line on its
  // left so the eye can tell a leaf's nesting depth apart at a glance, even
  // with several levels expanded at once — plain indentation alone reads
  // ambiguously once more than one level is open.
  Widget _withGuide(double indent, Widget child) {
    if (indent <= 0) return child;
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 1.4,
              margin: const EdgeInsets.only(right: 12),
              color: kBorder.withValues(alpha: 0.6),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }

  Widget _digerField(TextEditingController controller, {double indent = 0}) {
    final field = Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8, right: 2),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: kText, fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Dəqiqləşdirin (istəyə bağlı)',
          hintStyle: const TextStyle(color: kMuted, fontSize: 13),
          filled: true,
          fillColor: kCard,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
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
            borderSide: const BorderSide(color: kGold, width: 1.5),
          ),
        ),
      ),
    );
    return _withGuide(indent, field);
  }
}
