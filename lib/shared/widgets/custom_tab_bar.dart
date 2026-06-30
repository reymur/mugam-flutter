import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/colors.dart';

const _kTabs = [
  ('🏠', 'KLUB'),
  ('📅', 'KALENDAR'),
  ('🔍', 'AXTAR'),
  ('📢', 'ELANLAR'),
  ('🎼', 'SİFARİŞ'),
  ('🛍', 'BAZAR'),
  ('😄', 'HEKAYƏ'),
  ('🎬', 'VİDEO'),
  ('💬', 'MESAJ'),
  ('👤', 'PROFİL'),
];

const _kChatsIndex = 8;

class CustomTabBar extends StatelessWidget {
  const CustomTabBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.unreadCount = 0,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF70C0A06),
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: kNavH,
          child: Row(
            children: List.generate(_kTabs.length, (i) {
              final (emoji, label) = _kTabs[i];
              final isActive = i == currentIndex;
              return Expanded(
                child: GestureDetector(
                  onTap: () => onTap(i),
                  behavior: HitTestBehavior.opaque,
                  child: _TabItem(
                    emoji: emoji,
                    label: label,
                    isActive: isActive,
                    badge: i == _kChatsIndex ? unreadCount : 0,
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.emoji,
    required this.label,
    required this.isActive,
    required this.badge,
  });

  final String emoji;
  final String label;
  final bool isActive;
  final int badge;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedScale(
          scale: isActive ? 1.15 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: Opacity(
            opacity: isActive ? 1.0 : 0.45,
            child: badge > 0
                ? Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Text(emoji, style: const TextStyle(fontSize: 20)),
                      Positioned(
                        top: -4,
                        right: -8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: kRed,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            badge > 9 ? '9+' : '$badge',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : Text(emoji, style: const TextStyle(fontSize: 20)),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: GoogleFonts.nunito(
            fontSize: 9,
            fontWeight: FontWeight.w800,
            color: isActive ? kGold : kMuted,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}
