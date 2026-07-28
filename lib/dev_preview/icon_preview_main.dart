import 'package:flutter/material.dart';

import 'icon_preview_screen.dart';

// DEV-ONLY alternate entry point: `flutter run -t lib/dev_preview/icon_preview_main.dart`
// Boots straight into the icon preview grid, bypassing Firebase/auth/the
// real app shell entirely.
void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: IconPreviewScreen(),
    ),
  );
}
