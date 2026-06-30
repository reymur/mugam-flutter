import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';
import '../../../shared/widgets/topbar.dart';
import '../../../firebase/models.dart';
import '../../../firebase/firestore_service.dart';

// ── Fallback mock data ────────────────────────────────────────────────────────

const List<Musician> _fallbackMusicians = [
  Musician(
    id: '',
    name: 'Anar Musayev',
    instrument: 'Kaman',
    city: 'Bakı',
    emoji: '🎻',
    available: true,
    online: true,
    goldRing: true,
    rating: 4.9,
    reviews: 31,
    bio: '',
  ),
  Musician(
    id: '',
    name: 'Leyla Həsənova',
    instrument: 'Tar',
    city: 'Gəncə',
    emoji: '🎵',
    available: false,
    online: false,
    goldRing: false,
    rating: 4.7,
    reviews: 18,
    bio: '',
  ),
  Musician(
    id: '',
    name: 'Rəşad Əliyev',
    instrument: 'Nağara',
    city: 'Bakı',
    emoji: '🥁',
    available: true,
    online: true,
    goldRing: false,
    rating: 4.8,
    reviews: 25,
    bio: '',
  ),
  Musician(
    id: '',
    name: 'Günel Vəliyeva',
    instrument: 'Vokal',
    city: 'Sumqayıt',
    emoji: '🎤',
    available: true,
    online: false,
    goldRing: false,
    rating: 5.0,
    reviews: 12,
    bio: '',
  ),
  Musician(
    id: '',
    name: 'Tural Quliyev',
    instrument: 'Qarmon',
    city: 'Bakı',
    emoji: '🪗',
    available: false,
    online: true,
    goldRing: false,
    rating: 4.6,
    reviews: 23,
    bio: '',
  ),
];

const List<Event> _fallbackEvents = [
  Event(
    id: '',
    day: '18',
    month: 'May',
    title: 'Muğam Gecəsi - Bakıda canlı ifa',
    location: 'Hüseynov Sarayı, Bakı',
    tags: ['Muğam', 'VIP'],
    tagColors: ['gold', 'green'],
    spots: '12 yer qalıb',
  ),
  Event(
    id: '',
    day: '25',
    month: 'May',
    title: 'Tar Festivalı - Açıq hava konserti',
    location: 'Gənclik Parkı, Bakı',
    tags: ['Festival'],
    tagColors: ['gold'],
  ),
  Event(
    id: '',
    day: '2',
    month: 'İyun',
    title: 'Vokal Yarışması Final mərhələsi',
    location: 'Heydər Əliyev Mərkəzi',
    tags: ['Yarış', 'Pulsuz'],
    tagColors: ['gold', 'green'],
    spots: '5 yer qalıb',
  ),
];

const List<Room> _fallbackRooms = [
  Room(
    id: '',
    emoji: '🎻',
    name: 'Klassik Muğam Həvəskarları',
    members: '234 üzv',
    preview: 'Bu axşam Bakıda canlı konsert olacaq, kim gəlir?',
    live: true,
    avatarCount: 7,
  ),
  Room(
    id: '',
    emoji: '🎤',
    name: 'Gənc Müğənnilər Klubu',
    members: '156 üzv',
    preview: 'Yeni mahnı yazıram, fikir bildirə bilərsiniz',
    live: false,
    avatarCount: 4,
  ),
  Room(
    id: '',
    emoji: '🥁',
    name: 'Ritm və Performans',
    members: '89 üzv',
    preview: 'Nağara dərsləri üçün kim maraqlanır?',
    live: true,
    avatarCount: 12,
  ),
];

