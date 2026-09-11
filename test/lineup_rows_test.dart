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
  // ЗДЕСЬ БЫЛА ГРУППА «возврат ребёнка в силу предлагается на строке (N220)» —
  // семь вердиктов на плитку «Qaytar». Снята 12.09 вместе с самой плиткой:
  // возврата по одному человеку больше нет, под вопрос ставит хозяин вечера и
  // снимает вопрос он же, сразу со всего вечера.
  //
  // На её место встало правило «кому передаётся выбранное состояние». Оно
  // отвечает на тот же вопрос, что плитка, только не по одному человеку: один
  // ход владельца ложится на родителя и на ВСЕ его приглашения разом.
  group('кому передаётся выбор владельца (12.09)', () {
    PersonalEvent parentDoc() => PersonalEvent.fromFirestore('p', {
          'ownerUid': 'rafael',
          'date': '2026-09-11T20:00:00',
          'musicians': const <String>[],
          'status': 'agreed',
        });

    test('все приглашения этого вечера — поимённо, а не числом', () {
      final ids = invitationsFollowing('p', [
        child(id: 'c1', invitee: 'a'),
        child(id: 'c2', invitee: 'b'),
      ]);
      expect(ids, ['c1', 'c2']);
    });

    test('ОТМЕНЁННОЕ приглашение не трогается', () {
      // Снятое приглашение возвращать нечем и незачем: вопрос человеку сняли,
      // и заново он задаётся обычным приглашением, а не сменой состояния.
      final ids = invitationsFollowing('p', [
        child(id: 'c1'),
        child(id: 'c2', status: kStatusCancelled),
      ]);
      expect(ids, ['c1']);
    });

    test('ЧУЖИЕ ПРИГЛАШЕНИЯ И САМ РОДИТЕЛЬ не попадают', () {
      // Родитель пишется отдельно, первым id: попади он сюда вторым разом,
      // одна и та же запись ушла бы в пакет дважды.
      final ids = invitationsFollowing('p', [
        child(id: 'c1'),
        child(id: 'other', parent: 'p2'),
        parentDoc(),
      ]);
      expect(ids, ['c1']);
    });

    // КАНАРЕЙКА (I31): три вердикта выше утверждают ОТСУТСТВИЕ лишнего и
    // зазеленели бы разом, ослепни правило до пустого списка.
    test('КАНАРЕЙКА: правило вообще что-то находит', () {
      expect(invitationsFollowing('p', [child(id: 'c1')]), isNotEmpty);
    });
  });
}
