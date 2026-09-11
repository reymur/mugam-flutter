import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/core/agreements/event_status_view.dart';
import 'package:mugam_flutter/core/agreements/lineup.dart';
import 'package:mugam_flutter/core/agreements/lineup_rows.dart';
import 'package:mugam_flutter/firebase/models.dart';

// СТРОКИ «КОГО Я ПОЗВАЛ» — работа 7, шаг 5а (`docs/plan.md`), 09.09.
//
// ПРОВЕРЯЕТСЯ ГЛАВНОЕ УТВЕРЖДЕНИЕ ПРАВИЛА: ни один источник в одиночку не
// отвечает на все четыре вопроса строки, и каждый может пропасть отдельно.
// Поэтому здесь не «работает ли сборка», а четыре случая расхождения
// источников — ровно те, ради которых их два.
//
// СОБЫТИЕ СТРОИТСЯ ЧЕРЕЗ `fromFirestore`: карта ответов у модели закрыта, и
// это тот же путь, которым документ приходит в проде (I55).

void main() {
  PersonalEvent child({
    String id = 'c',
    String parent = 'p',
    String invitee = 'guest',
    String answer = kAnswerWaiting,
    String status = 'agreed',
    String? reason,
  }) =>
      PersonalEvent.fromFirestore(id, {
        'ownerUid': 'rafael',
        'parentEventId': parent,
        'date': '2026-09-11T20:00:00',
        'musicians': [invitee],
        'answers': {invitee: answer},
        'answersWrittenByOwner': true,
        'status': status,
        if (reason != null) 'unsettledReason': reason,
      });

  List<LineupRow> rowsOf({
    List<LineupSlot> lineup = const [],
    List<PersonalEvent> children = const [],
    Map<String, String> names = const {},
  }) =>
      lineupRows(
        lineup: lineup,
        children: children,
        parentEventId: 'p',
        nameOf: (uid) => names[uid],
      );

  group('три состояния, которые владелец обязан различать', () {
    test('позван и молчит — ответ waiting из ЕГО документа', () {
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        children: [child(answer: kAnswerWaiting)],
        names: const {'guest': 'Səid Oruc'},
      );
      expect(rows.single.kind, LineupRowKind.invited);
      expect(rows.single.answer, kAnswerWaiting);
    });

    test('позван и ответил — ответ доходит до строки', () {
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        children: [child(answer: kAnswerGoing)],
      );
      expect(rows.single.answer, kAnswerGoing);
      final no = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        children: [child(answer: kAnswerCant)],
      );
      expect(no.single.answer, kAnswerCant);
    });

    test('НЕ ПОЗВАН — с причиной, и причина дошла', () {
      final rows = rowsOf(
        lineup: const [
          LineupSlot(
            uid: 'guest',
            name: 'Səid',
            invited: false,
            reason: kNotInvitedOpenRound,
          )
        ],
      );
      expect(rows.single.kind, LineupRowKind.notInvited);
      expect(rows.single.reason, kNotInvitedOpenRound);
      // Ответа у него нет вовсе: вопрос не задан.
      expect(rows.single.answer, isNull);
    });
  });

  group('два состояния, которых в замысле не было', () {
    test('ПОЗВАН, А РЕБЁНКА НЕТ — приглашение снято, а не «ждём ответа»', () {
      // Прочитать это как ожидание значило бы пообещать ответ на вопрос,
      // который сняли (I47, цена уже заплачена в N13).
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
      );
      expect(rows.single.kind, LineupRowKind.withdrawn);
      expect(rows.single.answer, isNull);
      expect(rows.single.kind, isNot(LineupRowKind.invited));
    });

    test('ОТМЕНЁННЫЙ ребёнок — тоже снятое приглашение', () {
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        children: [child(status: 'cancelled', answer: kAnswerGoing)],
      );
      expect(rows.single.kind, LineupRowKind.withdrawn);
      // И согласие с отменённого документа НЕ показывается: человек сказал
      // «иду» на вечер, которого больше нет.
      expect(rows.single.answer, isNull);
    });

    test('РЕБЁНОК ЕСТЬ, А ШАБЛОНА НЕТ — показывается позванным', () {
      // Так выглядит незаписавшийся шаблон: дети созданы, `lineup` не
      // дописан. Промолчать о них значило бы соврать сильнее, чем показать
      // без порядка: приглашение у людей на руках.
      final rows = rowsOf(children: [child(invitee: 'guest')]);
      expect(rows.single.kind, LineupRowKind.invited);
      expect(rows.single.uid, 'guest');
    });
  });

  group('имя — живое первым, запасное вторым', () {
    test('живое имя старше снимка', () {
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'старое', invited: true)],
        children: [child()],
        names: const {'guest': 'Səid Oruc'},
      );
      expect(rows.single.name, 'Səid Oruc');
    });

    test('ЧЕЛОВЕК ИСЧЕЗ ИЗ СПИСКА — берётся снимок из шаблона', () {
      // Ровно то, ради чего запасное имя и заведено: шаблон переживает людей.
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        children: [child()],
      );
      expect(rows.single.name, 'Səid');
    });

    test('нет ни живого, ни снимка — пусто, а не выдуманное имя', () {
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: '', invited: true)],
        children: [child()],
      );
      expect(rows.single.name, '');
    });
  });

  group('порядок и отбор', () {
    test('ПОРЯДОК ШАБЛОНА — он же порядок отметки и приглашений', () {
      final rows = rowsOf(
        lineup: const [
          LineupSlot(uid: 'барабанщик', name: 'A', invited: true),
          LineupSlot(uid: 'гитарист', name: 'B', invited: true),
        ],
        children: [
          child(id: 'c2', invitee: 'гитарист'),
          child(id: 'c1', invitee: 'барабанщик'),
        ],
      );
      expect([for (final r in rows) r.uid], ['барабанщик', 'гитарист']);
    });

    test('ребёнок вне шаблона дописывается В КОНЕЦ', () {
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'A', invited: true)],
        children: [
          child(id: 'c1', invitee: 'guest'),
          child(id: 'c2', invitee: 'посторонний'),
        ],
      );
      expect([for (final r in rows) r.uid], ['guest', 'посторонний']);
    });

    test('ДЕТИ ЧУЖОГО РОДИТЕЛЯ НЕ ПОПАДАЮТ ВОВСЕ', () {
      final rows = rowsOf(
        children: [child(id: 'c9', parent: 'другой', invitee: 'чужой')],
      );
      expect(rows, isEmpty);
    });

    test('человек назван дважды — строка одна', () {
      final rows = rowsOf(
        lineup: const [
          LineupSlot(uid: 'guest', name: 'A', invited: true),
          LineupSlot(uid: 'guest', name: 'A', invited: false),
        ],
        children: [child()],
      );
      expect(rows.length, 1);
      expect(rows.single.kind, LineupRowKind.invited);
    });

    test('пусто и там и там — ни одной строки, и раздел не рисуется', () {
      expect(rowsOf(), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // ВОЗВРАТ РЕБЁНКА В СИЛУ НА СТРОКЕ ПОЗВАННОГО — N220, 11.09
  // -------------------------------------------------------------------------
  // ЧТО ЭТО ЗАКРЫВАЕТ. Шаг 8 обещал выход наверх («состояние без выхода —
  // скрытая отмена», решение владельца 08.09), и выхода не было НИ У КОГО:
  // приглашённый не владелец документа, а у зовущего ребёнок схлопнут под
  // родителем и в календаре не показан.
  group('возврат ребёнка в силу предлагается на строке (N220)', () {
    PersonalEvent gone(String answer) => child(
          answer: answer,
          status: kStatusUnsettled,
          reason: kReasonWorkCancelled,
        );

    test('СОГЛАСИВШЕМУСЯ — предлагается, и строка несёт чем его вернуть', () {
      final r = rowsOf(children: [gone(kAnswerGoing)]).single;
      expect(offersLineupRestore(r), isTrue);
      // Одного «предлагается» мало: без id вызывающему нечего звать, и
      // кнопка вышла бы нажимаемой в никуда (N147).
      expect(r.eventId, 'c');
      expect(r.unsettledReason, kReasonWorkCancelled);
    });

    // ТРИ СОСТОЯНИЯ, А НЕ ДВА — слова владельца 11.09: «у молчащего отказа не
    // было, вернуть его значит вернуть ВОПРОС».
    test('ОТКАЗАВШЕМУСЯ — не предлагается', () {
      expect(offersLineupRestore(rowsOf(children: [gone(kAnswerCant)]).single),
          isFalse);
    });

    test('МОЛЧАЩЕМУ — не предлагается', () {
      expect(
          offersLineupRestore(rowsOf(children: [gone(kAnswerWaiting)]).single),
          isFalse);
    });

    // КАНАРЕЙКА К ТРЁМ ОТРИЦАНИЯМ ВЫШЕ (I31): они утверждают ОТСУТСТВИЕ и
    // зазеленели бы все разом, ослепни правило до `false`. Здесь то же
    // правило говорит «да» — значит отрицания что-то да значат.
    test('КАНАРЕЙКА: правило не сводится к «никогда»', () {
      final yes = offersLineupRestore(rowsOf(children: [gone(kAnswerGoing)]).single);
      final no = offersLineupRestore(rowsOf(children: [gone(kAnswerCant)]).single);
      expect(yes && !no, isTrue,
          reason: 'правило схлопнулось: согласившийся и отказавшийся равны');
    });

    test('вечер В СИЛЕ — возврат не предлагается никому', () {
      for (final a in [kAnswerGoing, kAnswerCant, kAnswerWaiting]) {
        expect(offersLineupRestore(rowsOf(children: [child(answer: a)]).single),
            isFalse,
            reason: 'вернуть в силу предложено тому, кто и так в силе ($a)');
      }
    });

    test('ПОД ВОПРОСОМ ИЗ-ЗА УХОДА УЧАСТНИКА — тоже не предлагается', () {
      // Сужение сделано под `workCancelled`, и у соседнего повода поведение
      // обязано остаться прежним (I34). У ребёнка `memberLeft` быть не может
      // — состав из одного человека, — но правило об этом не знает, и
      // полагаться на «так не бывает» здесь нечем (I49).
      final r = rowsOf(children: [
        child(
          answer: kAnswerGoing,
          status: kStatusUnsettled,
          reason: kReasonMemberLeft,
        )
      ]).single;
      expect(offersLineupRestore(r), isFalse);
    });

    test('СНЯТОЕ и НЕПОЗВАННОЕ — полей документа нет вовсе', () {
      // У них ребёнка не существует, и `eventId` обязан быть пуст: иначе
      // кнопка позвала бы возврат на чужом или несуществующем документе.
      final withdrawn = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'G', invited: true)],
      ).single;
      expect(withdrawn.kind, LineupRowKind.withdrawn);
      expect(withdrawn.eventId, isNull);
      expect(offersLineupRestore(withdrawn), isFalse);

      final notInvited = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'G', invited: false)],
      ).single;
      expect(notInvited.eventId, isNull);
      expect(offersLineupRestore(notInvited), isFalse);
    });
  });
}
