import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/core/agreements/event_status_view.dart';
import 'package:mugam_flutter/core/agreements/lineup.dart';
import 'package:mugam_flutter/core/agreements/lineup_rows.dart';
import 'package:mugam_flutter/firebase/models.dart';

// СТРОКИ «КОГО Я ПОЗВАЛ» — работа 7, шаг 5а (`docs/plan.md`), 09.09.
// ПЕРЕПИСАНЫ 17.09: приглашение живёт в составе вечера (закон о договоре).
//
// ЧТО ПРОВЕРЯЕТСЯ ТЕПЕРЬ. Прежде правило собирало строку из ДВУХ источников —
// шаблона и детей-приглашений, — и вердикты были про их расхождение. Источник
// один: сам вечер. Осталось различение, ради которого правило и существует, —
// **три состояния человека в шаблоне**: позван, не позван с причиной, позван и
// снят. Свести любые два значило бы пообещать ответ там, где вопроса нет (I47).
//
// СОБЫТИЕ СТРОИТСЯ ЧЕРЕЗ `fromFirestore`: карта ответов у модели закрыта, и
// это тот же путь, которым документ приходит в проде (I55).

void main() {
  PersonalEvent event({
    String id = 'p',
    List<String> musicians = const [],
    Map<String, String> answers = const {},
    String status = 'agreed',
  }) =>
      PersonalEvent.fromFirestore(id, {
        'ownerUid': 'rafael',
        'date': '2026-09-11T20:00:00',
        'musicians': musicians,
        'answers': answers,
        'answersWrittenByOwner': true,
        'status': status,
      });

  List<LineupRow> rowsOf({
    List<LineupSlot> lineup = const [],
    List<String> musicians = const [],
    Map<String, String> answers = const {},
    String status = 'agreed',
    Map<String, String> names = const {},
  }) =>
      lineupRows(
        lineup: lineup,
        event: event(musicians: musicians, answers: answers, status: status),
        nameOf: (uid) => names[uid],
      );

  group('три состояния, которые владелец обязан различать', () {
    test('позван и молчит — ответ waiting из состава вечера', () {
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        musicians: const ['guest'],
        answers: const {'guest': kAnswerWaiting},
        names: const {'guest': 'Səid Oruc'},
      );
      expect(rows.single.kind, LineupRowKind.invited);
      expect(rows.single.answer, kAnswerWaiting);
    });

    test('позван и ответил — ответ доходит до строки', () {
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        musicians: const ['guest'],
        answers: const {'guest': kAnswerGoing},
      );
      expect(rows.single.answer, kAnswerGoing);
      final no = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        musicians: const ['guest'],
        answers: const {'guest': kAnswerCant},
      );
      expect(no.single.answer, kAnswerCant);
    });

    test('ВЫШЕДШИЙ ОСТАЁТСЯ ПОЗВАННЫМ, и ответ его виден', () {
      // Он в составе — значит вопрос ему задавали и он на него ответил, пусть
      // и самым сильным «нет». Прочитать это как «приглашение сняли» значило
      // бы стереть его ход и приписать его владельцу.
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        musicians: const ['guest'],
        answers: const {'guest': kAnswerLeft},
      );
      expect(rows.single.kind, LineupRowKind.invited);
      expect(rows.single.answer, kAnswerLeft);
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

    test('ПОЗВАН, А В СОСТАВЕ НЕТ — приглашение снято, а не «ждём ответа»', () {
      // Прочитать это как ожидание значило бы пообещать ответ на вопрос,
      // который сняли (I47, цена уже заплачена в N13). Прежде тем же ответом
      // было отсутствие документа-ребёнка; теперь — отсутствие в составе, и
      // это единственный способ снять приглашение.
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
      );
      expect(rows.single.kind, LineupRowKind.withdrawn);
      expect(rows.single.answer, isNull);
      expect(rows.single.kind, isNot(LineupRowKind.invited));
    });
  });

  group('отменённый вечер — приглашения не снимаются', () {
    test('ПОЗВАННЫЙ ОСТАЁТСЯ ПОЗВАННЫМ, и ответ его виден', () {
      // ЗДЕСЬ БЫЛО ОБРАТНОЕ, И СМЕНА НАМЕРЕННАЯ. Прежде отменённый РЕБЁНОК
      // читался как снятое приглашение — потому что отменить его можно было
      // по одному человеку. Отмены по одному человеку нет с 12.09: отменён
      // вечер целиком, и состояние его сказано строкой выше, над этим списком.
      // Прочитать состав отменённого вечера как «всех сняли» значило бы
      // сказать про каждого то, чего владелец не делал.
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        musicians: const ['guest'],
        answers: const {'guest': kAnswerGoing},
        status: kStatusCancelled,
      );
      expect(rows.single.kind, LineupRowKind.invited);
      expect(rows.single.answer, kAnswerGoing);
    });
  });

  group('имя — живое первым, запасное вторым', () {
    test('живое имя старше снимка', () {
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'старое', invited: true)],
        musicians: const ['guest'],
        answers: const {'guest': kAnswerWaiting},
        names: const {'guest': 'Səid Oruc'},
      );
      expect(rows.single.name, 'Səid Oruc');
    });

    test('ЧЕЛОВЕК ИСЧЕЗ ИЗ СПИСКА — берётся снимок из шаблона', () {
      // Ровно то, ради чего запасное имя и заведено: шаблон переживает людей.
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'Səid', invited: true)],
        musicians: const ['guest'],
        answers: const {'guest': kAnswerWaiting},
      );
      expect(rows.single.name, 'Səid');
    });

    test('нет ни живого, ни снимка — пусто, а не выдуманное имя', () {
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: '', invited: true)],
        musicians: const ['guest'],
        answers: const {'guest': kAnswerWaiting},
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
        // Состав нарочно в ОБРАТНОМ порядке: строки берут порядок у шаблона,
        // а не у `musicians`.
        musicians: const ['гитарист', 'барабанщик'],
        answers: const {
          'гитарист': kAnswerGoing,
          'барабанщик': kAnswerWaiting,
        },
      );
      expect([for (final r in rows) r.uid], ['барабанщик', 'гитарист']);
    });

    test('В СОСТАВЕ, НО НЕ В ШАБЛОНЕ — В ЭТОТ СПИСОК НЕ ПОПАДАЕТ', () {
      // Так выглядит человек, вписанный руками через «+ Əlavə et». Раздел
      // отвечает на вопрос «кого Я ПОЗВАЛ», а состав вечера показан выше своим
      // списком; попади он сюда — стоял бы на экране дважды. Прежде того же
      // добивалось устройство: у вписанного руками не заводилось ребёнка.
      final rows = rowsOf(
        lineup: const [LineupSlot(uid: 'guest', name: 'A', invited: true)],
        musicians: const ['guest', 'вписанный'],
        answers: const {'guest': kAnswerWaiting, 'вписанный': kAnswerGoing},
      );
      expect([for (final r in rows) r.uid], ['guest']);
    });

    test('ЧУЖОЙ ВЕЧЕР СЮДА НЕ ПОПАДАЕТ ВОВСЕ', () {
      // Прежде это значило «дети чужого родителя»; теперь правило чужих
      // документов не читает вообще — спрашивать нечего.
      final rows = rowsOf(musicians: const ['чужой']);
      expect(rows, isEmpty);
    });

    test('человек назван дважды — строка одна', () {
      final rows = rowsOf(
        lineup: const [
          LineupSlot(uid: 'guest', name: 'A', invited: true),
          LineupSlot(uid: 'guest', name: 'A', invited: false),
        ],
        musicians: const ['guest'],
        answers: const {'guest': kAnswerWaiting},
      );
      expect(rows.length, 1);
      expect(rows.single.kind, LineupRowKind.invited);
    });

    test('шаблона нет — ни одной строки, и раздел не рисуется', () {
      expect(rowsOf(), isEmpty);
      // И состав без шаблона раздела не рисует тоже: он про зов, а не про
      // состав.
      expect(rowsOf(musicians: const ['кто-то']), isEmpty);
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
  // ГРУППА ЖИВЁТ ДО СВОЕГО ШАГА И НАЗНАЧЕНА К СНЯТИЮ ВМЕСТЕ С ПРАВИЛОМ.
  // `invitationsFollowing` рассылает выбор владельца по документам-приглашениям;
  // их больше не создают (17.09), но девять штук остаются в проде до общего
  // стирания, и правило обязано с ними работать. Снимается шагом «рассылка
  // состояния» — вместе с параметром `alsoIds` у `setEventStatus`.
  //
  // ПОСТРОИТЕЛЬ РЕБЁНКА ЖИВЁТ ЗДЕСЬ, А НЕ НАВЕРХУ, И ЭТО НЕ ПЕРЕЕЗД РАДИ
  // ОПРЯТНОСТИ: наверху он был общим, и его общность была ровно тем, что
  // связывало строки состава с чужими документами. Строкам он больше не нужен
  // вовсе, а здесь нужен — значит и стоять ему здесь, и уйти отсюда вместе с
  // группой.
  group('кому передаётся выбор владельца (12.09)', () {
    PersonalEvent child({
      String id = 'c',
      String parent = 'p',
      String invitee = 'guest',
      String status = 'agreed',
    }) =>
        PersonalEvent.fromFirestore(id, {
          'ownerUid': 'rafael',
          'parentEventId': parent,
          'date': '2026-09-11T20:00:00',
          'musicians': [invitee],
          'status': status,
        });

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
