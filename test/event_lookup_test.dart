import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_lookup.dart';
import 'package:mugam_flutter/firebase/models.dart';

// Правило публичной двери в карточку (N90): найти документ по id и
// решить, договор это или мероприятие.
//
// Вынесено из экрана ДО появления третьего читателя (I23): по `isAgree`
// судят два списка, а с дверью будет судить и она.

PersonalEvent _event({
  required String id,
  bool isAgree = false,
  String ownerUid = 'me',
}) =>
    PersonalEvent(
      id: id,
      ownerUid: ownerUid,
      date: '2026-08-09T19:00:00.000',
      type: 'Toy',
      location: '',
      notes: '',
      participantUids: const [],
      isAgree: isAgree,
    );

void main() {
  group('поиск документа по id', () {
    test('находит среди своих', () {
      final own = [_event(id: 'a'), _event(id: 'b')];
      expect(findEventById('b', own, const [])?.id, 'b');
    });

    // Половина людей не нашла бы собственный договор, ищи мы в одном
    // списке: у владельца документ приходит потоком «мои», у второй
    // стороны — потоком «где я участник».
    test('находит среди тех, где я участник', () {
      final part = [_event(id: 'c', ownerUid: 'other')];
      expect(findEventById('c', const [], part)?.id, 'c');
    });

    test('чужого id нет — null, а не первый попавшийся', () {
      final own = [_event(id: 'a')];
      expect(findEventById('zzz', own, const []), isNull);
    });

    // Порядок назван в самой функции: своя запись главнее, потому что по
    // ней считаются права на правку.
    test('при совпадении в обоих списках берётся своя запись', () {
      final own = [_event(id: 'x', ownerUid: 'me')];
      final part = [_event(id: 'x', ownerUid: 'other')];
      expect(findEventById('x', own, part)?.ownerUid, 'me');
    });
  });

  group('какую карточку показывать', () {
    // Признак взят оттуда, где уже работает: `isAgree` отбирает список
    // договоров. Сломай это — и человек, открывший договор, увидит
    // карточку мероприятия: без кнопок отмены, без сторон, без истории.
    test('isAgree — карточка договора', () {
      expect(
        eventCardKindOf(_event(id: 'a', isAgree: true)),
        EventCardKind.agreement,
      );
    });

    test('без isAgree — карточка мероприятия', () {
      expect(
        eventCardKindOf(_event(id: 'a')),
        EventCardKind.personalEvent,
      );
    });
  });
}
