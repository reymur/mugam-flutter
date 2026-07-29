import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants/musician_options.dart';
import '../../core/models/activity_type.dart';
import '../../core/theme/colors.dart';
import 'activity_type_icons.dart';

const Color _kOnGold = Color(0xFF1A0E00);

// Full-screen "Fəaliyyət növü" picker — a single top-level category (radio)
// with its own checkbox-level sub-structure, some nested a level further
// (Şanson, Sintezator). Replaces the old showModalBottomSheet flow with a
// pushed page: same single-category-active selection model and the same
// ActivityType result contract, just a different chrome (card-per-category
// with a photo glyph + counts, instead of a plain list row).
class ActivityTypeScreen extends StatefulWidget {
  final ActivityType? initial;

  const ActivityTypeScreen({super.key, this.initial});

  static Future<ActivityType?> push(
    BuildContext context, {
    ActivityType? initial,
  }) {
    return Navigator.of(context).push<ActivityType>(
      MaterialPageRoute(builder: (_) => ActivityTypeScreen(initial: initial)),
    );
  }

  @override
  State<ActivityTypeScreen> createState() => _ActivityTypeScreenState();
}

class _ActivityTypeScreenState extends State<ActivityTypeScreen> {
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

  // Every field belongs to exactly one category — _buildResult() only ever
  // reads the fields matching `_category`. Clearing the outgoing category's
  // fields on every switch keeps the (now visible, per-card) "N seçildi"
  // counts from showing stale leftovers on a card that isn't the answer.
  void _resetFieldsFor(ActivityCategory cat) {
    switch (cat) {
      case ActivityCategory.simli:
        _simliInstruments.clear();
        _gitaraSub.clear();
        _sazSub.clear();
      case ActivityCategory.nefes:
        _nefesInstruments.clear();
      case ActivityCategory.klavish:
        _sintezator = false;
        _sintezatorRoles.clear();
        _qarmon = false;
        _qarmonSoloSintez = false;
      case ActivityCategory.muganni:
        _muganniRoles.clear();
        _muganniDigerController.clear();
        _sansonSub.clear();
        _sansonDigerController.clear();
      case ActivityCategory.zerb:
        _zerbInstruments.clear();
        _zerbDigerController.clear();
      case ActivityCategory.sesSistemleri:
        _sesDiger = false;
        _sesDigerController.clear();
      case ActivityCategory.videoCekilis:
        _videoDiger = false;
        _videoDigerController.clear();
      case ActivityCategory.sekil:
        _sekilDiger = false;
        _sekilDigerController.clear();
      case ActivityCategory.isiqSistemleri:
        _isiqDiger = false;
        _isiqDigerController.clear();
    }
  }

  void _toggleCategory(ActivityCategory cat) {
    setState(() {
      if (_category == cat) {
        _category = null;
        return;
      }
      if (_category != null) _resetFieldsFor(_category!);
      _category = cat;
    });
  }

  int _totalFor(ActivityCategory cat) => switch (cat) {
    ActivityCategory.simli => kSimliInstruments.length,
    ActivityCategory.nefes => kNefesInstruments.length,
    ActivityCategory.klavish => 2, // Sintezator, Qarmon
    ActivityCategory.muganni => kMuganniRoles.length,
    ActivityCategory.zerb => kZerbInstruments.length,
    ActivityCategory.sesSistemleri ||
    ActivityCategory.videoCekilis ||
    ActivityCategory.sekil ||
    ActivityCategory.isiqSistemleri => 1,
  };

  String _unitFor(ActivityCategory cat) => switch (cat) {
    ActivityCategory.simli ||
    ActivityCategory.nefes ||
    ActivityCategory.klavish ||
    ActivityCategory.zerb => 'alət',
    _ => 'xidmət',
  };

  int _selectedCountFor(ActivityCategory cat) => switch (cat) {
    ActivityCategory.simli =>
      _simliInstruments.length + _gitaraSub.length + _sazSub.length,
    ActivityCategory.nefes => _nefesInstruments.length,
    ActivityCategory.klavish =>
      (_sintezator ? 1 : 0) +
          _sintezatorRoles.length +
          (_qarmon ? 1 : 0) +
          (_qarmonSoloSintez ? 1 : 0),
    ActivityCategory.muganni => _muganniRoles.length + _sansonSub.length,
    ActivityCategory.zerb => _zerbInstruments.length,
    ActivityCategory.sesSistemleri => _sesDiger ? 1 : 0,
    ActivityCategory.videoCekilis => _videoDiger ? 1 : 0,
    ActivityCategory.sekil => _sekilDiger ? 1 : 0,
    ActivityCategory.isiqSistemleri => _isiqDiger ? 1 : 0,
  };

