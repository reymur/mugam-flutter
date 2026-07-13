import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';

// Presentational only — no tap handling. The parent (feed bar) wires onTap.
class AvatarRing extends StatelessWidget {
  final String? photoURL;
  // Matches the app's existing avatar-fallback convention (_ContactAvatar,
  // profile_screen.dart both fall back to the user's own emoji field on a
  // null photo) instead of diverging from it — purely additive/optional so
  // this widget still doesn't need to fetch any User data itself, callers
  // just pass along whatever emoji they already have on hand.
  final String? fallbackEmoji;
  final bool hasUnviewed;
  final double size;

  const AvatarRing({
    super.key,
    required this.photoURL,
    this.fallbackEmoji,
    required this.hasUnviewed,
    this.size = 64,
  });

  @override
  Widget build(BuildContext context) {
    // kGold for "at least one unviewed status in this ring" (WhatsApp's own
    // gold-vs-gray distinction), kMuted rather than kBorder for the viewed
    // state — kBorder is a near-invisible ~15%-alpha wash already used
    // elsewhere as every avatar's plain resting border (_ContactAvatar,
    // chats_screen.dart's chat-list avatar), so reusing it here would make
    // "viewed" read as no ring at all instead of a distinct, deliberately
    // muted state.
    final ringColor = hasUnviewed ? kGold : kMuted;

    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ringColor, width: 2.5),
      ),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: kBg3),
        child: photoURL != null
            ? CachedNetworkImage(
                imageUrl: photoURL!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                placeholder: (context, url) =>
                    const Center(child: CircularProgressIndicator(color: kGold)),
              )
            : fallbackEmoji != null
            ? Center(
                // _ContactAvatar uses fontSize: 64 on a 140px avatar (ratio
                // ~0.457) — profile_screen.dart's 86px avatar uses fontSize:
                // 38 (ratio ~0.442), same proportion. Scaled by `size` here
                // rather than hardcoding either literal value, since this
                // widget (unlike those two) is reused at variable sizes.
                child: Text(
                  fallbackEmoji!,
                  style: TextStyle(fontSize: size * 0.45),
                ),
              )
            // Last resort only, when the caller has neither a photo nor an
            // emoji to fall back to.
            : const Center(child: Icon(Icons.person, color: kMuted)),
      ),
    );
  }
}
