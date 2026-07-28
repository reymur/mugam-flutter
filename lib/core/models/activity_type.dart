// Structured "Fəaliyyət növü" (activity type) selection — replaces the old
// single-string `instrument` picker on EditProfileScreen. Top level is a
// single-select category (radio); each category has its own checkbox-level
// sub-structure, some with a further nested level (Şanson, Sintezator).
//
// Only the field matching `category` is ever populated on an ActivityType —
// separate nullable fields rather than a sealed-class hierarchy so
// fromMap/toMap stay flat switch statements with no runtime casts.
library;

enum ActivityCategory {
  simli,
  nefes,
  klavish,
  muganni,
  zerb,
  sesSistemleri,
  videoCekilis,
  sekil,
  isiqSistemleri,
}

// The recurring "Digər" pattern: a checkbox that, once selected, may carry
// an optional free-text clarification. `note` is '' (never null) so callers
// don't need a second null-check on top of `selected`.
class DigerNote {
  final bool selected;
  final String note;

  const DigerNote({this.selected = false, this.note = ''});

  DigerNote copyWith({bool? selected, String? note}) => DigerNote(
    selected: selected ?? this.selected,
    note: note ?? this.note,
  );

  String label(String fallback) =>
      note.trim().isNotEmpty ? note.trim() : fallback;

  Map<String, dynamic> toMap() => {'selected': selected, 'note': note};

  static DigerNote fromMap(Map<String, dynamic>? map) => DigerNote(
    selected: (map?['selected'] as bool?) ?? false,
    note: (map?['note'] as String?) ?? '',
  );
}

// Renders a set of leaf option strings to display/search labels, swapping
// any literal 'Digər' entry for its clarifying note (falling back to
// 'Digər' itself when no note was given).
List<String> _renderOptions(Set<String> options, DigerNote diger) {
  return options.map((o) => o == 'Digər' ? diger.label('Digər') : o).toList();
}

class SimliDetails {
  final Set<String> instruments;
  final Set<String> gitaraSub; // {'Milli','Akustik'} — only if instruments has 'Gitara'
  final Set<String> sazSub; // {'Milli','Türk'} — only if instruments has 'Saz'

  const SimliDetails({
    this.instruments = const {},
    this.gitaraSub = const {},
    this.sazSub = const {},
  });

  SimliDetails copyWith({
    Set<String>? instruments,
    Set<String>? gitaraSub,
    Set<String>? sazSub,
  }) => SimliDetails(
    instruments: instruments ?? this.instruments,
    gitaraSub: gitaraSub ?? this.gitaraSub,
    sazSub: sazSub ?? this.sazSub,
  );

  Map<String, dynamic> toMap() => {
    'instruments': instruments.toList(),
    'gitaraSub': gitaraSub.toList(),
    'sazSub': sazSub.toList(),
  };

  static SimliDetails fromMap(Map<String, dynamic> map) => SimliDetails(
    instruments: Set<String>.from(map['instruments'] as List? ?? const []),
    gitaraSub: Set<String>.from(map['gitaraSub'] as List? ?? const []),
    sazSub: Set<String>.from(map['sazSub'] as List? ?? const []),
  );
}

class NefesDetails {
  final Set<String> instruments;

  const NefesDetails({this.instruments = const {}});

  NefesDetails copyWith({Set<String>? instruments}) =>
      NefesDetails(instruments: instruments ?? this.instruments);

  Map<String, dynamic> toMap() => {'instruments': instruments.toList()};

  static NefesDetails fromMap(Map<String, dynamic> map) => NefesDetails(
    instruments: Set<String>.from(map['instruments'] as List? ?? const []),
  );
}

class KlavishDetails {
  final bool sintezator;
  final Set<String> sintezatorRoles; // {'Müşayətçi', 'Solo'}
  final bool qarmon;
  final bool qarmonSoloSintez;

  const KlavishDetails({
    this.sintezator = false,
    this.sintezatorRoles = const {},
    this.qarmon = false,
    this.qarmonSoloSintez = false,
  });

  KlavishDetails copyWith({
    bool? sintezator,
    Set<String>? sintezatorRoles,
    bool? qarmon,
    bool? qarmonSoloSintez,
  }) => KlavishDetails(
    sintezator: sintezator ?? this.sintezator,
    sintezatorRoles: sintezatorRoles ?? this.sintezatorRoles,
    qarmon: qarmon ?? this.qarmon,
    qarmonSoloSintez: qarmonSoloSintez ?? this.qarmonSoloSintez,
  );

