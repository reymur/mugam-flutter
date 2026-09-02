import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// СТОРОЖ НА ПРОВОДКУ ЗВОНКА ЧЕРЕЗ PushKit — Dart-сторона моста.
//
// ЗАЧЕМ ОН ВООБЩЕ НУЖЕН, ЕСЛИ ОКНО ПОКАЗЫВАЕТ НАТИВНЫЙ КОД. Именно поэтому и
// нужен. Путь PushKit устроен так, что ВИДИМАЯ часть работает без Dart
// вовсе: нативная сторона отчитывается в CallKit, и окно входящего звонка
// появляется. Всё, что делает Dart, — берёт звонок НА УЧЁТ. Пропади этот
// учёт, и поломка будет выглядеть так:
//
//   - окно показалось, человек нажал «принять» — и приняли;
//   - звонящий отменил вызов — а у вызываемого окно продолжает звонить,
//     потому что следить за отменой некому;
//   - разговор пошёл — а `reportConnected` не нашёл CallKit-идентификатор.
//
// Ни одна из трёх не читается как «push не работает»: push как раз работает.
// Поэтому проверка стоит здесь, а не выводится из того, что звонок пришёл.
//
// ЧЕГО ЭТОТ СТОРОЖ НЕ ЛОВИТ (границы пишутся вместе со сторожем):
//   - он текстовый и смотрит на ИСХОДНИК, а не на поведение. Он подтверждает,
//     что вызов написан, и молчит о том, что он делает;
//   - он ничего не говорит о нативной стороне — она сторожится из
//     functions/test/voip-push.test.ts, где лежит разбор AppDelegate.swift;
//   - срез тела `showIncoming` идёт по именам-границам: он доказывает, что
//     кусок ТОТ, и не доказывает, что он целый (N104). Поэтому рядом стоит
//     вердикт на длину среза.
void main() {
  late String callkit;

  setUpAll(() {
    final f = File('lib/core/calls/callkit_service.dart');
    expect(f.existsSync(), isTrue, reason: 'callkit_service.dart пропал');
    callkit = f.readAsStringSync();
  });

  test('КАНАРЕЙКА: разбор видит заведомо существующее', () {
    // Счёт вхождений с названным числом (I13), а не «да/нет» по голому имени.
    final mentions = 'CallEvent'.allMatches(callkit).length;
    expect(
      mentions,
      greaterThanOrEqualTo(5),
      reason: 'разбор нашёл $mentions упоминаний — он слеп, а не «связи нет»',
    );
    expect(callkit.length, greaterThan(5000));
  });

  test('событие входящего звонка обрабатывается, а не падает в default', () {
    // Без этого случая путь PushKit наполовину мёртв, и мёртв молча.
    expect(
      callkit.contains('case CallEventActionCallIncoming('),
      isTrue,
      reason: 'мост с пути PushKit снят: событие входящего звонка не '
          'обрабатывается, звонок не берётся на учёт',
    );
  });

  test('учёт звонка — ОДНА функция, и её зовут ОБА пути', () {
    // Сведено по задаче (I58): учёт у пути FCM и у пути PushKit буквально
    // один и тот же, и второе его написание разошлось бы с первым при
    // первой же правке.
    final calls = '_attachCall('.allMatches(callkit).length;
    expect(
      calls,
      greaterThanOrEqualTo(3),
      reason: 'вызовов _attachCall $calls: ожидается объявление и два вызова '
          '— из showIncoming (путь FCM) и из события (путь PushKit)',
    );
  });

  group('срез тела showIncoming', () {
    late String body;

    setUpAll(() {
      final from = callkit.indexOf('Future<void> showIncoming(');
      expect(from, greaterThan(0), reason: 'showIncoming не найдена');
      final to = callkit.indexOf('Future<void> reportOutgoingStarted(', from);
      expect(to, greaterThan(from), reason: 'конец showIncoming не найден');
      body = callkit.substring(from, to);
    });

    test('КАНАРЕЙКА: срез не пуст и не съел половину файла', () {
      expect(
        body.length,
        greaterThan(300),
        reason: 'срез длиной ${body.length} — границы уехали',
      );
      expect(body.length, lessThan(4000));
    });

    test('путь FCM берёт звонок на учёт той же функцией', () {
      expect(
        body.contains('_attachCall('),
        isTrue,
        reason: 'showIncoming перестала звать общий учёт — пути разошлись',
      );
    });

    test('показ окна остался только у пути FCM', () {
      // Разделено по задаче: общее у двух путей — учёт, разное — кто
      // показывает окно. Появись показ и на стороне события — это была бы
      // склейка двух дел и второе окно на один звонок.
      expect(body.contains('showCallkitIncoming('), isTrue);
      final incomingCase = callkit.substring(
        callkit.indexOf('case CallEventActionCallIncoming('),
        callkit.indexOf('case CallEventActionCallAccept('),
      );
      expect(
        incomingCase.contains('showCallkitIncoming('),
        isFalse,
        reason: 'обработчик события сам показывает окно — на пути PushKit это '
            'второе окно поверх уже показанного нативной стороной',
      );
      expect(
        incomingCase.contains('_attachCall('),
        isTrue,
        reason: 'обработчик события не берёт звонок на учёт',
      );
    });
  });
}
