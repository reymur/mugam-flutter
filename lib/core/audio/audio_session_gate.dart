import 'package:audio_session/audio_session.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

// Вынесено из `chat_screen.dart` 13.08 вместе с записью голоса. Обе функции
// жили там приватными и звались из двух мест ОДНОГО экрана (запись и
// проигрывание); с выносом записи в общее место звать их стало нужно из
// трёх, и копия в каждом месте — ровно то, чего работа 2 и избегает.
//
// Neither `record` nor `just_audio` ever sends AVAudioSession the explicit
// "I'm done" signal on stop/pause — they set category/options and activate
// on start, but never deactivate. Without this, background audio (Spotify
// etc.) stays ducked until the app is backgrounded/foregrounded, which
// happens to force a session reset as a side effect. Calling this
// ourselves right after stop/pause releases ducking immediately instead of
// relying on that incidental reset.
Future<void> deactivateAudioSession() async {
  try {
    final session = await AudioSession.instance;
    await session.setActive(false);
  } catch (e, st) {
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'audio_session_gate: deactivateAudioSession failed',
    );
  }
}

// Paired with deactivateAudioSession above — needed because that manual
// deactivate (on pause/natural-completion) isn't reliably followed by an
// equally explicit reactivation anywhere: just_audio's own implicit
// activate-on-start covers a message's first-ever play, but replaying an
// already-completed voice message (play -> complete -> our deactivate ->
// play again) hit the exact same silent-while-visually-playing race as the
// loop/message-switch bugs fixed earlier — just triggered by replay instead
// of looping or switching. Called explicitly (and awaited, unlike the
// fire-and-forget deactivate calls) right before play() so the session is
// genuinely active before playback starts producing audio.
Future<void> activateAudioSession() async {
  try {
    final session = await AudioSession.instance;
    await session.setActive(true);
  } catch (e, st) {
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'audio_session_gate: activateAudioSession failed',
    );
  }
}
