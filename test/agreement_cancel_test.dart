import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/agreement_cancel.dart';

// Правило «какая дорога отмены открыта». Проверяется отдельно от экрана
// потому, что от него зависит не вид кнопки, а ИМЯ ПОСТУПКА: отзыв и
// отказ оставляют в данных одинаковый след, и различает их только имя. С
// неверным именем уведомление уйдёт не тому человеку, и ни одна из сторон
// об этом не узнает.

const _me = 'me';
const _other = 'other';

void main() {
  group('какая дорога открыта', () {
    test('запроса нет — можно предложить отмену', () {
      expect(
        resolveCancelStage(
          status: 'agreed',
          cancelRequestedBy: null,
          currentUid: _me,
        ),
        CancelStage.none,
      );
    });

    test('просил я — дорога одна, отозвать', () {
      expect(
        resolveCancelStage(
          status: 'agreed',
          cancelRequestedBy: _me,
          currentUid: _me,
        ),
        CancelStage.requestedByMe,
      );
    });

    test('просит второй — у меня два разных ответа', () {
      expect(
        resolveCancelStage(
          status: 'agreed',
          cancelRequestedBy: _other,
          currentUid: _me,
        ),
        CancelStage.requestedByOther,
      );
    });

    test('две стороны одного запроса видят РАЗНОЕ', () {
      // Главное свойство: один и тот же договор для запросившего и для
      // второй стороны открывает разные дороги. Совпади они — на экране
      // была бы одна кнопка на два смысла, и `lastActionType` оказался бы
      // неверным у одного из двоих.
      const requestedBy = _me;
      final mine = resolveCancelStage(
        status: 'agreed',
        cancelRequestedBy: requestedBy,
        currentUid: _me,
      );
      final theirs = resolveCancelStage(
        status: 'agreed',
        cancelRequestedBy: requestedBy,
        currentUid: _other,
      );
      expect(mine, isNot(theirs));
      expect(mine, CancelStage.requestedByMe);
      expect(theirs, CancelStage.requestedByOther);
    });
  });

  group('отменённый договор ходов больше не принимает', () {
    // `cancelRequestedBy` при подтверждении НЕ очищается, поэтому без
    // проверки статуса экран увидел бы стоящий запрос и предложил бы на
    // него ответить — при том, что правила откажут. Это та же щель, что
    // была в правилах как N36, только с другой стороны.
    test('стоящий чужой запрос после отмены ходов не открывает', () {
      expect(
        resolveCancelStage(
          status: 'cancelled',
          cancelRequestedBy: _other,
          currentUid: _me,
        ),
        CancelStage.cancelled,
      );
    });

    test('стоящий свой запрос после отмены ходов не открывает', () {
      expect(
        resolveCancelStage(
          status: 'cancelled',
          cancelRequestedBy: _me,
          currentUid: _me,
        ),
        CancelStage.cancelled,
      );
    });
  });

  group('имена поступков совпадают с правилами буквально', () {
    // Правило требует буквального совпадения строки. Разойдись клиент с
    // `firestore.rules` хоть на символ — сервер откажет по правам, и
    // отказ будет молчаливым, если его проглотить. Проверяется по самому
    // файлу правил, а не по копии константы в тесте: копия разошлась бы
    // вместе с кодом и ничего бы не поймала.
    late String rules;

    setUpAll(() => rules = File('firestore.rules').readAsStringSync());

    test('cancelWithdrawn есть в firestore.rules', () {
      expect(rules.contains("'$kCancelWithdrawn'"), isTrue,
          reason: 'Имя отзыва разошлось с правилами: клиент шлёт '
              '$kCancelWithdrawn, а в firestore.rules такого нет.');
    });

    test('cancelDeclined есть в firestore.rules', () {
      expect(rules.contains("'$kCancelDeclined'"), isTrue,
          reason: 'Имя отказа разошлось с правилами: клиент шлёт '
              '$kCancelDeclined, а в firestore.rules такого нет.');
    });

    test('служба шлёт ровно эти имена и ничего иного', () {
      // Проход по исходникам: новый вызов с придуманным именем поступка
      // сюда не пролезет. Средство сильнее комментария — тот защищает
      // строку, а не класс.
      final svc = File('lib/firebase/firestore_service.dart').readAsStringSync();
      final names = RegExp(r"'lastActionType': '([^']+)'")
          .allMatches(svc)
          .map((m) => m.group(1))
          .toSet();
      expect(
        names,
        {'left', kCancelWithdrawn, kCancelDeclined},
        reason: 'Служба пишет lastActionType значениями $names. Каждое из '
            'них обязано быть разрешено в firestore.rules — иначе запись '
            'отвергнут по правам.',
      );
    });
  });
}
