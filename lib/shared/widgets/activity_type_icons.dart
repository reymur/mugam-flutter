import 'package:flutter/material.dart';

import '../../core/models/activity_type.dart';

// Category glyph for each "Fəaliyyət növü" bottom-sheet entry — all 9 are
// supplied photos (assets/icons/). The source files are portrait product
// shots on a pale card background with the actual instrument occupying
// only part of the frame (often along a diagonal, so its bounding box
// looks fuller than its actual pixel footprint) — BoxFit.cover alone still
// leaves visible card margin around it, so each is scaled up past its
// BoxFit.cover size and clipped to the glyph square, cropping the margin
// out. Scale is per-asset because the source photos don't share a margin
// ratio (e.g. guitar.png's photo is more zoomed out than keyboard.png's).
const Map<ActivityCategory, (String, double)> _categoryAssets = {
  ActivityCategory.simli: ('assets/icons/guitar.png', 1.4),
  ActivityCategory.nefes: ('assets/icons/clarinet.png', 1.6),
  ActivityCategory.klavish: ('assets/icons/keyboard.png', 1.3),
  ActivityCategory.muganni: ('assets/icons/microphone.png', 1.35),
  ActivityCategory.zerb: ('assets/icons/drums.png', 1.3),
  ActivityCategory.sesSistemleri: ('assets/icons/speaker.png', 1.26),
  ActivityCategory.videoCekilis: ('assets/icons/video_camera.png', 1.35),
  ActivityCategory.sekil: ('assets/icons/camera.png', 1.35),
  ActivityCategory.isiqSistemleri: ('assets/icons/isiq_sistemleri.png', 1.3),
};

Widget categoryGlyph(ActivityCategory category, {required double size}) {
  final (asset, scale) = _categoryAssets[category]!;
  return ClipRect(
    child: SizedBox(
      width: size,
      height: size,
      child: Transform.scale(
        scale: scale,
        child: Image.asset(asset, fit: BoxFit.cover),
      ),
    ),
  );
}
