import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/chat/chat_departure.dart';

// Уход человека из чата: два пути, одно правило.
//
// Теста на это правила НЕ БЫЛО, и дыра держалась ровно потому, что путей
// два, а смотрели на них порознь: `leaveGroup` (вышел сам) и
// `removeGroupMember` (удалил админ) оба снимали членство и оба НЕ снимали
// отметку присутствия `activeUsers`. Нашлось не глазами и не на устройстве
// — опытом на двух наборах правил, когда выяснилось, что вышедший,
// застрявший в `activeUsers`, получил бы чтение чужого чата.
//
// Поэтому случай «отметка присутствия ушла вместе с членством» закреплён
// ОТДЕЛЬНО для каждого пути. Один тест на оба не годится: он зазеленел бы,
// почини мы только один путь, — а именно так дыра и появилась.

const leaving = 'leaving-uid';
const stays = 'stays-uid';
const third = 'third-uid';
const admin = 'admin-uid';

void main() {
  group('отметка присутствия не переживает членство', () {
    // ПУТЬ 1 — вышел сам (leaveGroup).
    test('вышел сам: uid исчезает и из members, и из activeUsers', () {
      final after = chatAfterDeparture(
        members: const [leaving, stays],
        admins: const [stays],
        activeUsers: const [leaving, stays],
        uid: leaving,
      );

      expect(after.members, const [stays]);
      expect(
        after.activeUsers,
        const [stays],
        reason: 'вышедший остался в activeUsers — он больше не участник, '
            'но признак присутствия в чате сохранил',
      );
    });

    // ПУТЬ 2 — удалил админ (removeGroupMember). Отдельным тестом
    // намеренно: чинить пути порознь нельзя, но и проверять их одним
    // случаем — значит не заметить, если разойдутся снова.
    test('удалил админ: uid исчезает и из members, и из activeUsers', () {
      final after = chatAfterDeparture(
        members: const [admin, leaving, stays],
        admins: const [admin],
        activeUsers: const [leaving],
        uid: leaving,
      );

      expect(after.members, const [admin, stays]);
      expect(
        after.activeUsers,
        isEmpty,
        reason: 'удалённый админом остался в activeUsers',
      );
    });

    test('чужие отметки присутствия не трогаются', () {
      final after = chatAfterDeparture(
        members: const [leaving, stays, third],
        admins: const [],
        activeUsers: const [stays, leaving, third],
        uid: leaving,
      );
      expect(after.activeUsers, const [stays, third]);
    });

    test('уходящего не было в activeUsers — список не меняется', () {
      final after = chatAfterDeparture(
        members: const [leaving, stays],
        admins: const [],
        activeUsers: const [stays],
        uid: leaving,
      );
      expect(after.activeUsers, const [stays]);
    });

    test('последний участник: пустые списки, а не застрявшая отметка', () {
      // Документ чата после этого остаётся жить с пустым members —
      // застрявшая тут отметка была бы отметкой присутствия в чате, где
      // участников нет вовсе.
      final after = chatAfterDeparture(
        members: const [leaving],
        admins: const [leaving],
        activeUsers: const [leaving],
        uid: leaving,
      );
      expect(after.members, isEmpty);
      expect(after.activeUsers, isEmpty);
    });
  });

  group('повышение администратора — прежнее поведение сохранено', () {
    test('ушёл единственный админ, люди остались — повышать', () {
      final after = chatAfterDeparture(
        members: const [leaving, stays, third],
        admins: const [leaving],
        activeUsers: const [],
        uid: leaving,
      );
      expect(after.needsAdminPromotion, isTrue);
    });

    test('ушёл НЕ админ — не повышать, даже если админов нет вовсе', () {
      // Прежний код повышал только когда уходил админ. Правило обязано
      // сохранить это: иначе перенос тихо поправил бы поведение.
      final after = chatAfterDeparture(
        members: const [leaving, stays],
        admins: const [],
        activeUsers: const [],
        uid: leaving,
      );
      expect(after.needsAdminPromotion, isFalse);
    });

    test('ушёл админ, но остался другой админ — не повышать', () {
      final after = chatAfterDeparture(
        members: const [leaving, admin, stays],
        admins: const [leaving, admin],
        activeUsers: const [],
        uid: leaving,
      );
      expect(after.needsAdminPromotion, isFalse);
    });

    test('ушёл последний админ и людей не осталось — повышать некого', () {
      final after = chatAfterDeparture(
        members: const [leaving],
        admins: const [leaving],
        activeUsers: const [],
        uid: leaving,
      );
      expect(after.needsAdminPromotion, isFalse);
    });
  });
}
