import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/day_role.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/core/agreements/lineup.dart';
import 'package:mugam_flutter/core/agreements/lineup_children.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ПРИГЛАШЕНИЯ СВОИХ — работа 7, шаг 5 (`docs/plan.md`), 09.09.
//
// ТРИ ПРЕДМЕТА, И ОНИ РАЗНЫЕ:
//   1. разбор шаблона состава (`lineupFromFirestore`) — что читается из
//      документа и что выбрасывается;
//   2. схлопывание детей у зовущего (`collapsesUnderParent`) — то, без чего
//      шаг 5 ставит зовущему четыре строки на одном вечере;
//   3. сторож двойного нажатия (`invitedUidsUnder`) — то, без чего повторное
//      нажатие создаёт двойников, а они НЕОБРАТИМЫ В ДАННЫХ.
//
// СОБЫТИЕ СТРОИТСЯ ЧЕРЕЗ `fromFirestore`, А НЕ КОНСТРУКТОРОМ — тот же довод,
// что в `day_role_test.dart`: это путь, которым документ приходит в проде, и
// портить надо его, а не ближайшую удобную точку входа (I55).

void main() {
  PersonalEvent make({
    String id = 'e',
    String owner = 'owner',
    String? parent,
    List<String> musicians = const [],
    Object? lineup,
    String status = 'agreed',
  }) =>
      PersonalEvent.fromFirestore(id, {
        'ownerUid': owner,
        'date': '2026-09-11T20:00:00',
        'musicians': musicians,
        'status': status,
        if (parent != null) 'parentEventId': parent,
        if (lineup != null) 'lineup': lineup,
      });

  group('шаблон состава — разбор документа', () {
    test('обычная запись читается целиком: uid, имя, признак, причина', () {
      final e = make(lineup: const [
        {'uid': 'u1', 'name': 'Səid', 'invited': true, 'reason': null},
        {
          'uid': 'u2',
          'name': 'Ənvər',
          'invited': false,
          'reason': kNotInvitedOpenRound,
        },
      ]);
      expect(e.lineup.length, 2);
      expect(e.lineup[0].uid, 'u1');
      expect(e.lineup[0].name, 'Səid');
      expect(e.lineup[0].invited, isTrue);
      expect(e.lineup[0].reason, isNull);
      expect(e.lineup[1].invited, isFalse);
      expect(e.lineup[1].reason, kNotInvitedOpenRound);
    });

    test('ПОРЯДОК ОТМЕТКИ СОХРАНЯЕТСЯ — это порядок приглашений', () {
      final e = make(lineup: const [
        {'uid': 'барабанщик', 'name': 'A', 'invited': true},
        {'uid': 'гитарист', 'name': 'B', 'invited': true},
      ]);
      expect([for (final s in e.lineup) s.uid], ['барабанщик', 'гитарист']);
    });

    test('ЗАПИСЬ БЕЗ uid ВЫБРАСЫВАЕТСЯ ЦЕЛИКОМ, а не читается пустой', () {
      // Слот без человека — мусор, а не «человек без имени»: по нему нечего
      // читать и некому звонить, а в показе он стал бы пустой строкой,
      // которую примут за потерянного участника.
      final e = make(lineup: const [
        {'name': 'без uid', 'invited': true},
        {'uid': '', 'name': 'пустой uid', 'invited': true},
        {'uid': 'u1', 'name': 'настоящий', 'invited': true},
      ]);
      expect(e.lineup.length, 1);
      expect(e.lineup.single.uid, 'u1');
    });

    test('ВСЁ, ЧТО НЕ true, ЧИТАЕТСЯ КАК «НЕ ПОЗВАН» — сторона выбрана', () {
      // Ошибись умолчание в другую сторону, и непозванный молча стал бы
      // позванным: человек ждал бы ответа, которого никто не обещал.
      final e = make(lineup: const [
        {'uid': 'u1', 'name': 'нет ключа'},
        {'uid': 'u2', 'name': 'чужой тип', 'invited': 'true'},
        {'uid': 'u3', 'name': 'null', 'invited': null},
      ]);
      expect([for (final s in e.lineup) s.invited], [false, false, false]);
    });

    test('ЧУЖОЙ ТИП ПОЛЯ НЕ РОНЯЕТ РАЗБОР — падение здесь роняет календарь', () {
      // Документ вечера пишет не только наш клиент (I49): сервер ходит мимо
      // правил, плюс правка руками в консоли. `fromFirestore` зовётся на
      // каждый документ каждого потока.
      expect(make(lineup: 'не список').lineup, isEmpty);
      expect(make(lineup: const {'uid': 'u1'}).lineup, isEmpty);
      expect(make(lineup: const [42, 'строка', null]).lineup, isEmpty);
      expect(
        make(lineup: const [
          {'uid': 'u1', 'name': 7, 'reason': 9}
        ]).lineup.single.name,
        '',
      );
    });

    test('поля нет вовсе — пустой список, а не отказ', () {
      expect(make().lineup, isEmpty);
    });

    test('записанное читается обратно тем же (туда и назад)', () {
      const slots = [
        LineupSlot(uid: 'u1', name: 'Səid', invited: true),
        LineupSlot(
          uid: 'u2',
          name: 'Ənvər',
          invited: false,
          reason: kNotInvitedFailed,
        ),
      ];
      final back = lineupFromFirestore(lineupToFirestore(slots));
      expect(back.length, 2);
      expect(back[1].uid, 'u2');
      expect(back[1].invited, isFalse);
      expect(back[1].reason, kNotInvitedFailed);
    });
  });

  group('схлопывание — у зовущего вечер ОДНОЙ строкой', () {
    // Без этого правила шаг 5 ломает экран в первую же минуту: владелец
    // ребёнка — ЗОВУЩИЙ (иначе `allow create` не пустит), значит дети
    // приходят ему тем же запросом, что и свои вечера. Позвал троих — четыре
    // строки на 20:00.
    final parent = make(id: 'p', owner: 'rafael');
    final child =
        make(id: 'c', owner: 'rafael', parent: 'p', musicians: const ['teymur']);

    test('ребёнок зовущему НЕ показывается', () {
      expect(collapsesUnderParent(child, 'rafael'), isTrue);
      expect(showsInCalendarOf(child, 'rafael'), isFalse);
    });

    test('РОДИТЕЛЬ ПОКАЗЫВАЕТСЯ — прячется ребёнок, а не вечер', () {
      expect(collapsesUnderParent(parent, 'rafael'), isFalse);
      expect(showsInCalendarOf(parent, 'rafael'), isTrue);
    });

    test('ПРИГЛАШЁННОМУ ребёнок виден — это его работа', () {
      expect(collapsesUnderParent(child, 'teymur'), isFalse);
      expect(showsInCalendarOf(child, 'teymur'), isTrue);
    });

    test('ЗАНЯТОСТЬ ЗОВУЩЕГО НЕ СНИМАЕТСЯ — прячем показ, а не день', () {
      // Ответь `dayRoleOf` «свободен», и предупреждение о конфликте на этот
      // час замолчало бы. Здесь решается только «показывать ли».
      expect(dayRoleOf(child, 'rafael'), DayRole.occupied);
    });

    test('чужой ребёнок постороннему не прячется этим правилом', () {
      expect(collapsesUnderParent(child, 'кто-то третий'), isFalse);
    });

    test('ПУСТОЙ uid НЕ ПРЯЧЕТ НИЧЕГО — пустой экран читался бы как успех', () {
      expect(collapsesUnderParent(child, ''), isFalse);
      expect(showsInCalendarOf(child, ''), isTrue);
    });
  });

  group('сторож двойного нажатия — двойники необратимы', () {
    final mine = [
      make(id: 'p', owner: 'rafael'),
      make(id: 'c1', owner: 'rafael', parent: 'p', musicians: const ['teymur']),
      make(id: 'c2', owner: 'rafael', parent: 'p', musicians: const ['said']),
      // Ребёнок ДРУГОГО вечера — в счёт этого не входит.
      make(id: 'c3', owner: 'rafael', parent: 'other', musicians: const ['enver']),
      // Обычный вечер без родителя.
      make(id: 'own', owner: 'rafael', musicians: const ['enver']),
    ];

    test('позванные под этим вечером названы поимённо', () {
      expect(invitedUidsUnder(mine, 'p'), {'teymur', 'said'});
    });

    test('дети ЧУЖОГО родителя сюда не попадают', () {
      expect(invitedUidsUnder(mine, 'p'), isNot(contains('enver')));
      expect(invitedUidsUnder(mine, 'other'), {'enver'});
    });

    test('у вечера без приглашений — пусто, и это ответ, а не молчание', () {
      expect(invitedUidsUnder(mine, 'никого'), isEmpty);
    });

    test('ОТМЕНЁННОЕ ПРИГЛАШЕНИЕ СЧИТАЕТСЯ ПОЗВАННЫМ, и это решение', () {
      // «Звали и отменили» — не то же самое, что «не звали». Создать поверх
      // отменённого второе значило бы позвать человека, у которого отмена
      // этого же вечера уже лежит в календаре.
      final withCancelled = [
        make(
          id: 'c4',
          owner: 'rafael',
          parent: 'p',
          musicians: const ['murad'],
          status: 'cancelled',
        ),
      ];
      expect(invitedUidsUnder(withCancelled, 'p'), {'murad'});
    });
  });

  group('ответ приглашённого — дорога та же, что у обычного состава', () {
    test('созданный ребёнок читается приглашённому как ПРИГЛАШЕНИЕ', () {
      // Форма, которую пишет `createLineupInvitation`: состав — один
      // приглашённый, карта заполнена владельцем, ответ `waiting`.
      final child = PersonalEvent.fromFirestore('c', {
        'ownerUid': 'rafael',
        'parentEventId': 'p',
        'date': '2026-09-11T20:00:00',
        'musicians': const ['teymur'],
        'answers': const {'teymur': kAnswerWaiting},
        'answersWrittenByOwner': true,
      });
      expect(dayRoleOf(child, 'teymur'), DayRole.invited);
      expect(showsAsInvitation(child, 'teymur'), isTrue);
      // День приглашённого НЕ занят, пока он не ответил (N126).
      expect(dayRoleOf(child, 'teymur'), isNot(DayRole.occupied));
    });

    test('ЗОВУЩЕГО В СОСТАВЕ НЕТ — он не ждёт ответа на своём вечере', () {
      // N112: попади владелец в `musicians`, карта объявила бы его ждущим.
      final child = PersonalEvent.fromFirestore('c', {
        'ownerUid': 'rafael',
        'parentEventId': 'p',
        'date': '2026-09-11T20:00:00',
        'musicians': const ['teymur'],
        'answers': const {'teymur': kAnswerWaiting},
        'answersWrittenByOwner': true,
      });
      expect(child.participantUids, ['teymur']);
      expect(dayRoleOf(child, 'rafael'), DayRole.occupied);
    });

    test('НЕ СПРОШЕННЫЙ ОТЛИЧИМ ОТ ЖДУЩЕГО — карта писана владельцем', () {
      final child = PersonalEvent.fromFirestore('c', {
        'ownerUid': 'rafael',
        'parentEventId': 'p',
        'date': '2026-09-11T20:00:00',
        'musicians': const ['teymur'],
        'answers': const {'teymur': kAnswerWaiting},
        'answersWrittenByOwner': true,
      });
      expect(child.answerFor('посторонний'), isNull);
      expect(child.answerFor('teymur'), kAnswerWaiting);
    });
  });
}
