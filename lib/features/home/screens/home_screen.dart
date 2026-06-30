import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              _HeroBanner(),
              _MusiciansSection(),
            ],
          ),
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

// ── Musicians section ────────────────────────────────────────────────────────

class _Musician {
  final String name;
  final String instrument;
  final String city;
  final String emoji;
  final bool available;
  final bool online;
  final bool goldRing;
  final double rating;
  final int ratingCount;

  const _Musician({
    required this.name,
    required this.instrument,
    required this.city,
    required this.emoji,
    required this.available,
    required this.online,
    required this.goldRing,
    required this.rating,
    required this.ratingCount,
  });
}

const _kMusicians = [
  _Musician(
    name: 'Anar Musayev',
    instrument: 'Kaman',
    city: 'Bakı',
    emoji: '🎻',
    available: true,
    online: true,
    goldRing: true,
    rating: 4.9,
    ratingCount: 31,
  ),
  _Musician(
    name: 'Leyla Həsənova',
    instrument: 'Tar',
    city: 'Gəncə',
    emoji: '🎵',
    available: false,
    online: false,
    goldRing: false,
    rating: 4.7,
    ratingCount: 18,
  ),
  _Musician(
    name: 'Rəşad Əliyev',
    instrument: 'Nağara',
    city: 'Bakı',
    emoji: '🥁',
    available: true,
    online: true,
    goldRing: false,
    rating: 4.8,
    ratingCount: 25,
  ),
  _Musician(
    name: 'Günel Vəliyeva',
    instrument: 'Vokal',
    city: 'Sumqayıt',
    emoji: '🎤',
    available: true,
    online: false,
    goldRing: false,
    rating: 5.0,
    ratingCount: 12,
  ),
  _Musician(
    name: 'Tural Quliyev',
    instrument: 'Qarmon',
    city: 'Bakı',
    emoji: '🪗',
    available: false,
    online: true,
    goldRing: false,
    rating: 4.6,
    ratingCount: 23,
  ),
];

class _MusiciansSection extends StatelessWidget {
  const _MusiciansSection();

  @override
  Widget build(BuildContext context) {
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
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _kMusicians.length,
            itemBuilder: (context, index) => Padding(
              padding: EdgeInsets.only(
                right: index == _kMusicians.length - 1 ? 0 : 12,
              ),
              child: _MusicianCard(musician: _kMusicians[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _MusicianCard extends StatelessWidget {
  final _Musician musician;

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
                  '⭐ ${musician.rating} (${musician.ratingCount})',
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
