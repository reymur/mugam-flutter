import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';

class CallAvatarPanel extends StatelessWidget {
  final String name;
  final String? emoji;
  final String? subtitle;

  const CallAvatarPanel({super.key, required this.name, this.emoji, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 64,
            backgroundColor: kBg3,
            child: Text(emoji ?? '🎵', style: const TextStyle(fontSize: 50)),
          ),
          const SizedBox(height: 20),
          Text(name, style: GoogleFonts.nunito(fontSize: 24, color: kText, fontWeight: FontWeight.w600)),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle!, style: const TextStyle(color: kMuted, fontSize: 15)),
          ],
        ],
      ),
    );
  }
}