  Map<String, dynamic> toMap() => {
    'sintezator': sintezator,
    'sintezatorRoles': sintezatorRoles.toList(),
    'qarmon': qarmon,
    'qarmonSoloSintez': qarmonSoloSintez,
  };

  static KlavishDetails fromMap(Map<String, dynamic> map) => KlavishDetails(
    sintezator: (map['sintezator'] as bool?) ?? false,
    sintezatorRoles: Set<String>.from(
      map['sintezatorRoles'] as List? ?? const [],
    ),
    qarmon: (map['qarmon'] as bool?) ?? false,
    qarmonSoloSintez: (map['qarmonSoloSintez'] as bool?) ?? false,
  );
}

class MuganniDetails {
  final Set<String> roles; // {'Muğam ifaçısı','Xanəndə','Şanson','Aparıcı','Digər'}
  final DigerNote digerNote; // clarification for the top-level 'Digər'
  final Set<String> sansonSub; // {'Rus dilində','Digər'} — only if roles has 'Şanson'
  final DigerNote sansonDigerNote; // clarification for the nested 'Digər'

  const MuganniDetails({
    this.roles = const {},
    this.digerNote = const DigerNote(),
    this.sansonSub = const {},
    this.sansonDigerNote = const DigerNote(),
  });

  MuganniDetails copyWith({
    Set<String>? roles,
    DigerNote? digerNote,
    Set<String>? sansonSub,
    DigerNote? sansonDigerNote,
  }) => MuganniDetails(
    roles: roles ?? this.roles,
    digerNote: digerNote ?? this.digerNote,
    sansonSub: sansonSub ?? this.sansonSub,
    sansonDigerNote: sansonDigerNote ?? this.sansonDigerNote,
  );

  Map<String, dynamic> toMap() => {
    'roles': roles.toList(),
    'digerNote': digerNote.toMap(),
    'sansonSub': sansonSub.toList(),
    'sansonDigerNote': sansonDigerNote.toMap(),
  };

  static MuganniDetails fromMap(Map<String, dynamic> map) => MuganniDetails(
    roles: Set<String>.from(map['roles'] as List? ?? const []),
    digerNote: DigerNote.fromMap(map['digerNote'] as Map<String, dynamic>?),
    sansonSub: Set<String>.from(map['sansonSub'] as List? ?? const []),
    sansonDigerNote: DigerNote.fromMap(
      map['sansonDigerNote'] as Map<String, dynamic>?,
    ),
  );
}

class ZerbDetails {
  final Set<String> instruments; // includes 'Digər'
  final DigerNote digerNote;

  const ZerbDetails({
    this.instruments = const {},
    this.digerNote = const DigerNote(),
  });

  ZerbDetails copyWith({Set<String>? instruments, DigerNote? digerNote}) =>
      ZerbDetails(
        instruments: instruments ?? this.instruments,
        digerNote: digerNote ?? this.digerNote,
      );

  Map<String, dynamic> toMap() => {
    'instruments': instruments.toList(),
    'digerNote': digerNote.toMap(),
  };

  static ZerbDetails fromMap(Map<String, dynamic> map) => ZerbDetails(
    instruments: Set<String>.from(map['instruments'] as List? ?? const []),
    digerNote: DigerNote.fromMap(map['digerNote'] as Map<String, dynamic>?),
  );
}

// Səs sistemləri / İşıq sistemləri share the exact same shape: an optional
// category whose only sub-option is 'Digər'.
class SingleDigerDetails {
  final DigerNote digerNote;

  const SingleDigerDetails({this.digerNote = const DigerNote()});

  SingleDigerDetails copyWith({DigerNote? digerNote}) =>
      SingleDigerDetails(digerNote: digerNote ?? this.digerNote);

  Map<String, dynamic> toMap() => {'digerNote': digerNote.toMap()};

  static SingleDigerDetails fromMap(Map<String, dynamic> map) =>
      SingleDigerDetails(
        digerNote: DigerNote.fromMap(map['digerNote'] as Map<String, dynamic>?),
      );
}

class ActivityType {
  final ActivityCategory category;
  final SimliDetails? simli;
  final NefesDetails? nefes;
  final KlavishDetails? klavish;
  final MuganniDetails? muganni;
  final ZerbDetails? zerb;
  final SingleDigerDetails? sesSistemleri;
  final SingleDigerDetails? videoCekilis;
  final SingleDigerDetails? sekil;
  final SingleDigerDetails? isiqSistemleri;

  const ActivityType._({
    required this.category,
    this.simli,
    this.nefes,
    this.klavish,
    this.muganni,
    this.zerb,
    this.sesSistemleri,
    this.videoCekilis,
    this.sekil,
    this.isiqSistemleri,
  });

