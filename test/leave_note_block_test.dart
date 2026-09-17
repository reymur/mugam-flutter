import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mugam_flutter/features/agreements/widgets/leave_note_block.dart';
import 'package:mugam_flutter/navigation/app_tabs.dart';
import 'package:mugam_flutter/shared/widgets/voice_player.dart';

// ДВЕРЬ В ПЕРЕПИСКУ У РАСКРЫТОЙ ПРИЧИНЫ — ПОСЛЕДНЕЙ СТРОКОЙ БЛОКА (17.09).
//
// Решение владельца, вариант А: значок ведёт в переписку с ЧЕЛОВЕКОМ, то есть
// принадлежит всему блоку, а не тексту и не голосу. До 17.09 он стоял справа в
// `Row` с `crossAxisAlignment.start` — вровень с первой строкой колонки, в
// своей пустой полосе на всю высоту, и выглядел оторванным.
//
// Проверяется РАСКЛАДКОЙ, а не текстом разметки: порядок и выравнивание
// виджетов текстом не выражаются (I32). Голос — настоящий `VoicePlayer` с
// подставным движком звука, как в `voice_player_late_source_test.dart`.
//
// ЧИСЛА — ОТ ТЕСТОВОГО ШРИФТА, НЕ ОТ ТРУБКИ. Высоты текста в `flutter test`
// считаются шрифтом FlutterTest; разница «было — стало» по устройству та же,
// что по строке значка, а абсолютные числа на телефоне будут другими.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46; сверяется ПОИМЁННО):
//   1. вернуть значок в `Row` рядом с колонкой, `crossAxisAlignment.start` —
//      «только текст…», «только голос…», «текст и голос…: значок — последней
//      строкой блока, справа» и «значок стоит одинаково при любом наборе».
//      ЧЕТЫРЕ. Четвёртое предсказано по замеру старой раскладки 17.09 ДО
//      правки: отступ значка от нижнего края 11 / 11 / 59 — у «текст и голос»
//      значок висит вверху, у двух других совпадает случайно, потому что
//      значок выше содержимого.
//   2. цель нажатия 40×40 И `tapTargetSize: shrinkWrap` —
//      «цель нажатия значка не меньше 44×44, нажатие доходит до двери». ОДИН.
//      Без `shrinkWrap` порча не портит ничего: Material сам добирает цель до
//      48 (так и замерено у починки — кнопка 48×48 при заданных 44), и зелёный
//      прогон значил бы «портить было нечего» (I56).
//   3. заводить строку значка и без двери —
//      «без двери в переписку последней строки нет». ОДИН.

class _SilentBackend implements VoiceAudioBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _state = StreamController<PlayerState>.broadcast();
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
  @override
  Stream<PlayerState> get playerStateStream => _state.stream;
  @override
  Future<void> setFilePath(String path) async {}
  @override
  Future<void> setUrl(String url) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {
    await _position.close();
    await _duration.close();
    await _state.close();
  }
}

const _text = 'Maşın xarab oldu, gələ bilmirəm';

Widget _voice() => const VoicePlayer(
      localFilePath: '/tmp/leave.m4a',
      waveform: [10, 40, 80, 40, 10],
      accentColor: Colors.amber,
      labelColor: Colors.white,
      playedColor: Colors.amber,
      dotColor: Colors.amber,
    );

class _Layout {
  _Layout(this.block, this.text, this.voice, this.button);
  final Rect block;
  final Rect? text;
  final Rect? voice;
  final Rect? button;

  double get contentBottom => [
        if (text != null) text!.bottom,
        if (voice != null) voice!.bottom,
      ].reduce((a, b) => a > b ? a : b);
}

