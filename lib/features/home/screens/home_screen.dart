import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/models/activity_type.dart';
import '../../../core/theme/colors.dart';
import '../../../shared/widgets/topbar.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import '../../../firebase/models.dart';
import '../../../firebase/firestore_service.dart';
import '../../status/screens/status_viewer_screen.dart';
import '../../user/screens/user_profile_screen.dart';

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
                    // Секции «Tədbirlər» и «Otaqlar» сняты 07.08 вместе с
                    // вшитыми в код майскими концертами: в проде коллекции
                    // events и rooms ПУСТЫ, значит `list.isEmpty` было
                    // истинно всегда и живым людям показывалась выдумка.
                    // Пустые секции вместо неё не оставлены намеренно —
                    // молчащий заголовок читается как поломка, а главный
                    // экран всё равно переписывается своим шагом плана.
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
          // Large faded instrument silhouette watermark, replacing the
          // small corner-blur circle this card used to have — no bundled
          // image asset exists for a real tar silhouette in this project,
          // so a big low-opacity emoji glyph stands in for one; same
          // visual intent (a decorative shape behind the text, not meant
          // to read as sharp branded artwork) without a new asset.
          Positioned(
            right: 15,
            bottom: 20,
            child: Opacity(
              opacity: 0.12,
              child: Text('🎻', style: TextStyle(fontSize: 180)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: kGold.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('🎼', style: TextStyle(fontSize: 12)),
                      const SizedBox(width: 6),
                      Text(
                        'RƏSMİ KLUB',
                        style: TextStyle(
                          fontSize: 11,
                          color: kGold,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Azərbaycan\nMusiqiçilərinin Evi',
                  style: GoogleFonts.nunito(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: kText,
                    height: 32 / 26,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Müğənni, ifaçı, prodüser — hamı burada. Toy, konsert, '
                  'layihə üçün musiqiçi tap.',
                  style: TextStyle(
                    fontSize: 13,
                    color: kMuted,
                    height: 20 / 13,
                  ),
                ),
                const SizedBox(height: 16),
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
                        'Musiqiçi Tap',
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
                        'Elan Ver',
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
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
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
                style: GoogleFonts.nunito(
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
          height: 240,
          child: asyncMusicians.when(
            data: (list) {
              final musicians = list.excludingUid(currentUid);
              if (musicians.isEmpty) {
                return const _EmptyMusicians(
                  message: 'Musiqiçi tapılmadı',
                );
              }
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
            error: (_, _) => const _EmptyMusicians(
              message: 'Musiqiçilər yüklənmədi',
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyMusicians extends StatelessWidget {
  final String message;

  const _EmptyMusicians({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.people_outline_rounded, color: kMuted, size: 32),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(color: kMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _MusicianCard extends ConsumerWidget {
  final User musician;

  const _MusicianCard({required this.musician});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final hasActiveStatus = musician.hasActiveStatus;
    final viewerUser = hasActiveStatus
        ? ref.watch(currentUserProvider(currentUid)).value
        : null;
    final hasUnviewed =
        hasActiveStatus && (viewerUser?.hasUnviewedStatusFrom(musician) ?? false);
    const avatarBaseSize = 58.0;
    final avatarBoxSize = avatarBaseSize * 1.2;
    void openStatusViewer() => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserStatusViewerScreen(
              ownerUid: musician.id,
              currentUid: currentUid,
              initialUser: musician,
            ),
          ),
        );
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UserProfileScreen(user: musician),
        ),
      ),
      child: Container(
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
                    width: avatarBoxSize,
                    height: avatarBoxSize,
                    child: Stack(
                      children: [
                        if (hasActiveStatus)
                          GestureDetector(
                            onTap: openStatusViewer,
                            onLongPress: () => showAvatarLongPressMenu(
                              context,
                              photoURL: musician.photoURL,
                              onViewStatus: openStatusViewer,
                            ),
                            child: AvatarRing(
                              photoURL: musician.photoURL,
                              fallbackEmoji: musician.emoji,
                              hasUnviewed: hasUnviewed,
                              size: avatarBoxSize,
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: musician.photoURL != null
                                ? () => showFullImage(context, musician.photoURL!)
                                : null,
                            child: Container(
                              width: avatarBoxSize,
                              height: avatarBoxSize,
                              decoration: BoxDecoration(
                                color: kBg3,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: musician.goldRing ? kGold : kBorder,
                                  width: 2,
                                ),
                                image: musician.photoURL != null
                                    ? DecorationImage(
                                        image: NetworkImage(musician.photoURL!),
                                        fit: BoxFit.cover,
                                      )
                                    : null,
                              ),
                              child: musician.photoURL == null
                                  ? Center(
                                      child: Text(
                                        musician.emoji,
                                        style: const TextStyle(fontSize: 24),
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: musician.isActuallyOnline ? kGreen : kMuted,
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.nunito(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: kText,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  formatActivityForCard(musician.activityType, musician.instrument),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
      ),
    );
  }
}
