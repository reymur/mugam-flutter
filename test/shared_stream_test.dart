import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/store/shared_stream.dart';

void main() {
  test('на несколько подписчиков заводится ровно одна подписка', () async {
    var sourceCreated = 0;
    final source = StreamController<int>.broadcast();
    final shared = SharedStream<int>(() {
      sourceCreated++;
      return source.stream;
    });

    final a = <int>[];
    final b = <int>[];
    final subA = shared.stream.listen(a.add);
    final subB = shared.stream.listen(b.add);

    source.add(1);
    await Future<void>.delayed(Duration.zero);

    expect(sourceCreated, 1);
    expect(shared.subscriberCount, 2);
    expect(a, [1]);
    expect(b, [1]);

    await subA.cancel();
    await subB.cancel();
    await source.close();
  });

  // Ради этого свойства класс и существует: отсечка очистки подписывается
  // позже меты, и без повтора ждала бы следующей записи в документ —
  // возможно, минуты.
  test('опоздавший подписчик сразу получает последнее значение', () async {
    final source = StreamController<int>.broadcast();
    final shared = SharedStream<int>(() => source.stream);

    final first = <int>[];
    final subFirst = shared.stream.listen(first.add);
    source.add(7);
    await Future<void>.delayed(Duration.zero);

    final late = <int>[];
    final subLate = shared.stream.listen(late.add);
    await Future<void>.delayed(Duration.zero);

    expect(late, [7], reason: 'повтор последнего значения не сработал');

    source.add(8);
    await Future<void>.delayed(Duration.zero);
    expect(first, [7, 8]);
    expect(late, [7, 8]);

    await subFirst.cancel();
    await subLate.cancel();
    await source.close();
  });

  test('первый подписчик получает значение без повтора ровно один раз', () async {
    final source = StreamController<int>.broadcast();
    final shared = SharedStream<int>(() => source.stream);

    final seen = <int>[];
    final sub = shared.stream.listen(seen.add);
    source.add(1);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [1]);

    await sub.cancel();
    await source.close();
  });

  // Оставшийся снимок был бы выдан следующему подписчику за актуальный —
  // в том числе уже под другим аккаунтом на том же устройстве.
  test('после ухода последнего подписчика не остаётся ни подписки, ни значения', () async {
    var sourceCreated = 0;
    var idleCalls = 0;
    var source = StreamController<int>.broadcast();
    final shared = SharedStream<int>(() {
      sourceCreated++;
      return source.stream;
    }, onIdle: () => idleCalls++);

    final sub = shared.stream.listen((_) {});
    source.add(5);
    await Future<void>.delayed(Duration.zero);
    expect(shared.isConnected, isTrue);

    await sub.cancel();
    expect(shared.isConnected, isFalse);
    expect(idleCalls, 1);

    // Новый подписчик обязан начать с чистого листа: новая подписка на
    // источник и никакого «последнего значения» из прошлой жизни.
    await source.close();
    source = StreamController<int>.broadcast();
    final seen = <int>[];
    final sub2 = shared.stream.listen(seen.add);
    await Future<void>.delayed(Duration.zero);

    expect(sourceCreated, 2);
    expect(seen, isEmpty, reason: 'протухшее значение пережило отписку');

    await sub2.cancel();
    await source.close();
  });

  test('уход одного подписчика не рвёт поток остальным', () async {
    final source = StreamController<int>.broadcast();
    final shared = SharedStream<int>(() => source.stream);

    final staying = <int>[];
    final subStaying = shared.stream.listen(staying.add);
    final leaving = <int>[];
    final subLeaving = shared.stream.listen(leaving.add);

    source.add(1);
    await Future<void>.delayed(Duration.zero);
    await subLeaving.cancel();

    source.add(2);
    await Future<void>.delayed(Duration.zero);

    expect(staying, [1, 2]);
    expect(leaving, [1]);
    expect(shared.isConnected, isTrue);

    await subStaying.cancel();
    await source.close();
  });

  test('ошибка источника доходит до всех подписчиков', () async {
    final source = StreamController<int>.broadcast();
    final shared = SharedStream<int>(() => source.stream);

    final errorsA = <Object>[];
    final errorsB = <Object>[];
    final subA = shared.stream.listen((_) {}, onError: errorsA.add);
    final subB = shared.stream.listen((_) {}, onError: errorsB.add);

    source.addError(StateError('permission denied'));
    await Future<void>.delayed(Duration.zero);

    expect(errorsA, hasLength(1));
    expect(errorsB, hasLength(1));

    await subA.cancel();
    await subB.cancel();
    await source.close();
  });

  test('завершение источника закрывает всех подписчиков и сбрасывает состояние', () async {
    final source = StreamController<int>.broadcast();
    var idleCalls = 0;
    final shared = SharedStream<int>(
      () => source.stream,
      onIdle: () => idleCalls++,
    );

    var doneCalls = 0;
    shared.stream.listen((_) {}, onDone: () => doneCalls++);
    shared.stream.listen((_) {}, onDone: () => doneCalls++);
    await Future<void>.delayed(Duration.zero);

    await source.close();
    await Future<void>.delayed(Duration.zero);

    expect(doneCalls, 2);
    expect(shared.isConnected, isFalse);
    expect(idleCalls, 1);
  });
}
