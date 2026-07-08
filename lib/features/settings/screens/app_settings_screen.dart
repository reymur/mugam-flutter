import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/settings/image_quality_settings.dart';
import '../../../core/theme/colors.dart';

// General app settings, not tied to the user's profile — reached from the
// gear icon in the chats list AppBar. Currently just the HD photo-upload
// toggle; more app-wide settings belong here going forward.
class AppSettingsScreen extends ConsumerWidget {
  const AppSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hdEnabled = ref.watch(hdImageUploadProvider);
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        title: const Text('Ayarlar', style: TextStyle(color: kText)),
        iconTheme: const IconThemeData(color: kGold),
      ),
      body: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.high_quality, color: kGold),
            title: const Text('HD keyfiyyət', style: TextStyle(color: kText)),
            subtitle: const Text(
              'Şəkilləri orijinal ölçüdə göndər (daha çox trafik)',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
            activeThumbColor: kGold,
            value: hdEnabled,
            onChanged: (value) =>
                ref.read(hdImageUploadProvider.notifier).setEnabled(value),
          ),
        ],
      ),
    );
  }
}
