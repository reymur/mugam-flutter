import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/models/activity_type.dart';
import '../core/theme/colors.dart';
import '../shared/widgets/activity_type_icons.dart';
import '../shared/widgets/activity_type_sheet.dart';

// DEV-ONLY visual review screen for the "Fəaliyyət növü" category glyphs —
// renders the real categoryGlyph() used by ActivityTypeSheet for all 9
// categories, so image-asset swaps can be checked before/without touching
// the sheet itself. Run via `flutter run -t lib/dev_preview/icon_preview_main.dart`.
class IconPreviewScreen extends StatelessWidget {
  const IconPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tiles = <(String, Widget Function(double))>[
      for (final cat in ActivityCategory.values)
        (
          ActivityType.categoryLabels[cat]!,
          (double size) => categoryGlyph(cat, size: size),
        ),
    ];

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: Text(
          'Icon preview (dev only)',
          style: GoogleFonts.nunito(color: Colors.white),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: kGold,
        onPressed: () => ActivityTypeSheet.show(context),
        label: const Text('Open real sheet'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: GridView.builder(
              padding: const EdgeInsets.all(20),
              shrinkWrap: true,
              itemCount: tiles.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 20,
                crossAxisSpacing: 16,
                childAspectRatio: 0.85,
              ),
              itemBuilder: (context, i) {
                final (label, builder) = tiles[i];
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Large — full-bleed, no inset, matching the fix.
                    Container(
                      width: 72,
                      height: 72,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: kBg2,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: kGoldDim),
                      ),
                      child: builder(72),
                    ),
                    const SizedBox(height: 8),
                    // Small — exactly as the sheet's 34px category chip.
                    Container(
                      width: 34,
                      height: 34,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: kBg2,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: kGoldDim),
                      ),
                      child: builder(34),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.nunito(
                        color: kMuted,
                        fontSize: 12,
                        height: 1.2,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
