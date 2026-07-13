import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';

// Presentational only — no tap handling. The parent (feed bar) wires onTap.
class AvatarRing extends StatelessWidget {
  final String? photoURL;
  final bool hasUnviewed;
  final double size;

  const AvatarRing({
    super.key,
    required this.photoURL,
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
            // Existing avatars (_ContactAvatar, profile_screen.dart) fall
            // back to the user's own emoji field on a null photo — not
            // available here, since this widget deliberately only takes a
            // photoURL to stay data-layer agnostic (reused for any status
            // owner without needing a full User). Icons.person is the
            // closest faithful match: same null-check structure/circular
            // clip as those, generic content in place of the unavailable
            // per-user emoji.
            : const Center(child: Icon(Icons.person, color: kMuted)),
      ),
    );
  }
}
