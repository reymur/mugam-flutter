import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/cache/message_cache_service.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/auth_service.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  int _activeTabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final userAsync = ref.watch(currentUserProvider(currentUid));

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: userAsync.when(
          loading: () =>
              const Center(child: CircularProgressIndicator(color: kGold)),
          error: (_, _) => const Center(
            child: Text('Xəta baş verdi', style: TextStyle(color: kMuted)),
          ),
          data: (user) {
            if (user == null) {
              return const Center(
                child: Text(
                  'İstifadəçi tapılmadı',
                  style: TextStyle(color: kMuted),
                ),
              );
            }
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ProfileHeader(user: user),
                  _TabsRow(
                    activeIndex: _activeTabIndex,
                    onTap: (i) => setState(() => _activeTabIndex = i),
                  ),
                  _TabContent(activeIndex: _activeTabIndex, user: user),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// ── Tab row ──────────────────────────────────────────────────────────────────

class _TabsRow extends StatelessWidget {
  const _TabsRow({required this.activeIndex, required this.onTap});

  final int activeIndex;
  final ValueChanged<int> onTap;

  static const _tabs = [
    'Haqqında',
    'Video',
    'Tədbirlər',
    'Rəylər',
    '⚙️ Ayarlar',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16, bottom: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: List.generate(_tabs.length, (i) {
            final active = i == activeIndex;
            return GestureDetector(
              onTap: () => onTap(i),
              child: Container(
                margin: EdgeInsets.only(right: i < _tabs.length - 1 ? 8 : 0),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: active ? kGold : Colors.transparent,
                  border: active ? null : Border.all(color: kBorder),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _tabs[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: active ? const Color(0xFF1A0E00) : kMuted,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ── Tab content dispatcher ────────────────────────────────────────────────────

class _TabContent extends StatelessWidget {
  const _TabContent({required this.activeIndex, required this.user});

  final int activeIndex;
  final User user;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 30),
      child: switch (activeIndex) {
        0 => _AboutTab(user: user),
        1 => const _Placeholder(emoji: '🎬', text: 'Tezliklə əlavə olunacaq'),
        2 => const _Placeholder(emoji: '📅', text: 'Tezliklə əlavə olunacaq'),
        3 => const _Placeholder(emoji: '⭐', text: 'Tezliklə əlavə olunacaq'),
        _ => const _SettingsTab(),
      },
    );
  }
}

// ── About tab ─────────────────────────────────────────────────────────────────

class _AboutTab extends StatelessWidget {
  const _AboutTab({required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (user.instrument.isNotEmpty)
          _InfoCard(
            title: 'Bacarıqlar',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [_SkillTag(label: user.instrument)],
            ),
          ),
        _InfoCard(
          title: 'Haqqında',
          child: Text(
            user.bio.isNotEmpty ? user.bio : 'Məlumat yoxdur',
            style: const TextStyle(
              fontSize: 13,
              color: kMuted,
              height: 20 / 13,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              title,
              style: GoogleFonts.playfairDisplay(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: kText,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _SkillTag extends StatelessWidget {
  const _SkillTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: kGoldDim, // 0x14D4A03C ≈ 8% gold tint
        border: Border.all(color: const Color(0x40D4A03C)), // 25% gold tint
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: kGold,
        ),
      ),
    );
  }
}

// ── Placeholder for tabs 1–4 ──────────────────────────────────────────────────

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.emoji, required this.text});

  final String emoji;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(text, style: const TextStyle(fontSize: 14, color: kMuted)),
          ],
        ),
      ),
    );
  }
}

// ── Settings tab ──────────────────────────────────────────────────────────────

