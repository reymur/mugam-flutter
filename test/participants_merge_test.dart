import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/firebase/models.dart';
import 'package:mugam_flutter/shared/widgets/event_conflict_banner.dart';

// Перенос участников при замене мероприятия.
//
// Теста на это правило НЕ БЫЛО, и дефект нашёлся глазами на устройстве
// 04.08: при правке существующего мероприятия в список участников сам
// добавлялся человек из соседнего, конфликтующего. Правило жило внутри
// состояния виджета, проверить его было нечем.
//
// Поэтому оно вынесено чистой функцией, а здесь закреплены все случаи, в
// которых перенос НЕ должен происходить — их больше, чем положительных.

const me = 'me-uid';
const other = 'other-uid';
const third = 'third-uid';

PersonalEvent ev({
  String id = 'e1',
  String owner = other,
  List<String> people = const [third],
}) => PersonalEvent(
  id: id,
  ownerUid: owner,
  date: '2026-08-09T16:00:00.000',
  type: 'Toy',
  location: '',
  notes: '',
  participantUids: people,
  isAgree: true,
);

void main() {
  group('люди мероприятия — владелец И участники (N30)', () {
    test('владелец входит в людей, даже если его нет в musicians', () {
      // Мероприятие из календаря кладёт в musicians только выбранных, без
      // владельца; договор из предложения — владельца И вторую сторону.
      // Одно поле, два смысла — читать надо через eventPeople.
      expect(eventPeople(ev(owner: other, people: const [third])).toSet(),
          {other, third});
    });

    test('повторов не бывает, даже когда владелец лежит и в musicians', () {
      expect(eventPeople(ev(owner: other, people: const [other, third])).length,
          2);
    });
  });

  group('НЕ переносится', () {
    test('при правке существующего мероприятия — вообще ничего', () {
      // Тот самый дефект: человек открыл своё мероприятие карандашом и
      // увидел в участниках чужого, которого не добавлял.
      expect(
        participantsToMerge(
          conflicts: [ev()],
          current: const [],
          explicitlyRemoved: {},
          currentUid: me,
          isEditing: true,
        ),
        isEmpty,
      );
    });

    test('когда конфликтующих мероприятий несколько', () {
      // Заменить можно только одно, а какое — человек скажет
      // переключателем позже. Собрать список из людей всех трёх значило бы
      // угадать за него (класс B29).
      expect(
        participantsToMerge(
          conflicts: [ev(id: 'a'), ev(id: 'b', people: const ['x'])],
          current: const [],
          explicitlyRemoved: {},
          currentUid: me,
          isEditing: false,
        ),
        isEmpty,
      );
    });

    test('сам себя человек не переносит', () {
      expect(
        participantsToMerge(
          conflicts: [ev(owner: me, people: const [])],
          current: const [],
          explicitlyRemoved: {},
          currentUid: me,
          isEditing: false,
        ),
        isEmpty,
      );
    });

    test('кто уже в списке — второй раз не добавляется', () {
      expect(
        participantsToMerge(
          conflicts: [ev(owner: other, people: const [third])],
          current: const [other, third],
          explicitlyRemoved: {},
          currentUid: me,
          isEditing: false,
        ),
        isEmpty,
      );
    });

    test('явно убранный руками не возвращается', () {
      // Иначе перенос отменял бы действие человека.
      expect(
        participantsToMerge(
          conflicts: [ev(owner: other, people: const [third])],
          current: const [],
          explicitlyRemoved: {other, third},
          currentUid: me,
          isEditing: false,
        ),
        isEmpty,
      );
    });
  });

  group('замена: переносятся люди ТОЛЬКО заменяемого', () {
    test('при трёх конфликтах заранее не подмешивается никто', () {
      expect(
        participantsToMerge(
          conflicts: [
            ev(id: 'a', owner: 'own-a', people: const ['p-a']),
            ev(id: 'b', owner: 'own-b', people: const ['p-b']),
            ev(id: 'c', owner: 'own-c', people: const ['p-c']),
          ],
          current: const [],
          explicitlyRemoved: {},
          currentUid: me,
          isEditing: false,
        ),
        isEmpty,
      );
    });

    test('после выбора переключателем переносятся люди выбранного, и только', () {
      // Так это и зовётся при «Əvəz et»: список из ОДНОГО заменяемого.
      final add = participantsToMerge(
        conflicts: [ev(id: 'b', owner: 'own-b', people: const ['p-b'])],
        current: const [],
        explicitlyRemoved: {},
        currentUid: me,
        isEditing: false,
      );
      expect(add.toSet(), {'own-b', 'p-b'});
      expect(add.contains('own-a'), isFalse);
      expect(add.contains('p-c'), isFalse);
    });
  });

  group('«Yeni tədbir»: подмешанные снимаются', () {
    test('остаётся ровно то, что человек выбрал сам', () {
      final left = participantsAfterUnmerge(
        current: const ['chosen-by-hand', 'merged-1', 'merged-2'],
        merged: {'merged-1', 'merged-2'},
      );
      expect(left, ['chosen-by-hand']);
    });

    test('если подмешано было всё — не остаётся никого', () {
      expect(
        participantsAfterUnmerge(
          current: const ['merged-1', 'merged-2'],
          merged: {'merged-1', 'merged-2'},
        ),
        isEmpty,
      );
    });

    test('ничего не подмешивали — список не трогается', () {
      expect(
        participantsAfterUnmerge(
          current: const ['a', 'b'],
          merged: {},
        ),
        ['a', 'b'],
      );
    });
  });

  group('переносится', () {
    test('один конфликт при создании — владелец и участники', () {
      final add = participantsToMerge(
        conflicts: [ev(owner: other, people: const [third])],
        current: const [],
        explicitlyRemoved: {},
        currentUid: me,
        isEditing: false,
      );
      expect(add.toSet(), {other, third});
    });

    test('владелец заменяемого мероприятия не теряется (N31)', () {
      // Ровно то, что владелец проекта заметил на устройстве: переносился
      // участник, а создатель мероприятия — нет.
      final add = participantsToMerge(
        conflicts: [ev(owner: other, people: const [])],
        current: const [],
        explicitlyRemoved: {},
        currentUid: me,
        isEditing: false,
      );
      expect(add, [other]);
    });
  });
}
