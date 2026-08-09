import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/agreement_cancel.dart';

import 'support/source_text.dart';

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

    setUpAll(() => rules = readCode('firestore.rules'));

    // ВОЗВРАТ В СИЛУ ПРОВЕРЯЕТСЯ ТЕМ ЖЕ, и отдельной строкой: имя новое,
    // а требование к нему прежнее — буквальное совпадение с правилом
    // `restoresEvent()`, иначе молчаливый отказ по правам.
    test('имя возврата в силу есть в firestore.rules', () {
      expect(rules.contains("'$kRestoredDeed'"), isTrue,
          reason: 'Клиент шлёт lastActionType «$kRestoredDeed», а в '
              'firestore.rules такого имени нет. Правило требует '
              'буквального совпадения.');
    });

    test('все четыре имени отмены есть в firestore.rules', () {
      // Все четыре, а не два: запрос и подтверждение тоже называют себя —
      // без этого сервер берёт автора уведомления из прошлого действия и
      // называет в тексте не того человека.
      final missing = kCancelDeeds.where((d) => !rules.contains("'$d'"));
      expect(missing, isEmpty,
          reason: 'Имена разошлись с правилами: клиент шлёт $missing, а в '
              'firestore.rules таких нет. Правило требует буквального '
              'совпадения, и расхождение даст отказ по правам.');
    });

    test('служба шлёт ровно эти имена и ничего иного', () {
      // Проход по исходникам: новый вызов с придуманным именем поступка
      // сюда не пролезет. Средство сильнее комментария — тот защищает
      // строку, а не класс.
      final svc = readCode('lib/firebase/firestore_service.dart');
      final names = RegExp(r"'lastActionType': '([^']+)'")
          .allMatches(svc)
          .map((m) => m.group(1))
          .toSet();
      expect(
        names,
        {'left', kRestoredDeed, ...kCancelDeeds},
        reason: 'Служба пишет lastActionType значениями $names. Каждое из '
            'них обязано быть разрешено в firestore.rules — иначе запись '
            'отвергнут по правам.',
      );
    });
  });
}