  const ActivityType.simliOf(SimliDetails details)
    : this._(category: ActivityCategory.simli, simli: details);

  const ActivityType.nefesOf(NefesDetails details)
    : this._(category: ActivityCategory.nefes, nefes: details);

  const ActivityType.klavishOf(KlavishDetails details)
    : this._(category: ActivityCategory.klavish, klavish: details);

  const ActivityType.muganniOf(MuganniDetails details)
    : this._(category: ActivityCategory.muganni, muganni: details);

  const ActivityType.zerbOf(ZerbDetails details)
    : this._(category: ActivityCategory.zerb, zerb: details);

  const ActivityType.sesSistemleriOf(SingleDigerDetails details)
    : this._(category: ActivityCategory.sesSistemleri, sesSistemleri: details);

  const ActivityType.videoCekilisOf(SingleDigerDetails details)
    : this._(category: ActivityCategory.videoCekilis, videoCekilis: details);

  const ActivityType.sekilOf(SingleDigerDetails details)
    : this._(category: ActivityCategory.sekil, sekil: details);

  const ActivityType.isiqSistemleriOf(SingleDigerDetails details)
    : this._(
        category: ActivityCategory.isiqSistemleri,
        isiqSistemleri: details,
      );

  static const Map<ActivityCategory, String> categoryLabels = {
    ActivityCategory.simli: 'Simli alətlər',
    ActivityCategory.nefes: 'Nəfəs alətləri',
    ActivityCategory.klavish: 'Klaviş',
    ActivityCategory.muganni: 'Müğənni',
    ActivityCategory.zerb: 'Zərb alətləri',
    ActivityCategory.sesSistemleri: 'Səs sistemləri',
    ActivityCategory.videoCekilis: 'Video Çəkiliş',
    ActivityCategory.sekil: 'Şəkil',
    ActivityCategory.isiqSistemleri: 'İşıq sistemləri',
  };

  // Fully-qualified choice list for simli/nefes/klavish/muganni/zerb — one
  // entry per selected leaf, subs folded in (e.g. 'Gitara (Milli, Akustik)',
  // 'Şanson (Rus dilində)'). Shared by toDisplayLabel() and
  // profileDetailLines() so the two don't drift as category structure
  // changes. The four "single Digər" categories don't go through here —
  // toDisplayLabel() and profileDetailLines() format their note differently
  // (see each), so there's nothing to share for them.
  List<String> _detailParts() {
    switch (category) {
      case ActivityCategory.simli:
        final s = simli!;
        return s.instruments.map((i) {
          if (i == 'Gitara' && s.gitaraSub.isNotEmpty) {
            return 'Gitara (${s.gitaraSub.join(', ')})';
          }
          if (i == 'Saz' && s.sazSub.isNotEmpty) {
            return 'Saz (${s.sazSub.join(', ')})';
          }
          return i;
        }).toList();
      case ActivityCategory.nefes:
        return nefes!.instruments.toList();
      case ActivityCategory.klavish:
        final k = klavish!;
        final parts = <String>[];
        if (k.sintezator) {
          parts.add(
            k.sintezatorRoles.isEmpty
                ? 'Sintezator'
                : 'Sintezator (${k.sintezatorRoles.join(', ')})',
          );
        }
        if (k.qarmon) {
          parts.add(k.qarmonSoloSintez ? 'Qarmon (Solo sintez)' : 'Qarmon');
        }
        return parts;
      case ActivityCategory.muganni:
        final m = muganni!;
        final parts = <String>[];
        for (final role in m.roles) {
          if (role == 'Şanson') {
            final subs = _renderOptions(m.sansonSub, m.sansonDigerNote);
            parts.add(subs.isEmpty ? 'Şanson' : 'Şanson (${subs.join(', ')})');
          } else if (role == 'Digər') {
            parts.add(m.digerNote.label('Digər'));
          } else {
            parts.add(role);
          }
        }
        return parts;
      case ActivityCategory.zerb:
        return _renderOptions(zerb!.instruments, zerb!.digerNote);
      case ActivityCategory.sesSistemleri:
      case ActivityCategory.videoCekilis:
      case ActivityCategory.sekil:
      case ActivityCategory.isiqSistemleri:
        return const [];
    }
  }

