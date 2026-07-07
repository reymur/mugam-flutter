import 'package:flutter/services.dart';

// Thin wrapper around a per-platform, purpose-built low-latency sound
// mechanism — iOS: a small pool of pre-buffered AVAudioPlayer instances
// (prepareToPlay() called at load time); Android: SoundPool. Deliberately
// NOT a full media engine like just_audio/SoLoud (those exist to stream
// long-form audio and carry real initialization latency per play, which is
// exactly the "delayed click" problem this replaces) and deliberately does
// NOT touch AVAudioSession/AudioManager focus on either platform — so it
// can never conflict with this app's own carefully-tuned recording/voice-
// message audio session management (see chat_screen.dart's
// _activateAudioSession/_deactivateAudioSession).
//
// Android side is implemented (SoundPool, same shape as iOS) but UNTESTED —
// no Android device was available this session. Verify on a real Android
// device before relying on it; the iOS path is the one confirmed on-device.
class NativeSoundEffect {
  NativeSoundEffect._();

  static const MethodChannel _channel = MethodChannel(
    'mugam/native_sound_effect',
  );

  // Must be called once per soundId before play() — preloads/prepares the
  // asset natively so playback is instant, not on first use.
  static Future<void> load(String soundId, String assetPath) {
    return _channel.invokeMethod('load', {
      'soundId': soundId,
      'path': assetPath,
    });
  }

  static Future<void> play(String soundId) {
    return _channel.invokeMethod('play', {'soundId': soundId});
  }
}
