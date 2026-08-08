import 'package:flutter/material.dart';

import '../../../core/models/activity_type.dart';
import '../../../core/search/algolia_filter_utils.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/activity_type_screen.dart';
import '../../../shared/widgets/city_picker_sheet.dart';


// Search-screen filter state — all optional/AND-combined by whoever reads
// this (SearchScreen._matches). minRating uses the sheet's fixed steps
// (0/3/4/4.5) as the actual value, so "no rating filter" is just 0 rather
// than a separate nullable flag.
class SearchFilters {
  final String? city;
  final ActivityType? activityType;
  final double minRating;
  final bool onlyAvailable;
  final bool onlyOnline;

  const SearchFilters({
    this.city,
    this.activityType,
    this.minRating = 0,
    this.onlyAvailable = false,
    this.onlyOnline = false,
  });

  int get activeCount => [
    city != null,
    activityType != null,
    minRating > 0,
    onlyAvailable,
    onlyOnline,
  ].where((v) => v).length;

  bool get isEmpty => activeCount == 0;

  // Nullable fields need to distinguish "leave unchanged" from "explicitly
  // clear to null" — a plain `String? city` param can't do that (passing
  // null would mean both). Wrapping in a function makes "not passed" (no
  // wrapper) distinguishable from "passed null" (wrapper returning null).
  SearchFilters copyWith({
    String? Function()? city,
    ActivityType? Function()? activityType,
    double? minRating,
    bool? onlyAvailable,
    bool? onlyOnline,
  }) {
    return SearchFilters(
      city: city != null ? city() : this.city,
      activityType: activityType != null ? activityType() : this.activityType,
      minRating: minRating ?? this.minRating,
      onlyAvailable: onlyAvailable ?? this.onlyAvailable,
      onlyOnline: onlyOnline ?? this.onlyOnline,
    );
  }

  // Algolia `filters` expression (not `facetFilters`) — this needs to mix
  // exact match (city), array-contains (activityInstruments, as an OR
  // group), boolean (available/online) and a numeric range (rating) in one
  // AND-combined expression, which `filters` supports and `facetFilters`
  // doesn't. excludeUid keeps the signed-in user out of their own search
  // results, same as search_screen.dart's old `u.id != currentUid` check.
  //
  // The OR group for instruments mirrors the "any overlapping instrument"
  // semantics the old client-side _matches had
  // (wanted.any(userInstruments.contains)) — a user matches if they have
  // at least one of the selected activity type's leaf instruments, not all
  // of them.
  String toAlgoliaFilters(String excludeUid) =>
      toAlgoliaFiltersExcluding([excludeUid]);

  // Same as toAlgoliaFilters, but for callers excluding more than one uid
  // (e.g. a group's existing members, or already-selected participants) —
  // one NOT objectID clause per uid, AND-joined with the rest.
  String toAlgoliaFiltersExcluding(Iterable<String> excludeUids) {
    final clauses = <String>[...excludeUidsClauses(excludeUids)];
    if (city != null) clauses.add('city:"${escapeAlgoliaFilterValue(city!)}"');
    if (minRating > 0) clauses.add('rating >= $minRating');
    if (onlyAvailable) clauses.add('available:true');
    if (onlyOnline) {
      // Raw `online:true` alone is stale the same way the Firestore field
      // itself is (see User.isActuallyOnline, lib/firebase/models.dart) —
      // PresenceService's heartbeat pauses rather than clears it on
      // backgrounding, so a long-backgrounded user can stay `online: true`
      // in the index indefinitely. Re-deriving isActuallyOnline's own
      // "online AND lastSeen within the last onlineGracePeriod" check here,
      // against the lastSeen (epoch millis) toAlgoliaUserRecord denormalizes
      // (functions/src/algoliaShared.ts), keeps this filter's notion of
      // "online" consistent with what the rest of the app already shows.
      // onlineQueryWindow, а не onlineGracePeriod: у запроса окно одно на
      // всех (см. константу), тогда как у каждой сборки оно своё.
      final threshold = DateTime.now()
          .subtract(User.onlineQueryWindow)
          .millisecondsSinceEpoch;
      clauses.add('online:true AND lastSeen > $threshold');
    }

    final wanted = activityType?.toSearchableInstruments() ?? const [];
    if (wanted.isNotEmpty) {
      final orGroup = wanted
          .map((i) => 'activityInstruments:"${escapeAlgoliaFilterValue(i)}"')
          .join(' OR ');
      clauses.add('($orGroup)');
    }

    return clauses.join(' AND ');
  }
}

// Bottom sheet for refining a user search — reuses CityPickerSheet and
// ActivityTypeScreen as-is rather than building parallel pickers, so a
// change to either stays in sync everywhere it's used (profile, this
// filter, ...) instead of drifting.
class FilterSheet extends StatefulWidget {
  final SearchFilters initial;
  final TextEditingController nameController;