// ── Screen ────────────────────────────────────────────────────────────────────

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            Topbar(
              notificationCount: 3,
              onNotificationTap: () {},
              onLanguageTap: () {},
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: const [
                    _HeroBanner(),
                    _MusiciansSection(),
                    _EventsSection(),
                    _RoomsSection(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroBanner extends StatelessWidget {
  const _HeroBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF1C1408),
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -40,
            right: -60,
            child: Container(
              width: 200,
              height: 200,
              decoration: const BoxDecoration(
                color: Color(0x1FD4A03C),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'MUĞAM GECƏSİ',
                  style: TextStyle(
                    fontSize: 11,
                    color: kGold,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Muğam Gecəsi - Bakıda',
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: kText,
                    height: 30 / 22,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '18 May, Hüseynov Sarayı - Azərbaycan musiqisinin ən gözəl gecəsi',
                  style: TextStyle(
                    fontSize: 13,
                    color: kMuted,
                    height: 20 / 13,
                  ),
                ),
                const SizedBox(height: 8),
                const Opacity(
                  opacity: 0.4,
                  child: Text(
                    '♦ ◆ ♦ ◆ ♦',
                    style: TextStyle(
                      color: kGold,
                      letterSpacing: 4,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () {},
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kGold,
                        foregroundColor: const Color(0xFF1A0E00),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        elevation: 0,
                      ),
                      child: const Text(
                        'Bilet al',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: () {},
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: kBorder),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: kText,
                      ),
                      child: const Text(
                        'Ətraflı',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: kText,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Musicians section ─────────────────────────────────────────────────────────

class _MusiciansSection extends ConsumerWidget {
  const _MusiciansSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncMusicians = ref.watch(musiciansProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 18, bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Musiqiçilər',
                style: GoogleFonts.playfairDisplay(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: kText,
                ),
              ),
              const Text(
                'Hamısı →',
                style: TextStyle(
                  fontSize: 12,
                  color: kGold,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 220,
          child: asyncMusicians.when(
            data: (list) {
              final musicians = list.isEmpty ? _fallbackMusicians : list;
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: musicians.length,
                itemBuilder: (context, index) => Padding(
                  padding: EdgeInsets.only(
                    right: index == musicians.length - 1 ? 0 : 12,
                  ),
                  child: _MusicianCard(musician: musicians[index]),
                ),
              );
            },
            loading: () => const Center(
              child: CircularProgressIndicator(color: kGold),
            ),
            error: (_, _) => ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _fallbackMusicians.length,
              itemBuilder: (context, index) => Padding(
                padding: EdgeInsets.only(
                  right: index == _fallbackMusicians.length - 1 ? 0 : 12,
                ),
                child: _MusicianCard(musician: _fallbackMusicians[index]),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MusicianCard extends StatelessWidget {
  final Musician musician;

  const _MusicianCard({required this.musician});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(
          color: musician.goldRing ? kGold : kBorder,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: SizedBox(
                    width: 58,
                    height: 58,
                    child: Stack(
                      children: [
                        Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            color: kBg3,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: musician.goldRing ? kGold : kBorder,
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              musician.emoji,
                              style: const TextStyle(fontSize: 24),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: musician.online ? kGreen : kMuted,
                              shape: BoxShape.circle,
                              border: Border.all(color: kCard, width: 2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  musician.name,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: kText,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  musician.instrument,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: kGold,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  musician.city,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: kMuted,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '⭐ ${musician.rating} (${musician.reviews})',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 10,
                    color: kMuted,
                  ),
                ),
                const Spacer(),
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  child: OutlinedButton(
                    onPressed: () {},
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: kGold),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Dəvət et',
                      style: TextStyle(
                        fontSize: 11,
                        color: kGold,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (musician.available)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: kGreen,
                  shape: BoxShape.circle,
                  border: Border.all(color: kCard, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Events section ────────────────────────────────────────────────────────────

class _EventsSection extends ConsumerWidget {
  const _EventsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncEvents = ref.watch(eventsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 18, bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Tədbirlər',
                style: GoogleFonts.playfairDisplay(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: kText,
                ),
              ),
              const Text(
                'Hamısı →',
                style: TextStyle(
                  fontSize: 12,
                  color: kGold,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        asyncEvents.when(
          data: (list) {
            final events = list.isEmpty ? _fallbackEvents : list;
            return Column(
              children: [for (final event in events) _EventCard(event: event)],
            );
          },
          loading: () => const Center(
            child: CircularProgressIndicator(color: kGold),
          ),
          error: (_, _) => Column(
            children: [
              for (final event in _fallbackEvents) _EventCard(event: event),
            ],
          ),
        ),
      ],
    );
  }
}

class _EventCard extends StatelessWidget {
  final Event event;

  const _EventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 50,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: kGold,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  event.day,
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF1A0E00),
                  ),
                ),
                Text(
                  event.month.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A0E00),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: kText,
                    height: 20 / 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  event.location,
                  style: const TextStyle(
                    fontSize: 12,
                    color: kMuted,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (int i = 0; i < event.tags.length; i++)
                      _EventTag(
                        label: event.tags[i],
                        colorType: event.tagColors[i],
                      ),
                  ],
                ),
                if (event.spots != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    event.spots!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: kRed,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EventTag extends StatelessWidget {
  final String label;
  final String colorType;

  const _EventTag({required this.label, required this.colorType});

  @override
  Widget build(BuildContext context) {
    final isGold = colorType == 'gold';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isGold ? kGoldDim : const Color(0x1427AE60),
        border: Border.all(color: isGold ? kGold : kGreen),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: isGold ? kGold : kGreen,
        ),
      ),
    );
  }
}

// ── Rooms section ─────────────────────────────────────────────────────────────

class _RoomsSection extends ConsumerWidget {
  const _RoomsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncRooms = ref.watch(roomsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 18, bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Otaqlar',
                style: GoogleFonts.playfairDisplay(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: kText,
                ),
              ),
              const Text(
                'Hamısı →',
                style: TextStyle(
                  fontSize: 12,
                  color: kGold,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        asyncRooms.when(
          data: (list) {
            final rooms = list.isEmpty ? _fallbackRooms : list;
            return Column(
              children: [for (final room in rooms) _RoomCard(room: room)],
            );
          },
          loading: () => const Center(
            child: CircularProgressIndicator(color: kGold),
          ),
          error: (_, _) => Column(
            children: [
              for (final room in _fallbackRooms) _RoomCard(room: room),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoomCard extends StatelessWidget {
  final Room room;

  const _RoomCard({required this.room});

  @override
  Widget build(BuildContext context) {
    final visibleAvatars = room.avatarCount > 4 ? 4 : room.avatarCount;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: kBg3,
                    border: Border.all(color: kBorder),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(
                      room.emoji,
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.name,
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: kText,
                        ),
                      ),
                      Text(
                        room.members,
                        style: const TextStyle(
                          fontSize: 12,
                          color: kMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (room.live)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: kGreen,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'Canlı',
                        style: TextStyle(
                          fontSize: 11,
                          color: kGreen,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          // Preview with left border
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.only(left: 10),
            decoration: const BoxDecoration(
              border: Border(
                left: BorderSide(color: kBorder, width: 2),
              ),
            ),
            child: Text(
              room.preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                color: kMuted,
                height: 20 / 13,
              ),
            ),
          ),
          // Avatars row
          Row(
            children: [
              SizedBox(
                height: 26,
                width: 26 + (visibleAvatars - 1) * 18.0,
                child: Stack(
                  children: [
                    for (int i = 0; i < visibleAvatars; i++)
                      Positioned(
                        left: i * 18.0,
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: kBg3,
                            shape: BoxShape.circle,
                            border: Border.all(color: kCard, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (room.avatarCount > 4) ...[
                const SizedBox(width: 8),
                Text(
                  '+${room.avatarCount - 4} daha',
                  style: const TextStyle(fontSize: 11, color: kMuted),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
