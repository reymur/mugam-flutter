import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';

const Color _kHeroBg = Color(0xFF15100A);

class UserProfileScreen extends ConsumerWidget {
  final User user;

  const UserProfileScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isOwnProfile = user.id.isNotEmpty && user.id == currentUid;
    final liveUser = ref.watch(currentUserProvider(user.id)).value ?? user;

    final eventsAsync = ref.watch(personalEventsProvider(currentUid));
    final agreementCount = eventsAsync.asData?.value
            .where((e) =>
                e.isAgree &&
                ((e.ownerUid == currentUid && e.partnerUid == user.id) ||
                    (e.ownerUid == user.id && e.partnerUid == currentUid)))
            .length ??
        0;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Profil',
          style: GoogleFonts.playfairDisplay(fontSize: 18, color: kText),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHero(context, isOwnProfile, agreementCount, liveUser),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('Haqqında'),
                  const SizedBox(height: 10),
                  _buildAbout(),
                  const SizedBox(height: 24),
                  _sectionTitle('Xidmətlər və Qiymətlər'),
                  const SizedBox(height: 10),
                  _buildServices(),
                  const SizedBox(height: 24),
                  _sectionTitle('Rəylər (${user.reviews})'),
                  const SizedBox(height: 10),
                  _buildReviews(),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Hero section
  // ---------------------------------------------------------------------------
  Widget _buildHero(
    BuildContext context,
    bool isOwnProfile,
    int agreementCount,
    User liveUser,
  ) {
    final starCount = user.rating.round().clamp(0, 5);
    final starsStr =
        List.filled(starCount, '★').join() + List.filled(5 - starCount, '☆').join();

    return Container(
      color: _kHeroBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Avatar with online dot
          SizedBox(
            width: 96,
            height: 96,
            child: Stack(
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: kBg3,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: user.goldRing ? kGold : kBorder,
                      width: 3,
                    ),
                  ),
                  child: Center(
                    child: Text(user.emoji, style: const TextStyle(fontSize: 48)),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: liveUser.isActuallyOnline ? kGreen : kMuted,
                      shape: BoxShape.circle,
                      border: Border.all(color: _kHeroBg, width: 3),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Name
          Text(
            user.name,
            textAlign: TextAlign.center,
            style: GoogleFonts.playfairDisplay(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: kText,
            ),
          ),
          const SizedBox(height: 4),
          // Instrument
          Text(
            user.instrument,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: kGold, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          // Meta row: city + available badge
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 6,
            children: [
              Text(
                '📍 ${user.city}',
                style: const TextStyle(fontSize: 13, color: kMuted),
              ),
              if (user.available) _availableBadge(),
            ],
          ),
          const SizedBox(height: 10),
          // Rating row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(starsStr, style: const TextStyle(fontSize: 16, color: kGold)),
              const SizedBox(width: 6),
              Text(
                '${user.reviews} rəy',
                style: const TextStyle(fontSize: 12, color: kMuted),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Stats box
          Container(
            decoration: BoxDecoration(
              color: kCard,
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(14),
            ),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    child: _StatColumn(label: 'Tədbirlər', value: '${user.reviews}'),
                  ),
                  Container(width: 1, color: kBorder),
                  Expanded(
                    child: _StatColumn(
                      label: 'Reytinq',
                      value: user.rating.toStringAsFixed(1),
                    ),
                  ),
                  Container(width: 1, color: kBorder),
                  const Expanded(
                    child: _StatColumn(label: 'İl', value: '10+'),
                  ),
                ],
              ),
            ),
          ),
          // Action buttons (hidden when viewing own profile)
          if (!isOwnProfile) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: agreementCount > 0
                      ? ElevatedButton(
                          onPressed: () => context.go('/agreements'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kGold,
                            foregroundColor: const Color(0xFF1A0E00),
                            elevation: 0,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: Text(
                            '🤝 Razılaşma ($agreementCount)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        )
                      : Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color: kBg3,
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(color: kBorder),
                          ),
                          child: const Text(
                            '🤝 Razılaşma',
                            style: TextStyle(
                              color: kMuted,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content:
                              Text('Söhbət funksiyası tezliklə əlavə olunacaq'),
                          backgroundColor: kBg3,
                        ),
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: kBorder),
                      foregroundColor: kText,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text(
                      '✉️ Mesaj',
                      style: TextStyle(color: kText, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _availableBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: kGreen.withAlpha(30),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kGreen),
      ),
      child: const Text(
        '✅ Hazırdır',
        style: TextStyle(fontSize: 12, color: kGreen, fontWeight: FontWeight.bold),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section title
  // ---------------------------------------------------------------------------
  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: GoogleFonts.playfairDisplay(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: kText,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // About section
  // ---------------------------------------------------------------------------
  Widget _buildAbout() {
    final bio = user.bio.isNotEmpty
        ? user.bio
        : '${user.city} şəhərindən professional '
            '${user.instrument.toLowerCase()} musiqiçi. '
            '10+ il səhnə təcrübəsi.';
    return Text(
      bio,
      style: const TextStyle(fontSize: 14, color: kMuted, height: 1.5),
    );
  }

  // ---------------------------------------------------------------------------
  // Services section
  // ---------------------------------------------------------------------------
  Widget _buildServices() {
    const services = [
      ('💍 Toy', '200–400 AZN'),
      ('🎭 Konsert', '150–300 AZN'),
      ('🍽 Restoran', '100–200 AZN / gecə'),
      ('📸 Çəkiliş', '150–250 AZN'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (int i = 0; i < services.length; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Text(
                    services[i].$1,
                    style: const TextStyle(fontSize: 14, color: kText),
                  ),
                  const Spacer(),
                  Text(
                    services[i].$2,
                    style: const TextStyle(
                      fontSize: 14,
                      color: kGold,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            if (i < services.length - 1)
              const Divider(color: kBorder, height: 1, thickness: 1),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Reviews section
  // ---------------------------------------------------------------------------
  Widget _buildReviews() {
    const reviewData = [
      (
        author: 'Əli Hüseynov',
        text: 'Çox peşəkar ifa, toyumuz əfsanəvi oldu!',
        rating: 5,
        date: '12 May 2026',
      ),
      (
        author: 'Nigar Quliyeva',
        text: 'Vaxtında gəldi, hamı məmnun qaldı.',
        rating: 5,
        date: '3 May 2026',
      ),
      (
        author: 'Tural Babayev',
        text: 'Gözəl səs, professional davranış.',
        rating: 4,
        date: '28 Apr 2026',
      ),
    ];

    return Column(
      children: [
        for (int i = 0; i < reviewData.length; i++) ...[
          _reviewCard(
            author: reviewData[i].author,
            text: reviewData[i].text,
            rating: reviewData[i].rating,
            date: reviewData[i].date,
          ),
          if (i < reviewData.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _reviewCard({
    required String author,
    required String text,
    required int rating,
    required String date,
  }) {
    final stars = List.filled(rating, '★').join() + List.filled(5 - rating, '☆').join();
    return Container(
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: kBg3,
                  shape: BoxShape.circle,
                  border: Border.all(color: kBorder),
                ),
                child: const Center(
                  child: Text('👤', style: TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      author,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: kText,
                      ),
                    ),
                    Text(
                      date,
                      style: const TextStyle(fontSize: 11, color: kMuted),
                    ),
                  ],
                ),
              ),
              Text(stars, style: const TextStyle(fontSize: 13, color: kGold)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: const TextStyle(fontSize: 13, color: kMuted, height: 1.5),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stat column for the stats box
// ---------------------------------------------------------------------------
class _StatColumn extends StatelessWidget {
  final String label;
  final String value;

  const _StatColumn({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: GoogleFonts.playfairDisplay(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: kGold2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              color: kMuted,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