  // Categories rendered as a grid of selectable chips (matching the
  // reference design) — every category with a real leaf list, vs. the 4
  // sesSistemleri/videoCekilis/sekil/isiqSistemleri categories, which are
  // just a single optional "Digər" note and don't read as a "pick from N"
  // list at all.
  bool _isGridCategory(ActivityCategory cat) =>
      cat == ActivityCategory.simli ||
      cat == ActivityCategory.nefes ||
      cat == ActivityCategory.klavish ||
      cat == ActivityCategory.muganni ||
      cat == ActivityCategory.zerb;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  children: [
                    for (final cat in ActivityCategory.values)
                      _buildCategoryCard(cat),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _confirmButton(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 20, 16),
      child: Column(
        children: [
          Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: kBg2,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.chevron_left_rounded,
                    color: kText,
                    size: 24,
                  ),
                ),
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Fəaliyyət növü',
            style: GoogleFonts.nunito(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: kText,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Hansı xidməti göstərirsiniz?',
            style: TextStyle(fontSize: 13.5, color: kMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryCard(ActivityCategory cat) {
    final selected = _category == cat;
    final count = _selectedCountFor(cat);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: selected ? kGold : kBorder, width: selected ? 1.6 : 1),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(18),
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            onTap: () => _toggleCategory(cat),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  _iconChip(cat, selected),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ActivityType.categoryLabels[cat]!,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: selected ? kGold : kText,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_totalFor(cat)} ${_unitFor(cat)}',
                          style: const TextStyle(fontSize: 12.5, color: kMuted),
                        ),
                      ],
                    ),
                  ),
                  if (selected && count > 0) ...[
                    _countBadge(count),
                    const SizedBox(width: 8),
                  ],
                  _chevronButton(selected),
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
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Divider(height: 1, color: kBorder.withValues(alpha: 0.5)),
                        const SizedBox(height: 12),
                        _contentFor(cat),
                        if (_isGridCategory(cat)) _gridFooter(cat),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _countBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: kGoldDim,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kGold.withValues(alpha: 0.5)),
      ),
      child: Text(
        '$count seçildi',
        style: const TextStyle(fontSize: 11.5, color: kGold, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _chevronButton(bool expanded) {
    return AnimatedRotation(
      turns: expanded ? 0.5 : 0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: kBg2,
          shape: BoxShape.circle,
          border: Border.all(color: kBorder),
        ),
        child: const Icon(Icons.keyboard_arrow_down_rounded, color: kMuted, size: 20),
      ),
    );
  }

  Widget _gridFooter(ActivityCategory cat) {
    final count = _selectedCountFor(cat);
    final total = _totalFor(cat);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$count / $total ${_unitFor(cat)} seçildi',
            style: const TextStyle(fontSize: 12.5, color: kMuted),
          ),
          if (count > 0)
            InkWell(
              onTap: () => setState(() => _resetFieldsFor(cat)),
              child: const Text(
                'Təmizlə',
                style: TextStyle(fontSize: 12.5, color: kGold, fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }

  // Same clip/border-as-separate-layers structure as the old bottom sheet's
  // icon chip — combining `border` with `clipBehavior` on one AnimatedContainer
  // glows past the corners under Impeller (iOS) despite being pixel-perfect
  // on Skia/web.
  Widget _iconChip(ActivityCategory cat, bool selected) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(color: kBg2, child: categoryGlyph(cat, size: 44)),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: selected ? kGold : kBorder, width: selected ? 2 : 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _confirmButton() {
    final enabled = _category != null;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled ? 1 : 0.45,
      child: IgnorePointer(
        ignoring: !enabled,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(context).pop(_buildResult()),
          child: Container(
            height: 56,
            padding: const EdgeInsets.only(left: 18, right: 6),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [kGold2, kGold]),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome_rounded, size: 18, color: _kOnGold),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Təsdiqlə',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _kOnGold),
                  ),
                ),
                Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(color: _kOnGold, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: const Icon(Icons.arrow_forward_rounded, color: kGold, size: 18),
                ),
              ],
            ),
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
        return _leafGrid(
          options: kNefesInstruments,
          isSelected: (o) => _nefesInstruments.contains(o),
          onToggle: (o, now) {
            if (now) {
              _nefesInstruments.add(o);
            } else {
              _nefesInstruments.remove(o);
            }
          },
        );
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

  // Shared shape for every leaf-list category: a 3-column grid of chips,
  // each optionally revealing its own sub-content (a nested toggle wrap, a
  // "Digər" text field, ...) right below it when selected. Every "pick
  // one/many things" category fits this — simli/klavish/muganni's nested
  // extra content is what used to make them look bespoke, but the nesting
  // itself is the same shape as simli's Gitara/Saz sub-options either way.
  //
  // `mainAxisExtent` (a fixed pixel height) rather than `childAspectRatio` —
  // aspect-ratio-derived height depends on the grid's available width, which
  // this screen doesn't have a fixed value for, and got this badly wrong
  // once already (tall, sparse-looking cells).
  Widget _leafGrid({
    required List<String> options,
    required bool Function(String leaf) isSelected,
    required void Function(String leaf, bool nowSelected) onToggle,
    Widget? Function(String leaf)? extraFor,
  }) {
    return Column(
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: options.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 46,
          ),
          itemBuilder: (context, i) {
            final o = options[i];
            final sel = isSelected(o);
            return _gridChip(o, sel, () => setState(() => onToggle(o, !sel)));
          },
        ),
        for (final o in options)
          if (extraFor?.call(o) != null)
            _revealChildren(isSelected(o), [
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: extraFor!(o)!,
              ),
            ]),
      ],
    );
  }

  // Compact toggle-chip row for a leaf's own sub-options (Gitara→Milli/
  // Akustik, Sintezator→Müşayətçi/Solo, Şanson→Rus dilində/Digər). Not a
  // _leafGrid itself — no per-item glyph, no further nesting inside a
  // single wrap row (the one exception, Şanson→Digər→text field, is
  // composed by hand in _muganniContent instead of trying to generalize
  // this to arbitrary depth).
  Widget _subToggleWrap(
    List<String> options,
    Set<String> selectedSet, {
    void Function(String leaf, bool nowSelected)? onToggleExtra,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final s in options)
            _smallToggleChip(
              s,
              selectedSet.contains(s),
              () => setState(() {
                final now = !selectedSet.contains(s);
                if (now) {
                  selectedSet.add(s);
                } else {
                  selectedSet.remove(s);
                }
                onToggleExtra?.call(s, now);
              }),
            ),
        ],
      ),
    );
  }

  Widget _gridChip(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? kGoldDim : kCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? kGold : kBorder, width: selected ? 1.6 : 1),
            ),
            child: Row(
              children: [
                instrumentGlyph(label, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected ? kGold : kText,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (selected)
            Positioned(
              left: -6,
              top: -6,
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(color: kGold, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: const Icon(Icons.check_rounded, size: 12, color: _kOnGold),
              ),
            ),
        ],
      ),
    );
  }

  // Compact pill for a leaf's own sub-options (Gitara→Milli/Akustik,
  // Saz→Milli/Türk) — smaller than the main grid chip since it's a second
  // level of nesting, no per-instrument glyph.
  Widget _smallToggleChip(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? kGoldDim : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? kGold : kBorder, width: selected ? 1.4 : 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? kGold : kMuted,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
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
    return _leafGrid(
      options: kSimliInstruments,
      isSelected: (o) => _simliInstruments.contains(o),
      onToggle: (o, now) {
        if (now) {
          _simliInstruments.add(o);
        } else {
          _simliInstruments.remove(o);
          if (_simliSubOptions.containsKey(o)) _simliSubSetFor(o).clear();
        }
      },
      extraFor: (o) => _simliSubOptions.containsKey(o)
          ? _subToggleWrap(_simliSubOptions[o]!, _simliSubSetFor(o))
          : null,
    );
  }

  Widget _zerbContent() {
    return _leafGrid(
      options: kZerbInstruments,
      isSelected: (o) => _zerbInstruments.contains(o),
      onToggle: (o, now) {
        if (now) {
          _zerbInstruments.add(o);
        } else {
          _zerbInstruments.remove(o);
          if (o == 'Digər') _zerbDigerController.clear();
        }
      },
      extraFor: (o) => o == 'Digər' ? _digerField(_zerbDigerController) : null,
    );
  }

  static const List<String> _klavishOptions = ['Sintezator', 'Qarmon'];

  Widget _klavishContent() {
    return _leafGrid(
      options: _klavishOptions,
      isSelected: (o) => o == 'Sintezator' ? _sintezator : _qarmon,
      onToggle: (o, now) {
        if (o == 'Sintezator') {
          _sintezator = now;
          if (!now) _sintezatorRoles.clear();
        } else {
          _qarmon = now;
          if (!now) _qarmonSoloSintez = false;
        }
      },
      extraFor: (o) => o == 'Sintezator'
          ? _subToggleWrap(kSintezatorRoles, _sintezatorRoles)
          : Align(
              alignment: Alignment.centerLeft,
              child: _smallToggleChip(
                'Solo sintez',
                _qarmonSoloSintez,
                () => setState(() => _qarmonSoloSintez = !_qarmonSoloSintez),
              ),
            ),
    );
  }

  Widget _muganniContent() {
    return _leafGrid(
      options: kMuganniRoles,
      isSelected: (o) => _muganniRoles.contains(o),
      onToggle: (o, now) {
        if (now) {
          _muganniRoles.add(o);
        } else {
          _muganniRoles.remove(o);
          if (o == 'Şanson') {
            _sansonSub.clear();
            _sansonDigerController.clear();
          }
          if (o == 'Digər') _muganniDigerController.clear();
        }
      },
      extraFor: (o) {
        if (o == 'Şanson') {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _subToggleWrap(
                kSansonSubOptions,
                _sansonSub,
                onToggleExtra: (s, now) {
                  if (!now && s == 'Digər') _sansonDigerController.clear();
                },
              ),
              _revealChildren(_sansonSub.contains('Digər'), [
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _digerField(_sansonDigerController),
                ),
              ]),
            ],
          );
        }
        if (o == 'Digər') return _digerField(_muganniDigerController);
        return null;
      },
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
          fillColor: kBg2,
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
