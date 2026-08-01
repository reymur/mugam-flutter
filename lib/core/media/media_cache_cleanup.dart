import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/chat/screens/media_thumbnail_cache.dart';
// Both files declare a class literally named VideoCacheManager (chat videos
// and status videos are deliberately separate stores) — prefixed rather
// than shown, since `show` can't disambiguate two identical names.
import '../../features/chat/screens/video_message_widgets.dart' as chat_video;
import '../../shared/widgets/status_video_player.dart' as status_video;

// Everything on this device holding decoded/downloaded media bytes that
// belonged to whoever was signed in before — wiped when a DIFFERENT account
// signs in on the same device (see main.dart's
// _reconcileLocalStoreWithSignedInUid, which is also what makes this
// crash-resilient via a persisted "wipe pending" marker).
//
// Deliberately NOT run on an ordinary sign-out, or on signing back into the
// same account: these caches exist precisely so a returning user doesn't
// re-download their own photos and videos, and that's the common case. The
// account actually changing is the only moment the contents stop belonging
// to the person using the device.
//
// "The new account can't construct the Storage URLs, so it can never read
// these entries" is not a sufficient argument for leaving them: the bytes
// are still sitting in the app container, reachable outside the app's own
// UI (a shared, lost, or resold phone; a filesystem/backup extraction).
// For a messenger carrying private photos, video and voice notes, deleting
// them is the only defensible default.
Future<void> clearMediaCachesForAccountChange() async {
  // flutter_cache_manager stores — the on-disk half. Each is an independent
  // store with its own directory, so all three have to be emptied by name;
  // there is no global "empty every cache manager" call.
  await _guard('DefaultCacheManager', () => DefaultCacheManager().emptyCache());
  await _guard(
    'chat VideoCacheManager',
    () => chat_video.VideoCacheManager.instance.emptyCache(),
  );
  await _guard(
    'status VideoCacheManager',
    () => status_video.VideoCacheManager.instance.emptyCache(),
  );

  // In-memory halves. These die with the process anyway, so they only
  // matter for an account switch that happens without an app restart in
  // between — but that's a perfectly ordinary flow (Çıxış → log in as
  // someone else), and the previous account's decoded bytes would otherwise
  // stay live in RAM and keep rendering.
  await _guard('thumbnail caches', () async {
    MediaThumbnailCacheManager.instance.clear();
    ImagePreviewCacheManager.instance.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  // Loose files the app writes to its own temp directory outside any cache
  // manager: compressed copies made before sending (video_compressor,
  // image_compressor), voice-note recordings, camera captures, map
  // snapshots, and — the most sensitive of the set — chat documents
  // downloaded to be opened with open_filex, plus media copied out for
  // share/save. iOS may reclaim tmp on its own eventually, but that's not
  // a guarantee and never prompt.
  await _guard('temp directory', _emptyTempDirectory);
}

Future<void> _emptyTempDirectory() async {
  final dir = await getTemporaryDirectory();
  if (!await dir.exists()) return;
  await for (final entity in dir.list()) {
    try {
      await entity.delete(recursive: true);
    } catch (e) {
      // A single locked/in-use entry must not abort the rest of the sweep.
      debugPrint('media cleanup: could not delete ${entity.path} ($e)');
    }
  }
}

// Each step is independently guarded: one cache store failing (a locked
// sqlite file, a permissions quirk) must not skip the stores after it.
Future<void> _guard(String label, Future<void> Function() step) async {
  try {
    await step();
  } catch (e, st) {
    debugPrint('media cleanup: $label failed ($e)');
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'clearMediaCachesForAccountChange: $label failed',
    );
  }
}
