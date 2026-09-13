import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/audio/voice_recording_session.dart';
import 'package:mugam_flutter/shared/widgets/voice_hold_recorder.dart';

import 'support/fake_voice_recorder.dart';

// ОБЩАЯ ЗАПИСЬ ГОЛОСА УДЕРЖАНИЕМ — контроллер (решение владельца 13.09).
//
// Утверждения о НАЛИЧИИ (I31): отдана ли запись, идёт ли, заперта ли. Ослепни
// контроллер — ожидаемого не будет, и тест покраснеет.
//
// ПОРЧА НА ОБЕ СТОРОНЫ (требование владельца): сломанное общее обязано ронять
// не только этот файл, но и оба места вызова — тест листа выхода и тест записи
// в чате. Этот файл — общая сторона; места добавятся шагами перевода.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ «контроллер не отдаёт запись зовущему» (называется ДО
// порчи — I46): «нажал — идёт запись; отпустил — запись отдана зовущему» и
// «вверх за порог — замок: отпускание не останавливает, стоп отдаёт запись».
//
// ЧЕГО НЕ ЛОВИТ: настоящий микрофон и отклик пальцу — это трубка; как кнопка и
// полоса выглядят — это глаза.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const origin = Offset(200, 400);

  VoiceHoldController make(
    FakeVoiceRecorder recorder,
    List<VoiceRecording> handed, {
    List<String>? said,
  }) {
    final c = VoiceHoldController(
      recorder: recorder,
      onRecorded: (rec) async => handed.add(rec),
      onNoPermission: () => said?.add('mikrofon'),
    );
    addTearDown(c.dispose);
    return c;
  }

  test('нажал — идёт запись; отпустил — запись отдана зовущему', () async {
    final recorder = FakeVoiceRecorder();
    final handed = <VoiceRecording>[];
    final c = make(recorder, handed);

    await c.pointerDown(origin);
    expect(c.isRecording, isTrue);

    await c.pointerUp();
    expect(c.isRecording, isFalse);
    expect(handed, [recorder.result]);
    expect(recorder.stops, 1);
  });

  test('смахнул влево за порог — отмена, зовущему не отдано ничего', () async {
    final recorder = FakeVoiceRecorder();
    final handed = <VoiceRecording>[];
    final c = make(recorder, handed);

    await c.pointerDown(origin);
    c.pointerMove(origin.translate(VoiceHoldController.cancelThreshold - 1, 0));
    expect(c.isRecording, isFalse);
    expect(recorder.cancels, 1);

    await c.pointerUp();
    expect(handed, isEmpty);
    expect(recorder.stops, 0);
  });

  test('вверх за порог — замок: отпускание не останавливает, стоп отдаёт запись',
      () async {
    final recorder = FakeVoiceRecorder();
    final handed = <VoiceRecording>[];
    final c = make(recorder, handed);

    await c.pointerDown(origin);
    c.pointerMove(origin.translate(0, VoiceHoldController.lockThreshold - 1));
    expect(c.isLocked, isTrue);

    await c.pointerUp();
    expect(c.isRecording, isTrue, reason: 'при замке палец отпускают свободно');
    expect(handed, isEmpty);

    await c.stop();
    expect(c.isRecording, isFalse);
    expect(handed, [recorder.result]);
  });

  test('нет разрешения — записи нет, зовущему сказано', () async {
    final recorder = FakeVoiceRecorder(outcome: VoiceStartOutcome.noPermission);
    final handed = <VoiceRecording>[];
    final said = <String>[];
    final c = make(recorder, handed, said: said);

    await c.pointerDown(origin);
    expect(c.isRecording, isFalse);
    expect(said, ['mikrofon']);
  });

  test('сеанс ничего не отдал (случайный тычок) — зовущий не зовётся', () async {
    final recorder = FakeVoiceRecorder()..result = null;
    final handed = <VoiceRecording>[];
    final c = make(recorder, handed);

    await c.pointerDown(origin);
    await c.pointerUp();
    expect(recorder.stops, 1);
    expect(handed, isEmpty);
  });
}
