import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _hdImageUploadKey = 'hd_image_upload_enabled';

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider must be overridden with a SharedPreferences instance at app startup',
  );
});

// Global "send photos in HD" toggle, persisted across launches. Read by
// chat_screen's upload path to pick the compression tier — see
// compressImageFile in core/media/image_compressor.dart.
class HdImageUploadNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(sharedPreferencesProvider).getBool(_hdImageUploadKey) ?? false;

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await ref.read(sharedPreferencesProvider).setBool(_hdImageUploadKey, enabled);
  }
}

final hdImageUploadProvider = NotifierProvider<HdImageUploadNotifier, bool>(
  HdImageUploadNotifier.new,
);