  // Human-readable summary, written into the legacy `instrument`/`specialty`
  // string fields so every other screen that just prints/searches that
  // string keeps working unchanged.
  String toDisplayLabel() {
    switch (category) {
      case ActivityCategory.simli:
      case ActivityCategory.nefes:
      case ActivityCategory.klavish:
      case ActivityCategory.muganni:
      case ActivityCategory.zerb:
        final parts = _detailParts();
        return parts.isEmpty ? categoryLabels[category]! : parts.join(', ');
      case ActivityCategory.sesSistemleri:
        final d = sesSistemleri!.digerNote;
        return d.selected
            ? '${categoryLabels[category]} (${d.label('Digər')})'
            : categoryLabels[category]!;
      case ActivityCategory.videoCekilis:
        final d = videoCekilis!.digerNote;
        return d.selected
            ? '${categoryLabels[category]} (${d.label('Digər')})'
            : categoryLabels[category]!;
      case ActivityCategory.sekil:
        final d = sekil!.digerNote;
        return d.selected
            ? '${categoryLabels[category]} (${d.label('Digər')})'
            : categoryLabels[category]!;
      case ActivityCategory.isiqSistemleri:
        final d = isiqSistemleri!.digerNote;
        return d.selected
            ? '${categoryLabels[category]} (${d.label('Digər')})'
            : categoryLabels[category]!;
    }
  }

  // Single-line label for the fixed-height musician card (home screen).
  // Deliberately terser than toDisplayLabel()/profileDetailLines(): drops
  // sub-qualifiers (Milli/Akustik, Sintezator/Qarmon roles, Şanson subs) for
  // simli/nefes/klavish/zerb, and always shows just the category name for
  // Müğənni and the four "single Digər" categories — the card has no room
  // for the full breakdown, which is what the profile screen is for.
  String cardLabel() {
    switch (category) {
      case ActivityCategory.simli:
        final s = simli!.instruments;
        return s.isEmpty ? categoryLabels[category]! : s.join(', ');
      case ActivityCategory.nefes:
        final n = nefes!.instruments;
        return n.isEmpty ? categoryLabels[category]! : n.join(', ');
      case ActivityCategory.klavish:
        final k = klavish!;
        final parts = [
          if (k.sintezator) 'Sintezator',
          if (k.qarmon) 'Qarmon',
        ];
        return parts.isEmpty ? categoryLabels[category]! : parts.join(', ');
      case ActivityCategory.zerb:
        final parts = _renderOptions(zerb!.instruments, zerb!.digerNote);
        return parts.isEmpty ? categoryLabels[category]! : parts.join(', ');
      case ActivityCategory.muganni:
      case ActivityCategory.sesSistemleri:
      case ActivityCategory.videoCekilis:
      case ActivityCategory.sekil:
      case ActivityCategory.isiqSistemleri:
        return categoryLabels[category]!;
    }
  }

  // Full, untruncated breakdown for the profile screen: one line per
  // selected choice, category name shown separately by the caller (see
  // formatActivityForProfile). For the four "single Digər" categories this
  // surfaces the literal word "Digər" plus the typed clarification — unlike
  // toDisplayLabel(), which folds the note into the category string instead
  // (kept as-is there since that string also feeds the legacy Firestore
  // `instrument`/`specialty` mirror read by other screens).
  List<String> profileDetailLines() {
    switch (category) {
      case ActivityCategory.simli:
      case ActivityCategory.nefes:
      case ActivityCategory.klavish:
      case ActivityCategory.muganni:
      case ActivityCategory.zerb:
        return _detailParts();
      case ActivityCategory.sesSistemleri:
        return _singleDigerDetailLines(sesSistemleri!.digerNote);
      case ActivityCategory.videoCekilis:
        return _singleDigerDetailLines(videoCekilis!.digerNote);
      case ActivityCategory.sekil:
        return _singleDigerDetailLines(sekil!.digerNote);
      case ActivityCategory.isiqSistemleri:
        return _singleDigerDetailLines(isiqSistemleri!.digerNote);
    }
  }

  static List<String> _singleDigerDetailLines(DigerNote d) {
    if (!d.selected) return const [];
    final note = d.note.trim();
    return [note.isEmpty ? 'Digər' : 'Digər: $note'];
  }

