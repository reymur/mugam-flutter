import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/audio/voice_recording_session.dart';
import 'package:mugam_flutter/features/chat/widgets/chat_voice_record_button.dart';
import 'package:mugam_flutter/shared/widgets/voice_hold_recorder.dart';

import 'support/fake_voice_recorder.dart';

// ЧАТ ПИШЕТ ГОЛОСОВОЕ ОБЩЕЙ ЗАПИСЬЮ — место вызова №2 (13.09, вариант Б, шаг 3).
//
// Порча на обе стороны (требование владельца): сломанная общая запись обязана
// ронять контроллер (`voice_hold_controller_test.dart`), лист выхода
// (`leave_event_sheet_test.dart`) и этот файл — не одно место.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ «контроллер не отдаёт запись зовущему» (называется ДО
// порчи — I46): оба теста этого файла.
//
// ЧЕГО НЕ ЛОВИТ: сам хвост чата — очередь отправки, цитату, крутилку — он
// остался в `chat_screen.dart` без изменений и проверяется на трубке; и
// раскладку строки ввода вокруг кнопки — тоже трубка.

void main() {
  Future<(VoiceHoldController, List<VoiceRecording>, FakeVoiceRecorder)> pump(
    WidgetTester tester,
  ) async {
    final recorder = FakeVoiceRecorder();
    final handed = <VoiceRecording>[];
    final controller = VoiceHoldController(
      recorder: recorder,
      onRecorded: (rec) async => handed.add(rec),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ChatVoiceRecordButton(
              controller: controller,
              uploading: false,
            ),
          ),
        ),
      ),
    );
    return (controller, handed, recorder);
  }

  testWidgets('чат: удержал и отпустил микрофон — запись уходит хвосту чата',
      (tester) async {
    final (controller, handed, recorder) = await pump(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump();
    expect(controller.isRecording, isTrue);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(handed, [recorder.result],
        reason: 'запись не дошла до хвоста чата — голосовое не ушло бы');
  });

  testWidgets('чат: при замке кнопка отправки останавливает и отдаёт запись',
      (tester) async {
    final (controller, handed, recorder) = await pump(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic)));
    await tester.pump();
    await gesture.moveBy(const Offset(0, VoiceHoldController.lockThreshold - 1));
    await tester.pump();
    expect(controller.isLocked, isTrue);

    await gesture.up();
    await tester.pump();
    expect(handed, isEmpty, reason: 'при замке отпускание не отправляет');

    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(handed, [recorder.result],
        reason: 'кнопка отправки при замке не отдала запись хвосту чата');
  });
}
