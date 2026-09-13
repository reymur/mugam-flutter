import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/features/agreements/widgets/leave_event_sheet.dart';
import 'package:mugam_flutter/shared/widgets/voice_hold_recorder.dart';

import 'support/fake_voice_recorder.dart';

// ЛИСТ ВЫХОДА ПИШЕТ ГОЛОС ОБЩЕЙ ЗАПИСЬЮ — место вызова №1 (13.09, вариант Б).
//
// Порча на обе стороны (требование владельца): сломанная общая запись обязана
// ронять и контроллер (`voice_hold_controller_test.dart`), и этот лист, и чат.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ «контроллер не отдаёт запись зовущему» (называется ДО
// порчи — I46): здесь — «отпустил — запись встаёт строкой на прослушку,
// отправка несёт её в результат». «Удержал микрофон» останется зелёным:
// полоса записи встаёт раньше, чем запись отдаётся.
//
// ЧЕГО НЕ ЛОВИТ: настоящий микрофон, отклик пальцу и проигрывание записи —
// проигрыватель подменён подписью (`recordingPreview`), потому что тянет
// плагин звука; это трубка.

void main() {
  Future<LeaveSheetResult?> Function() openSheet(
    WidgetTester tester,
    FakeVoiceRecorder recorder,
  ) {
    LeaveSheetResult? result;
    var closed = false;
    return () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () async {
                    result = await showModalBottomSheet<LeaveSheetResult>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => LeaveEventSheet(
                        recorder: recorder,
                        recordingPreview: (rec) =>
                            Text('preview:${rec.filePath}'),
                      ),
                    );
                    closed = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return closed ? result : null;
    };
  }

  Finder mic() => find.byIcon(Icons.mic);

  testWidgets('удержал микрофон — идёт запись, вместо поля полоса записи',
      (tester) async {
    final recorder = FakeVoiceRecorder();
    await openSheet(tester, recorder)();
    expect(find.byType(TextField), findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(mic()));
    await tester.pump();
    expect(recorder.starts, 1);
    expect(find.byType(VoiceRecordingStrip), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await gesture.up();
    await tester.pump();
    expect(find.byType(VoiceRecordingStrip), findsNothing);
  });

  testWidgets(
      'отпустил — запись встаёт строкой на прослушку, отправка несёт её в результат',
      (tester) async {
    final recorder = FakeVoiceRecorder();
    LeaveSheetResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showModalBottomSheet<LeaveSheetResult>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => LeaveEventSheet(
                      recorder: recorder,
                      recordingPreview: (rec) =>
                          Text('preview:${rec.filePath}'),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(mic()));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('preview:${recorder.result!.filePath}'), findsOneWidget,
        reason: 'готовая запись не встала строкой — лист её не получил');

    await tester.tap(find.widgetWithText(TextButton, 'Gələ bilmirəm'));
    await tester.pumpAndSettle();
    expect(result, isNotNull, reason: 'лист не закрылся отправкой');
    expect(result!.voice, recorder.result,
        reason: 'отправка не несёт записанное — выход ушёл бы без голоса');
  });
}
