import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/push/push_route.dart';

// КУДА ВЕДЁТ НАЖАТИЕ НА УВЕДОМЛЕНИЕ.
//
// До 26.08 это решение жило внутри обработчика в `main.dart` и не
// проверялось ничем: обработчик привязан к `FirebaseMessaging` и к живому
// роутеру, поднять его в тесте нечем (I32). Обход в тот же день нашёл там
// ТРИ расхождения с сервером, и ни одно не падало — нажатие просто не
// делало ничего.
//
// Здесь проверяются ВСЕ типы поимённо, а не выборочно: пропущенный тип
// выглядит точно так же, как разобранный, — оба молчат.

void main() {
  Map<String, dynamic> d(String type, {String? chatId, String? eventId}) => {
    'type': type,
    if (chatId != null) 'chatId': chatId,
    if (eventId != null) 'eventId': eventId,
  };

  group('переписка — шесть типов', () {
    // Имя `job_offer_waiting_for_date` СВЕРЕНО С ОТПРАВИТЕЛЕМ
    // (`functions/src/index.ts:1549`), а не взято по памяти: клиент ждал
    // `job_offer_waiting_date`, без `for`, и уведомление «ждёт от вас даты»
    // не открывало чат ни разу.
    const chatTypes = [
      'new_message',
      'job_offer_created',
      'job_offer_changed',
      'job_offer_cancelled',
      'job_offer_agreed',
      'job_offer_waiting_for_date',
    ];

    for (final t in chatTypes) {
      test('$t ведёт в свою переписку', () {
        expect(pushRouteFor(d(t, chatId: 'c-1')), '/chat/c-1');
      });
    }

    test('без chatId вести некуда, а не в общий экран', () {
      expect(pushRouteFor(d('new_message')), isNull);
    });
  });

  group('вечер — девять типов ведут в САМ вечер', () {
    const eventTypes = [
      'event_cancel_confirmed',
      'event_cancel_declined',
      'event_cancel_requested',
      'event_cancel_withdrawn',
      'event_edited',
      'event_participant_added',
      'event_participant_left',
      'event_replaced',
      'event_unsettled',
    ];

    for (final t in eventTypes) {
      test('$t ведёт в карточку вечера', () {
        expect(pushRouteFor(d(t, eventId: 'e-1')), '/event/e-1');
      });
    }

    test('без eventId вести некуда', () {
      expect(pushRouteFor(d('event_edited')), isNull);
    });
  });

  group('вечер — два типа ведут в СПИСОК, и это верный ответ', () {
    // У этих двоих карточку читать уже нельзя: удалённого вечера нет вовсе,
    // а снятому участнику документ не отдаёт `firestore.rules`. Переход в
    // карточку вернул бы отказ вместо экрана.
    //
    // Сервер различает их с самого начала (`openList` вместо `openEvent`),
    // клиент различия не читал.
    for (final t in ['event_deleted', 'event_participant_removed']) {
      test('$t ведёт в список, а НЕ в карточку', () {
        final r = pushRouteFor(d(t, eventId: 'e-1'));
        expect(r, '/agreements');
        expect(r, isNot(startsWith('/event/')),
            reason: 'тип, которому карточка запрещена, ведёт в карточку');
      });
    }
  });

  group('незнакомое молчит, а не уводит', () {
    // `null` и «/agreements» — РАЗНОЕ (I47). Первое: типа не знаем. Второе:
    // сказанный ответ. Сведи их — и незнакомый тип уводил бы человека на
    // экран, к его уведомлению отношения не имеющий.
    test('незнакомый тип', () => expect(pushRouteFor(d('нечто')), isNull));
    test('типа нет вовсе', () => expect(pushRouteFor({}), isNull));
    test('тип не строка', () => expect(pushRouteFor({'type': 7}), isNull));
    test('тип пустой', () => expect(pushRouteFor(d('')), isNull));

    // ЗВОНОК СЮДА НЕ ПОПАДАЕТ И НЕ ДОЛЖЕН: его разбирает отдельный фоновый
    // обработчик и отдаёт CallKit до того, как человек чего-либо коснётся.
    test('incoming_call не разбирается здесь', () {
      expect(pushRouteFor(d('incoming_call')), isNull);
    });
  });

  // КАНАРЕЙКИ. Без них заглушка, всегда возвращающая один ответ, прошла бы
  // большинство проверок выше.
  group('правило не сводится к одному ответу', () {
    test('ответы РАЗНЫЕ у разных типов', () {
      final answers = {
        pushRouteFor(d('new_message', chatId: 'c-1')),
        pushRouteFor(d('event_edited', eventId: 'e-1')),
        pushRouteFor(d('event_deleted', eventId: 'e-1')),
        pushRouteFor(d('нечто')),
      };
      expect(answers.length, 4,
          reason: 'правило схлопнулось: разные типы дают один ответ');
    });

    test('разбираемых типов ровно двадцать', () {
      // Число само по себе слабое, но оно ловит ОДНУ вещь, которую не ловит
      // ничто выше: молча выпавший из набора тип. Перечисления в тестах и в
      // правиле разные, и разойтись им нельзя.
      //
      // Было 17 до 30.08; три добавлены шагом 4 работы N130 —
      // `job_offer_answered`, `job_offer_accepted`, `job_offer_withdrawn`.
      expect(kKnownPushTypes.length, 20);
    });

    // СВЕРКА С ОТПРАВИТЕЛЕМ — ПОИМЁННАЯ, И ОНА ЗДЕСЬ ЕДИНСТВЕННОЕ, ЧТО
    // ВООБЩЕ СМОТРИТ ЧЕРЕЗ ГРАНИЦУ Dart↔TypeScript.
    //
    // Сторожа на неё поставить нечем: тип живёт строкой в `functions/src` и
    // строкой в этом наборе, общего у них ничего. Дефект уже случался —
    // `job_offer_waiting_date` против `job_offer_waiting_for_date`, и
    // выглядел он как «нажатие не открывает ничего».
    //
    // Здесь стоит **чтение файла отправителя**, а не память: если имя в
    // `offerMoves.ts` поменяют, покраснеет тут.
    //
    // ЧЕГО ОН НЕ ЛОВИТ: он читает ОДИН файл сервера и не увидит типа,
    // заведённого в другом; и он не проверяет обратное — что каждый наш тип
    // кто-то шлёт.
    test('три типа ходов предложения совпадают с отправителем', () {
      final src = File('functions/src/offerMoves.ts').readAsStringSync();
      for (final t in const [
        'job_offer_answered',
        'job_offer_accepted',
        'job_offer_withdrawn',
      ]) {
        expect(kKnownPushTypes.contains(t), isTrue,
            reason: '$t не разбирается клиентом');
        expect(src.contains('"$t"'), isTrue,
            reason: '$t не найден в offerMoves.ts — имена разошлись, и '
                'нажатие по уведомлению не откроет ничего');
      }
      // Канарейка: файл прочитан, а не пуст.
      expect(src.contains('openChat('), isTrue,
          reason: 'канарейка: offerMoves.ts не читается — совпадения выше '
              'означали бы «искали не там», а не «имена сошлись»');
    });

    test('каждый разбираемый тип куда-нибудь ведёт', () {
      for (final t in kKnownPushTypes) {
        final r = pushRouteFor(d(t, chatId: 'c-1', eventId: 'e-1'));
        expect(r, isNotNull, reason: '$t объявлен разбираемым, но молчит');
      }
    });
  });
}
