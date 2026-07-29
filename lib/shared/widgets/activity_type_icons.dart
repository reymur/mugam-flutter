import 'package:flutter/material.dart';

import '../../core/models/activity_type.dart';
import '../../core/theme/colors.dart';

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

// Per-instrument glyphs for every leaf option across simli/nefes/klavish/
// zerb — muganni's roles (Muğam ifaçısı, Xanəndə, Şanson, Aparıcı) and every
// category's "Digər" aren't physical instruments, so they fall through to
// the placeholder note glyph.
const Map<String, String> _instrumentAssets = {
  'Gitara': 'assets/icons/gitara.png',
  'Saz': 'assets/icons/saz.png',
  'Skripka': 'assets/icons/skripka.png',
  'Kanun': 'assets/icons/kanun.png',
  'Tar': 'assets/icons/tar.jpg',
  'Kamança': 'assets/icons/kamanca.png',
  'Ud': 'assets/icons/ud.png',
  'Klarnet': 'assets/icons/klarnet.png',
  'Balaban': 'assets/icons/balaban.png',
  'Zurna': 'assets/icons/zurna.png',
  'Tütək': 'assets/icons/tutek.png',
  'Saksafon': 'assets/icons/saksafon.png',
  'Qaboy': 'assets/icons/qaboy.png',
  'Sintezator': 'assets/icons/sintezator.png',
  'Qarmon': 'assets/icons/qarmon.png',
  'Udarnik': 'assets/icons/udarnik.png',
  'Nağara': 'assets/icons/nagara.png',
  'Zərb': 'assets/icons/zerb.png',
  'Dəf': 'assets/icons/def.png',
  'Davul': 'assets/icons/davul.png',
};

Widget instrumentGlyph(String label, {required double size}) {
  final asset = _instrumentAssets[label];
  if (asset == null) {
    return Icon(Icons.music_note_rounded, size: size * 0.55, color: kMuted);
  }
  return ClipRRect(
    borderRadius: BorderRadius.circular(size * 0.22),
    child: Image.asset(asset, width: size, height: size, fit: BoxFit.cover),
  );
}
