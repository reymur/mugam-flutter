import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/settings/image_quality_settings.dart';
import '../../../core/settings/upload_limit_settings.dart';
import '../../../core/theme/colors.dart';

// General app settings, not tied to the user's profile — reached from the
// gear icon in the chats list AppBar. Currently the HD media-upload toggle
// (applies to both photos and videos) and the max-file-size slider; more
// app-wide settings belong here going forward.
class AppSettingsScreen extends ConsumerStatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  ConsumerState<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends ConsumerState<AppSettingsScreen> {
  // Ephemeral drag value so the label/thumb track the finger smoothly;
  // the Firestore write (maxUploadSizeMbProvider.notifier.setMb) only
  // fires on release (onChangeEnd), not on every onChanged tick — a
  // continuous drag would otherwise hammer Firestore with dozens of writes
  // for a single gesture. Null until the user actually drags, so the
  // slider tracks the live provider value (e.g. after loading, or a value
  // change from elsewhere) whenever it isn't mid-drag.
  int? _draftMb;

  @override
  Widget build(BuildContext context) {
    final hdEnabled = ref.watch(hdImageUploadProvider);
    final savedMb = ref.watch(maxUploadSizeMbProvider);
    final displayMb = _draftMb ?? savedMb;
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
              'Şəkil və videoları yüksək keyfiyyətdə göndər (daha çox trafik)',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
            activeThumbColor: kGold,
            value: hdEnabled,
            onChanged: (value) =>
                ref.read(hdImageUploadProvider.notifier).setEnabled(value),
          ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file, color: kGold),
            title: const Text(
              'Maksimum fayl ölçüsü',
              style: TextStyle(color: kText),
            ),
            subtitle: Text(
              '$displayMb MB',
              style: const TextStyle(color: kMuted, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Slider(
              value: displayMb.toDouble().clamp(
                MaxUploadSizeMbNotifier.minMb.toDouble(),
                MaxUploadSizeMbNotifier.maxMb.toDouble(),
              ),
              min: MaxUploadSizeMbNotifier.minMb.toDouble(),
              max: MaxUploadSizeMbNotifier.maxMb.toDouble(),
              activeColor: kGold,
              label: '$displayMb MB',
              onChanged: (value) =>
                  setState(() => _draftMb = value.round()),
              onChangeEnd: (value) {
                final mb = value.round();
                setState(() => _draftMb = null);
                ref.read(maxUploadSizeMbProvider.notifier).setMb(mb);
              },
            ),
          ),
        ],
      ),
    );
  }
}