Future<_Layout> _pump(
  WidgetTester tester, {
  required bool withText,
  required bool withVoice,
  VoidCallback? onOpenChat,
}) async {
  await tester.pumpWidget(MaterialApp(
    // Высота без предела — как на карточке, где блок стоит в колонке
    // прокручиваемого экрана. Первая редакция ставила блок прямо в тело
    // `Scaffold`, и замер дал высоту блока 600 — высоту экрана: колонка
    // растянулась по ограниченной высоте. Число, равное размеру экрана, и
    // выдало ошибку обвязки.
    home: Scaffold(
      body: SingleChildScrollView(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            child: LeaveNoteBlock(
              text: withText ? _text : '',
              voice: withVoice ? _voice() : null,
              onOpenChat: onOpenChat,
            ),
          ),
        ),
      ),
    ),
  ));
  final button = find.byType(IconButton);
  return _Layout(
    tester.getRect(find.byType(LeaveNoteBlock)),
    withText ? tester.getRect(find.text(_text)) : null,
    withVoice ? tester.getRect(find.byType(VoicePlayer)) : null,
    button.evaluate().isEmpty ? null : tester.getRect(button),
  );
}

void main() {
  setUp(() {
    voiceAudioBackendOverride = () => _SilentBackend();
    addTearDown(() => voiceAudioBackendOverride = null);
  });

  const sets = <String, (bool, bool)>{
    'только текст': (true, false),
    'только голос': (false, true),
    'текст и голос': (true, true),
  };

  for (final entry in sets.entries) {
    final (withText, withVoice) = entry.value;
    testWidgets(
        '${entry.key}: значок переписки — последней строкой блока, справа',
        (tester) async {
      final l = await _pump(tester,
          withText: withText, withVoice: withVoice, onOpenChat: () {});
      // ЗАМЕР для записи «было / стало» — печатается, решает не он.
      // ignore: avoid_print
      print('ЗАМЕР ${entry.key}: блок ${l.block.height}, '
          'значок ${l.button?.size}, содержимое до ${l.contentBottom - l.block.top}');
      expect(l.button, isNotNull, reason: 'двери в переписку нет вовсе');
      expect(l.button!.top, greaterThanOrEqualTo(l.contentBottom),
          reason: 'значок стоит в строке текста или голоса, а не под ними');
      expect(l.block.right - l.button!.right, lessThanOrEqualTo(16),
          reason: 'значок не у правого края блока');
    });
  }

  testWidgets(
      'значок стоит одинаково при любом наборе: одинаковый отступ от правого и нижнего края блока',
      (tester) async {
    final offsets = <String, Offset>{};
    for (final entry in sets.entries) {
      final (withText, withVoice) = entry.value;
      final l = await _pump(tester,
          withText: withText, withVoice: withVoice, onOpenChat: () {});
      offsets[entry.key] = Offset(
        l.block.right - l.button!.right,
        l.block.bottom - l.button!.bottom,
      );
    }
    // ignore: avoid_print
    print('ЗАМЕР отступы значка от правого и нижнего края: $offsets');
    expect(offsets.values.toSet().length, 1,
        reason: 'значок сдвигается в зависимости от того, есть ли текст и голос');
  });

  testWidgets('цель нажатия значка не меньше 44×44, нажатие доходит до двери',
      (tester) async {
    var opened = 0;
    final l = await _pump(tester,
        withText: true, withVoice: true, onOpenChat: () => opened++);
    expect(l.button!.width, greaterThanOrEqualTo(44));
    expect(l.button!.height, greaterThanOrEqualTo(44));
    // Рисунок прежний: эмодзи вкладки «MESAJ», размер 20.
    final glyph = tester.widget<Text>(find.text(kChatEmoji));
    expect(glyph.style?.fontSize, 20);
    await tester.tap(find.byType(IconButton));
    expect(opened, 1, reason: 'нажатие на значок не открывает переписку');
  });

  testWidgets('без двери в переписку последней строки нет', (tester) async {
    final l = await _pump(tester, withText: true, withVoice: true);
    expect(l.button, isNull);
    // Высота блока = содержимое + отступы 10 + 10 + рамка 1 + 1. Лишней
    // пустой строки под голосом быть не должно.
    expect(l.block.height, closeTo((l.contentBottom - l.text!.top) + 22, 0.5),
        reason: 'под содержимым осталась пустая строка без значка');
  });
}
