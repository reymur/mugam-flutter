import 'package:mugam_flutter/core/audio/voice_recording_session.dart';

/// Подделка записи голоса — одна на все тесты общего показа записи (13.09).
///
/// Настоящий сеанс тянет плагины (микрофон, временная папка, звук старта), и
/// в тесте их нет. Подделка отвечает ровно тремя ходами интерфейса и считает,
/// сколько раз каждый позвали.
class FakeVoiceRecorder implements VoiceRecorder {
  FakeVoiceRecorder({
    this.outcome = VoiceStartOutcome.started,
    this.result = const VoiceRecording(
      filePath: '/tmp/fake_voice.m4a',
      waveform: [10, 50, 90],
    ),
  });

  VoiceStartOutcome outcome;

  /// Что отдаст остановка. `null` — случайный тычок.
  VoiceRecording? result;

  int starts = 0;
  int stops = 0;
  int cancels = 0;

  @override
  Future<VoiceStartOutcome> start({void Function()? onArmed}) async {
    starts += 1;
    if (outcome == VoiceStartOutcome.started) onArmed?.call();
    return outcome;
  }

  @override
  Future<VoiceRecording?> stopAndFinish() async {
    stops += 1;
    return result;
  }

  @override
  Future<void> cancel() async {
    cancels += 1;
  }
}