  // Flat leaf list — meant for an `activityInstruments` array field so
  // Firestore can `array-contains` filter users by a single instrument,
  // which it can't do against the nested `activityType` map above.
  List<String> toSearchableInstruments() {
    switch (category) {
      case ActivityCategory.simli:
        final s = simli!;
        final out = <String>[];
        for (final i in s.instruments) {
          out.add(i);
          if (i == 'Gitara') out.addAll(s.gitaraSub);
          if (i == 'Saz') out.addAll(s.sazSub);
        }
        return out;
      case ActivityCategory.nefes:
        return nefes!.instruments.toList();
      case ActivityCategory.klavish:
        final k = klavish!;
        final out = <String>[];
        if (k.sintezator) {
          out.add('Sintezator');
          out.addAll(k.sintezatorRoles);
        }
        if (k.qarmon) {
          out.add('Qarmon');
          if (k.qarmonSoloSintez) out.add('Solo sintez');
        }
        return out;
      case ActivityCategory.muganni:
        final m = muganni!;
        final out = <String>[];
        for (final role in m.roles) {
          if (role == 'Şanson') {
            out.add('Şanson');
            out.addAll(_renderOptions(m.sansonSub, m.sansonDigerNote));
          } else if (role == 'Digər') {
            out.add(m.digerNote.label('Digər'));
          } else {
            out.add(role);
          }
        }
        return out;
      case ActivityCategory.zerb:
        return _renderOptions(zerb!.instruments, zerb!.digerNote);
      case ActivityCategory.sesSistemleri:
        final d = sesSistemleri!.digerNote;
        return d.selected ? [d.label('Digər')] : const [];
      case ActivityCategory.videoCekilis:
        final d = videoCekilis!.digerNote;
        return d.selected ? [d.label('Digər')] : const [];
      case ActivityCategory.sekil:
        final d = sekil!.digerNote;
        return d.selected ? [d.label('Digər')] : const [];
      case ActivityCategory.isiqSistemleri:
        final d = isiqSistemleri!.digerNote;
        return d.selected ? [d.label('Digər')] : const [];
    }
  }

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> details;
    switch (category) {
      case ActivityCategory.simli:
        details = simli!.toMap();
      case ActivityCategory.nefes:
        details = nefes!.toMap();
      case ActivityCategory.klavish:
        details = klavish!.toMap();
      case ActivityCategory.muganni:
        details = muganni!.toMap();
      case ActivityCategory.zerb:
        details = zerb!.toMap();
      case ActivityCategory.sesSistemleri:
        details = sesSistemleri!.toMap();
      case ActivityCategory.videoCekilis:
        details = videoCekilis!.toMap();
      case ActivityCategory.sekil:
        details = sekil!.toMap();
      case ActivityCategory.isiqSistemleri:
        details = isiqSistemleri!.toMap();
    }
    return {'category': category.name, 'details': details};
  }

  static ActivityType? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final category = ActivityCategory.values.firstWhere(
      (c) => c.name == map['category'],
      orElse: () => ActivityCategory.simli,
    );
    final details = (map['details'] as Map<String, dynamic>?) ?? const {};
    switch (category) {
      case ActivityCategory.simli:
        return ActivityType.simliOf(SimliDetails.fromMap(details));
      case ActivityCategory.nefes:
        return ActivityType.nefesOf(NefesDetails.fromMap(details));
      case ActivityCategory.klavish:
        return ActivityType.klavishOf(KlavishDetails.fromMap(details));
      case ActivityCategory.muganni:
        return ActivityType.muganniOf(MuganniDetails.fromMap(details));
      case ActivityCategory.zerb:
        return ActivityType.zerbOf(ZerbDetails.fromMap(details));
      case ActivityCategory.sesSistemleri:
        return ActivityType.sesSistemleriOf(
          SingleDigerDetails.fromMap(details),
        );
      case ActivityCategory.videoCekilis:
        return ActivityType.videoCekilisOf(
          SingleDigerDetails.fromMap(details),
        );
      case ActivityCategory.sekil:
        return ActivityType.sekilOf(SingleDigerDetails.fromMap(details));
      case ActivityCategory.isiqSistemleri:
        return ActivityType.isiqSistemleriOf(
          SingleDigerDetails.fromMap(details),
        );
    }
  }
}

/// Card-safe single-line activity label. `legacyInstrument` is the flat
/// string mirror (`User.instrument`) — the fallback for accounts that
/// predate structured activity types (`activityType == null`), where
/// there's nothing else to show.
String formatActivityForCard(ActivityType? activityType, String legacyInstrument) {
  return activityType?.cardLabel() ?? legacyInstrument;
}

/// Full activity breakdown for the profile screen. `heading` is the
/// category name (bold/gold line under the user's name) — or, for legacy
/// accounts with no structured `activityType`, the flat instrument string
/// itself, with `details` empty. `details` is the untruncated per-choice
/// list (see [ActivityType.profileDetailLines]).
({String heading, List<String> details}) formatActivityForProfile(
  ActivityType? activityType,
  String legacyInstrument,
) {
  if (activityType == null) {
    return (heading: legacyInstrument, details: const []);
  }
  return (
    heading: ActivityType.categoryLabels[activityType.category]!,
    details: activityType.profileDetailLines(),
  );
}
