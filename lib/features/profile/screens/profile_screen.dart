import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  int _activeTabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _ProfileHeader(),
              _TabsRow(
                activeIndex: _activeTabIndex,
                onTap: (i) => setState(() => _activeTabIndex = i),
              ),
              _TabContent(activeIndex: _activeTabIndex),
            ],
          ),
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

  static const _tabs = ['Haqqında', 'Video', 'Tədbirlər', 'Rəylər', '⚙️ Ayarlar'];

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
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
  const _TabContent({required this.activeIndex});

  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 30),
      child: switch (activeIndex) {
        0 => const _AboutTab(),
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
  const _AboutTab();

  static const _skills = [
    'Kaman',
    'Tar ifası',
    'Toy musiqisi',
    'Klassik muğam',
    'Canlı ifa',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoCard(
          title: 'Bacarıqlar',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _skills.map((s) => _SkillTag(label: s)).toList(),
          ),
        ),
        _InfoCard(
          title: 'Haqqında',
          child: const Text(
            '10 illik təcrübəyə malik peşəkar musiqiçiyəm...',
            style: TextStyle(
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
            Text(
              text,
              style: const TextStyle(fontSize: 14, color: kMuted),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Settings tab ──────────────────────────────────────────────────────────────

class _SettingsTab extends StatelessWidget {
  const _SettingsTab();

  @override
  Widget build(BuildContext context) {
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
      ],
    );
  }
}

// ── Profile header (unchanged) ────────────────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context) {
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
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            '🎵',
                            style: TextStyle(fontSize: 38),
                          ),
                        ),
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
                // Name
                Text(
                  'Anar Musayev',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: kText,
                  ),
                ),
                const SizedBox(height: 2),
                // Handle
                const Text(
                  '@anar_musician',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: kMuted),
                ),
                const SizedBox(height: 8),
                // Badges
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 6,
                  runSpacing: 6,
                  children: const [
                    _Badge(
                      label: '🎵 Musiqiçi',
                      textColor: kGold,
                      bgColor: Color(0x26D4A03C),
                      borderColor: Color(0x4DD4A03C),
                    ),
                    _Badge(
                      label: '✅ Təsdiqlənmiş',
                      textColor: kGreen,
                      bgColor: Color(0x2627AE60),
                      borderColor: Color(0x4D27AE60),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Bio
                const Text(
                  'Klassik kaman ifaçısı, 10 illik təcrübə',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFFB0A080),
                    height: 20 / 13,
                  ),
                ),
                const SizedBox(height: 14),
                // Stats
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    _StatItem(value: '47', label: 'Gigs'),
                    SizedBox(width: 24),
                    _StatItem(value: '234', label: 'Rəy'),
                    SizedBox(width: 24),
                    _StatItem(value: '4.9', label: 'Reytinq'),
                  ],
                ),
                const SizedBox(height: 16),
                // Action buttons
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {},
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kGold,
                          foregroundColor: const Color(0xFF1A0E00),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 10),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          elevation: 0,
                        ),
                        child: const Text(
                          'Redaktə et',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {},
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: kBorder),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 10),
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
