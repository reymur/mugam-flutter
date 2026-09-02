import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// СТОРОЖ НА ДВА МОЛЧАЛИВЫХ РИСКА ОТЛОЖЕННОГО ДЕЙСТВИЯ (N194).
//
// ЧТО ЧИНИЛОСЬ. Приложение, разбуженное VoIP-push'ем из смахнутого
// состояния, показывает окно звонка нативно, до подъёма Dart. Человек
// успевает нажать раньше, чем Dart подпишется: замер 02.09 — подписка
// появляется не позже чем через 1,32 с после push'а (серверные отметки:
// push 01:42:21.514Z, первая запись клиента 01:42:22.831Z). События CallKit
// мгновенны и не повторяются (N193), поэтому нажатие исчезало без следа.
// Теперь действие копится нативно и выдаётся Dart при подписке.
//
// РИСК ПЕРВЫЙ, И ОН ДОРОЖЕ ВТОРОГО. Подписавшись на протокол
// `CallkitIncomingAppDelegate`, мы ЗАБРАЛИ у плагина вызов
// `action.fulfill()`: он зовёт его только в ветке `else`, когда делегата
// нет. Не позвать — CallKit повиснет на действии до тайм-аута транзакции, и
// человек увидит нажатие, которое «не сработало». Ни ошибки, ни падения.
//
// РИСК ВТОРОЙ. При ЖИВОМ Dart одно нажатие приходит ДВАЖДЫ — событием на
// канал и вызовом нативного делегата. Без пометки применённого выдача
// повторила бы действие вторым заходом.
//
// ЧЕГО ЭТОТ СТОРОЖ НЕ ЛОВИТ (границы пишутся вместе со сторожем):
//   - он текстовый: подтверждает, что вызовы написаны, и молчит о том, что
//     они делают. Поведение проверяется только на трубке;
//   - он не видит, что `fulfill()` стоит на ВСЕХ путях внутри метода —
//     ранний `return` перед ним прошёл бы незамеченным;
//   - имя канала он сверяет как строку и не проверяет, что нативная сторона
//     отвечает на этот метод.
void main() {
  late String swift;
  late String swiftCode;
  late String dart;

  String codeOnly(String t) => t
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  setUpAll(() {
    final s = File('ios/Runner/AppDelegate.swift');
    final d = File('lib/core/calls/callkit_service.dart');
    expect(s.existsSync(), isTrue, reason: 'AppDelegate.swift пропал');
    expect(d.existsSync(), isTrue, reason: 'callkit_service.dart пропал');
    swift = s.readAsStringSync();
    swiftCode = codeOnly(swift);
    dart = codeOnly(d.readAsStringSync());
  });

  test('КАНАРЕЙКА: оба файла прочитаны, отсечение работает', () {
    expect(swift.length, greaterThan(3000));
    expect(dart.length, greaterThan(3000));
    expect(
      swiftCode.length,
      lessThan(swift.length),
      reason: 'комментарии не отсечены — счёт ниже будет считать разбор',
    );
    expect(
      swiftCode.length,
      greaterThan(swift.length ~/ 4),
      reason: 'отсечение съело код: осталось ${swiftCode.length} из ${swift.length}',
    );
  });

  group('риск первый: fulfill перешёл к нам вместе с протоколом', () {
    test('AppDelegate подписан на протокол плагина', () {
      // Ищется МЕСТО ОБЪЯВЛЕНИЯ, а не упоминание имени: голое имя есть в
      // файле всегда, в том числе в разборе (guards_are_guards_test).
      expect(
        RegExp(r'class AppDelegate[\s\S]{0,300}CallkitIncomingAppDelegate')
            .hasMatch(swiftCode),
        isTrue,
        reason: 'протокол снят — отложенные действия перестали накапливаться, '
            'и приём из смахнутого снова молчит',
      );
    });

    // САМЫЙ ДОРОГОЙ ВЕРДИКТ ФАЙЛА.
    test('в каждой ветви с action стоит action.fulfill()', () {
      const withAction = ['onAccept', 'onDecline', 'onEnd'];
      final missing = <String>[];
      for (final name in withAction) {
        final from = swiftCode.indexOf('func $name(');
        expect(from, greaterThan(0), reason: 'метод $name не найден');
        final open = swiftCode.indexOf('{', from);
        final close = swiftCode.indexOf('\n  }', open);
        expect(close, greaterThan(open), reason: 'тело $name не вычленяется');
        final body = swiftCode.substring(open, close);
        // Срез по именам-границам доказывает, что кусок ТОТ, и не
        // доказывает, что он целый (N104) — поэтому длина названа числом.
        expect(
          body.length,
          inInclusiveRange(10, 600),
          reason: 'тело $name длиной ${body.length} — границы уехали',
        );
        if (!body.contains('action.fulfill()')) missing.add(name);
      }
      expect(
        missing,
        isEmpty,
        reason: 'без action.fulfill() CallKit повиснет на действии: $missing. '
            'Плагин зовёт fulfill ТОЛЬКО когда делегата нет — подписавшись, '
            'мы забрали это себе',
      );
    });

    test('у onTimeOut action нет, и fulfill там не нужен', () {
      // Утверждение НАЛИЧИЯ метода: ослепни разбор — покраснеет здесь.
      expect(swiftCode.contains('func onTimeOut('), isTrue);
      expect(
        RegExp(r'func onTimeOut\([^)]*action').hasMatch(swiftCode),
        isFalse,
        reason: 'у onTimeOut появился action — значит завершать теперь нам, '
            'и вердикт выше обязан включить его в список',
      );
    });

    test('три остальных метода протокола реализованы, пусть и пусто', () {
      for (final name in [
        'didActivateAudioSession',
        'didDeactivateAudioSession',
        'providerDidReset',
      ]) {
        expect(
          swiftCode.contains('func $name('),
          isTrue,
          reason: '$name не реализован — протокол не соблюдён, сборка не '
              'соберётся, но покраснеть лучше здесь',
        );
      }
    });
  });

  group('риск второй: выдача идемпотентна', () {
    test('применённое помечается ключом «действие:callId»', () {
      expect(
        dart.contains(r"_applied.add('accept:$callId')"),
        isTrue,
        reason: 'приём по событию не помечается — выдача применит его второй '
            'раз при следующем запуске',
      );
      expect(
        dart.contains(r"_applied.add('decline:$callId')"),
        isTrue,
        reason: 'отказ по событию не помечается — то же самое',
      );
    });

    test('выдача проверяет пометку прежде, чем применить', () {
      expect(dart.contains('_applied.contains(key)'), isTrue);
      expect(
        RegExp(r"final key = '\$action:\$callId'").hasMatch(dart),
        isTrue,
        reason: 'ключ идемпотентности собирается не из действия и callId',
      );
    });

    test('у отложенного действия есть срок годности', () {
      // Без него отложенное отклонение всплыло бы через час и закрыло чужой,
      // давно законченный разговор.
      expect(
        dart.contains('age > 60'),
        isTrue,
        reason: 'срок годности снят: протухшее действие применится к живому '
            'звонку. Он выведен из длительности окна (30 с), а не назначен',
      );
    });
  });

  group('проводка выдачи', () {
    test('выдача зовётся, и СТРОГО ПОСЛЕ подписки', () {
      final main = codeOnly(File('lib/main.dart').readAsStringSync());
      final listen = main.indexOf('ensureListening(');
      final drain = main.indexOf('drainPendingNativeActions(');
      expect(listen, greaterThan(0), reason: 'подписка не зовётся вовсе');
      expect(drain, greaterThan(0), reason: 'выдача не подключена');
      expect(
        drain,
        greaterThan(listen),
        reason: 'выдача стоит ДО подписки — остаётся щель того же вида, '
            'между выдачей и подпиской',
      );
    });

    test('имя канала одно на обе стороны', () {
      // Имя канала объявлено НЕ в AppDelegate, а у владельца канала —
      // VoipPushPlugin.swift. Первая редакция вердикта искала его в
      // AppDelegate и покраснела на исправном дереве: ложная тревога, I14, и
      // поймана она тем, что вывод сверили с тем, каким он обязан быть НА
      // ИСПРАВНОМ.
      final plugin = codeOnly(File('ios/Runner/VoipPushPlugin.swift').readAsStringSync());
      expect(dart.contains("'mugam/voip_push'"), isTrue);
      expect(
        plugin.contains('"mugam/voip_push"'),
        isTrue,
        reason: 'имя канала разошлось — MethodChannel ответит '
            'MissingPluginException, и узнаем мы об этом в проде',
      );
      // Со скобками и кавычками — то есть МЕСТО, где метод объявлен и где
      // он зовётся, а не упоминание его имени.
      expect(
        plugin.contains('case "takePendingCallActions":'),
        isTrue,
        reason: 'нативная сторона не отвечает на метод выдачи',
      );
      expect(
        dart.contains("invokeMethod<List<dynamic>>('takePendingCallActions')"),
        isTrue,
        reason: 'Dart перестал спрашивать отложенные действия',
      );
    });
  });
}
