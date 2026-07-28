import 'package:flutter/material.dart';

import '../../core/constants/musician_options.dart';
import '../../core/theme/colors.dart';

// Bottom sheet for picking a city from kCities — auto-pops on tap (unlike
// ActivityTypeSheet, a single selection needs no confirm step). Shared
// between EditProfileScreen and RegisterScreen so both use the exact same
// picker instead of each keeping its own chip-grid.
class CityPickerSheet {
  static Future<String?> show(BuildContext context, {String? initial}) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: kBg2,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Şəhər seçin',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: kText,
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: kCities.length,
                itemBuilder: (context, index) {
                  final cityName = kCities[index];
                  return ListTile(
                    leading: const Icon(
                      Icons.location_on_outlined,
                      color: kGold,
                    ),
                    title: Text(
                      cityName,
                      style: TextStyle(
                        color: initial == cityName ? kGold : kText,
                        fontWeight: initial == cityName
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: initial == cityName
                        ? const Icon(Icons.check, color: kGold)
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(cityName),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
