import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mugam_flutter/shared/widgets/voice_player.dart';

// ИСТОЧНИК, ПРИШЕДШИЙ ПОСЛЕ ПЕРВОГО КАДРА (N235).
//
// Поломка, замеренная владельцем на трубке 15.09: у причины выхода первое
// раскрытие «?» не играет даже после трёх секунд ожидания, второе играет.
// Причина не в скорости нажатия, а в устройстве: `localFilePath` приходит
// БУДУЩИМ, к первому кадру его нет, а принять пришедшее позже было нечем —
// `didUpdateWidget` у `VoicePlayer` отсутствовал.
//
// ЭТОТ НАБОР ПИСАЛСЯ ДО ПРАВКИ И ОБЯЗАН БЫЛ УПАСТЬ НА НЕЙ — иначе он
// проверяет не причину, а собственное представление о ней (I9).
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46):
//   • снять `didUpdateWidget` целиком — «поздний путь доезжает до плеера» и
//     «поздняя ссылка доезжает до плеера», два теста;
//   • расширить условие до «менять источник при ЛЮБОЙ смене» — «смена
//     источника на живом плеере не трогает уже поставленный», один тест, и
//     он же стоит сторожем чата;
//   • оставить условие, но забыть `setState`/повторную постановку — падёт
//     первый же тест.
//
// ЧЕГО НЕ ЛОВИТ: настоящий звук. Подставной плеер записывает вызовы, а не
// воспроизводит — на трубке это проверяется человеком.

class _FakeBackend implements VoiceAudioBackend {
  final List<String> calls = [];
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
  Future<void> setFilePath(String path) async => calls.add('setFilePath:$path');
  @override
  Future<void> setUrl(String url) async => calls.add('setUrl:$url');
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(Duration position) async => calls.add('seek');
  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _position.close();
    await _duration.close();
    await _state.close();
  }
}

void main() {
  late _FakeBackend fake;

  setUp(() {
    fake = _FakeBackend();
    voiceAudioBackendOverride = () => fake;
    addTearDown(() => voiceAudioBackendOverride = null);
  });

  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  VoicePlayer player({String? localFilePath, String? audioURL}) => VoicePlayer(
    localFilePath: localFilePath,
    audioURL: audioURL,
    waveform: const [10, 20, 30],
    accentColor: Colors.amber,
    labelColor: Colors.white,
    playedColor: Colors.amber,
    dotColor: Colors.amber,
  );

  testWidgets('к первому кадру источника нет — плееру ничего не ставят', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(player()));
    // Канарейка к пустому списку: подставной подключён и виджет построился.
    expect(find.byType(VoicePlayer), findsOneWidget);
    expect(fake.calls, isEmpty);
  });

  testWidgets('поздний ПУТЬ доезжает до плеера', (tester) async {
    await tester.pumpWidget(wrap(player()));
    expect(fake.calls, isEmpty);

    // Ровно то, что делает причина выхода: файл приехал, виджет перестроился
    // с тем же местом в дереве — значит `initState` больше не позовут.
    await tester.pumpWidget(wrap(player(localFilePath: '/tmp/late.m4a')));
    await tester.pump();

    expect(fake.calls, ['setFilePath:/tmp/late.m4a']);
  });

  testWidgets('поздняя ССЫЛКА доезжает до плеера', (tester) async {
    await tester.pumpWidget(wrap(player()));
    await tester.pumpWidget(wrap(player(audioURL: 'https://x/late.m4a')));
    await tester.pump();

    expect(fake.calls, ['setUrl:https://x/late.m4a']);
  });

  // СТОРОЖ НА УЗОСТЬ УСЛОВИЯ — он же сторож ЧАТА.
  //
  // В чате источник МЕНЯЕТСЯ на живом плеере: своё голосовое играет с
  // `localFilePath`, после подтверждения сообщение переходит на `audioURL`, а
  // файл с диска удаляется. Проба владельца 15.09 показала, что сейчас оно
  // играет сквозь этот переход — потому что файл уже загружен в плеер.
  //
  // Расширь условие до «менять при любой смене» — и переход сменит источник
  // ПОСРЕДИ воспроизведения, сломав работающее. Этот тест краснеет первым.
  testWidgets('смена источника на живом плеере не трогает уже поставленный', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(player(localFilePath: '/tmp/pending.m4a')));
    expect(fake.calls, ['setFilePath:/tmp/pending.m4a']);

    // Подтверждение сообщения: путь исчез, вместо него ссылка.
    await tester.pumpWidget(wrap(player(audioURL: 'https://x/confirmed.m4a')));
    await tester.pump();

    expect(
      fake.calls,
      ['setFilePath:/tmp/pending.m4a'],
      reason: 'Источник переставлен на живом плеере. В чате это оборвёт '
          'воспроизведение своего голосового в момент подтверждения — '
          'случай, который сейчас РАБОТАЕТ (проба владельца 15.09).',
    );
  });

  testWidgets('источник, поставленный к первому кадру, ставится один раз', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(player(audioURL: 'https://x/a.m4a')));
    expect(fake.calls, ['setUrl:https://x/a.m4a']);

    // Перестройка без смены источника — повторной постановки быть не должно.
    await tester.pumpWidget(wrap(player(audioURL: 'https://x/a.m4a')));
    await tester.pump();

    expect(fake.calls, ['setUrl:https://x/a.m4a']);
  });
}