class _SettingsTab extends ConsumerWidget {
  const _SettingsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final incomingAsync = ref.watch(incomingFriendRequestsProvider(currentUid));
    // AsyncError here means the read was denied (e.g. firestore.rules for
    // friendRequests was rolled back while this build is still installed on
    // a device) — same "fail silent, not visibly broken" contract as
    // UserProfileScreen._buildFriendButton's own error branch. Showing this
    // entry point with a badge that can never load, leading to a screen
    // that can only ever say "Xəta baş verdi", would be worse than not
    // showing it at all.
    if (incomingAsync.hasError) {
      return Column(
        children: [
          ListTile(
            leading: const Icon(Icons.star, color: kGold),
            title: const Text(
              'Seçilmiş mesajlar',
              style: TextStyle(color: kText),
            ),
            trailing: const Icon(Icons.chevron_right, color: kMuted),
            onTap: () => context.push('/starred'),
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: kRed),
            title: const Text('Çıxış', style: TextStyle(color: kRed)),
            onTap: () => _confirmLogout(context, ref),
          ),
        ],
      );
    }
    final incomingCount = incomingAsync.asData?.value.length ?? 0;

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.people_alt, color: kGold),
          title: const Text(
            'Dost sorğuları',
            style: TextStyle(color: kText),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (incomingCount > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: kGold,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$incomingCount',
                    style: const TextStyle(
                      color: Color(0xFF1A0E00),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              const Icon(Icons.chevron_right, color: kMuted),
            ],
          ),
          onTap: () => context.push('/friend-requests'),
        ),
        ListTile(
          leading: const Icon(Icons.star, color: kGold),
          title: const Text(
            'Seçilmiş mesajlar',
            style: TextStyle(color: kText),
          ),
          trailing: const Icon(Icons.chevron_right, color: kMuted),
          onTap: () => context.push('/starred'),
        ),
        ListTile(
          leading: const Icon(Icons.logout, color: kRed),
          title: const Text('Çıxış', style: TextStyle(color: kRed)),
          onTap: () => _confirmLogout(context, ref),
        ),
      ],
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text('Çıxış', style: TextStyle(color: kText)),
        content: const Text(
          'Hesabdan çıxmaq istəyirsiniz?',
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Ləğv et', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Çıxış', style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    final service = ref.read(firestoreServiceProvider);
    try {
      if (uid != null && uid.isNotEmpty) {
        await service.setUserPresence(uid, online: false);
        await service.clearActiveUserFromAllChats(uid);
      }
      await ref.read(messageCacheServiceProvider).clearAll();
      await AuthService().logout();
      if (context.mounted) context.go('/login');
    } catch (e, st) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Çıxış zamanı xəta baş verdi: $e'),
            backgroundColor: kRed,
          ),
        );
      }
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'ProfileScreen: sign out failed',
      );
    }
  }
}

// ── Profile header ──────────────────────────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    final isMusician = user.role == 'musician';
    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(color: Color(0xFF15100A)),
      child: Stack(
        children: [
          Positioned(
            top: -40,
            right: -40,
            child: Container(
              width: 200,
              height: 200,
              decoration: const BoxDecoration(
                color: Color(0x33D4A03C),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Avatar
                Center(
                  child: GestureDetector(
                    onTap: user.photoURL != null
                        ? () => showFullImage(context, user.photoURL!)
                        : null,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Stack(
                        children: [
                          Container(
                            width: 86,
                            height: 86,
                            decoration: BoxDecoration(
                              color: kBg3,
                              shape: BoxShape.circle,
                              border: Border.all(color: kGold, width: 3),
                              image: user.photoURL != null
                                  ? DecorationImage(
                                      image: NetworkImage(user.photoURL!),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            alignment: Alignment.center,
                            child: user.photoURL == null
                                ? Text(
                                    user.emoji,
                                    style: const TextStyle(fontSize: 38),
                                  )
                                : null,
                          ),
                          if (user.verified)
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: kGold,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFF15100A),
                                    width: 2,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: const Text(
                                  '✓',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF1A0E00),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Name
                Text(
                  user.name,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: kText,
                  ),
                ),
                const SizedBox(height: 8),
                // Badges
                if (isMusician || user.verified)
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (isMusician)
                        const _Badge(
                          label: '🎵 Musiqiçi',
                          textColor: kGold,
                          bgColor: Color(0x26D4A03C),
                          borderColor: Color(0x4DD4A03C),
                        ),
                      if (user.verified)
                        const _Badge(
                          label: '✅ Təsdiqlənmiş',
                          textColor: kGreen,
                          bgColor: Color(0x2627AE60),
                          borderColor: Color(0x4D27AE60),
                        ),
                    ],
                  ),
                if (user.bio.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  // Bio
                  Text(
                    user.bio,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFFB0A080),
                      height: 20 / 13,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                // Stats
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _StatItem(value: '${user.gigs}', label: 'Gigs'),
                    const SizedBox(width: 24),
                    _StatItem(value: '${user.reviews}', label: 'Rəy'),
                    const SizedBox(width: 24),
                    _StatItem(
                      value: user.rating.toStringAsFixed(1),
                      label: 'Reytinq',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Action buttons
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                EditProfileScreen(user: user),
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kGold,
                          foregroundColor: const Color(0xFF1A0E00),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          elevation: 0,
                        ),
                        child: const Text(
                          'Redaktə et',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Bu funksiya tezliklə əlavə olunacaq',
                              ),
                              backgroundColor: kBg3,
                            ),
                          );
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: kBorder),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: kText,
                        ),
                        child: const Text(
                          'Paylaş',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: kText,
                          ),
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

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.textColor,
    required this.bgColor,
    required this.borderColor,
  });

  final String label;
  final Color textColor;
  final Color bgColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: textColor,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: GoogleFonts.playfairDisplay(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: kGold2,
          ),
        ),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            color: kMuted,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
