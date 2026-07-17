import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import 'edit_profile_screen.dart';
import 'profile_settings_screen.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
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
                  _ProfileHeader(
                    user: user,
                    onSettingsTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ProfileSettingsScreen(),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 20, 14, 8),
                    child: Text(
                      'Haqqında',
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: kText,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 30),
                    child: _AboutTab(user: user),
                  ),
                ],
              ),
            );
          },
        ),
      ),
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

// ── Profile header ──────────────────────────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.user, required this.onSettingsTap});

  final User user;
  final VoidCallback onSettingsTap;

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
                // Stats — Paylaş now lives here as a small icon right next
                // to Reytinq (its own former full-width button below was
                // removed; the icon-based edit/settings affordances above
                // replace the old Redaktə et button and the tab-row's
                // Ayarlar entry the same way).
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
                    const SizedBox(width: 6),
                    _HeaderIconButton(
                      icon: Icons.share,
                      size: 18,
                      onTap: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Bu funksiya tezliklə əlavə olunacaq',
                            ),
                            backgroundColor: kBg3,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Settings — moved out of the horizontal tab row (see _TabsRow):
          // icon-only, top-left, same destination as before (activeIndex
          // 4, still handled by _TabContent's default switch case).
          Positioned(
            top: 12,
            left: 12,
            child: _HeaderIconButton(
              icon: Icons.settings,
              size: 24,
              onTap: onSettingsTap,
            ),
          ),
          // Edit — replaces the old full-width "Redaktə et" button.
          Positioned(
            top: 12,
            right: 12,
            child: _HeaderIconButton(
              icon: Icons.edit,
              size: 20,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => EditProfileScreen(user: user)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Small circular icon-only affordance used for the header's edit/settings/
// share actions — a translucent dark disc so a gold icon stays legible
// against both the plain background and the decorative gold blur circle
// behind the avatar, without needing full button chrome (label, padding,
// border) for what's just a single tap target.
class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    this.size = 20,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0x99000000),
            shape: BoxShape.circle,
            border: Border.all(color: kBorder),
          ),
          child: Icon(icon, size: size, color: kGold),
        ),
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