  const FilterSheet({
    super.key,
    required this.initial,
    required this.nameController,
  });

  static Future<SearchFilters?> show(
    BuildContext context, {
    required SearchFilters initial,
    required TextEditingController nameController,
  }) {
    return showModalBottomSheet<SearchFilters>(
      // Тап по затемнённому фону не закрывает: по нему легко попасть,
      // целясь в поле формы, и терять введённое из-за промаха обидно.
      // Свайп и кнопка отмены закрывают как обычно — они делаются
      // намеренно. Одно правило на все листы С ВВОДОМ (N28).
      isDismissible: false,
      context: context,
      backgroundColor: kBg2,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FilterSheet(initial: initial, nameController: nameController),
    );
  }

  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late SearchFilters _filters;

  static const _ratingSteps = [0.0, 3.0, 4.0, 4.5];

  @override
  void initState() {
    super.initState();
    _filters = widget.initial;
  }

  Future<void> _pickCity() async {
    final result = await CityPickerSheet.show(context, initial: _filters.city);
    if (result != null) {
      setState(() => _filters = _filters.copyWith(city: () => result));
    }
  }

  Future<void> _pickActivity() async {
    final result = await ActivityTypeScreen.push(
      context,
      initial: _filters.activityType,
    );
    if (result != null) {
      setState(() => _filters = _filters.copyWith(activityType: () => result));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
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
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Filtr',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: kText,
                    ),
                  ),
                  Visibility(
                    visible: !_filters.isEmpty,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: TextButton(
                      onPressed: () => setState(() {
                        widget.nameController.clear();
                        _filters = const SearchFilters();
                      }),
                      child: const Text(
                        'Təmizlə',
                        style: TextStyle(color: kGold, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionLabel('Ad'),
                    TextField(
                      controller: widget.nameController,
                      style: const TextStyle(color: kText),
                      decoration: InputDecoration(
                        hintText: 'İstifadəçi adı',
                        hintStyle: const TextStyle(color: kMuted),
                        prefixIcon: const Icon(Icons.search, color: kMuted),
                        filled: true,
                        fillColor: kCard,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: kBorder),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: kBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: kGold, width: 1.5),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 18),
                    _sectionLabel('Şəhər'),
                    _pickerRow(
                      label: _filters.city ?? 'Hamısı',
                      selected: _filters.city != null,
                      onTap: _pickCity,
                      onClear: _filters.city != null
                          ? () => setState(() => _filters = _filters.copyWith(city: () => null))
                          : null,
                    ),
                    const SizedBox(height: 18),
                    _sectionLabel('Fəaliyyət növü'),
                    _pickerRow(
                      label: _filters.activityType?.cardLabel() ?? 'Hamısı',
                      selected: _filters.activityType != null,
                      onTap: _pickActivity,
                      onClear: _filters.activityType != null
                          ? () => setState(
                              () => _filters = _filters.copyWith(activityType: () => null),
                            )
                          : null,
                    ),
                    const SizedBox(height: 18),
                    _sectionLabel('Reyting'),
                    Wrap(
                      spacing: 8,
                      children: _ratingSteps.map((r) {
                        final selected = _filters.minRating == r;
                        return ChoiceChip(
                          label: Text(r == 0 ? 'Hamısı' : '$r+'),
                          selected: selected,
                          onSelected: (_) =>
                              setState(() => _filters = _filters.copyWith(minRating: r)),
                          selectedColor: kGold,
                          backgroundColor: kCard,
                          labelStyle: TextStyle(
                            color: selected ? kOnGold : kText,
                            fontWeight: FontWeight.w600,
                          ),
                          side: BorderSide(color: selected ? kGold : kBorder),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('İşə hazıram', style: TextStyle(color: kText)),
                      value: _filters.onlyAvailable,
                      activeThumbColor: kGold,
                      onChanged: (v) =>
                          setState(() => _filters = _filters.copyWith(onlyAvailable: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Onlayn indi', style: TextStyle(color: kText)),
                      value: _filters.onlyOnline,
                      activeThumbColor: kGold,
                      onChanged: (v) =>
                          setState(() => _filters = _filters.copyWith(onlyOnline: v)),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(_filters),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kGold,
                    foregroundColor: kOnGold,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Tətbiq et',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: kMuted,
        letterSpacing: 0.4,
      ),
    ),
  );

  Widget _pickerRow({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? kGold : kBorder),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? kGold : kMuted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (onClear != null)
              GestureDetector(
                onTap: onClear,
                child: const Icon(Icons.close_rounded, color: kMuted, size: 18),
              )
            else
              const Icon(Icons.chevron_right_rounded, color: kMuted),
          ],
        ),
      ),
    );
  }
}
