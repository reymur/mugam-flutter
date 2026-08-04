import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Проход по исходникам — третье средство из разбора «комментарий защищает
// строку, а не класс» (AUDIT_TODO.md). Оно ловит ровно то, чего не ловят
// ни тип, ни обычный тест: ДОПИСЫВАНИЕ нового кода мимо правила. Тот, кто
// заводит третий путь удаления участника, в `chat_departure.dart` не
// смотрит и комментария там не увидит — увидит красный тест.
//
// Здесь же место будущему проходу по цепочкам `.where(` (запрет «форма
// запроса обязана доказывать правило чтения», тот же разбор).

const _service = 'lib/firebase/firestore_service.dart';

void main() {
  late List<String> lines;
  late String source;

  setUpAll(() {
    source = File(_service).readAsStringSync();
    lines = source.split('\n');
  });

  group('удаление участника идёт только через chatAfterDeparture', () {
    test('никто не вычёркивает uid из members через arrayRemove', () {
      // Сокращение `members` — это и есть уход из чата, а уход обязан
      // снимать вместе с членством и отметку присутствия. `arrayRemove`
      // по этому полю снимает членство В ОБХОД правила и молча оставляет
      // человека в `activeUsers` — ровно та дыра, что была в
      // removeGroupMember до 04.08.
      final offenders = <String>[];
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.contains("'members'") && l.contains('arrayRemove')) {
          offenders.add('$_service:${i + 1}: ${l.trim()}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Участник вычёркивается из members мимо chatAfterDeparture '
            '(lib/core/chat/chat_departure.dart). Считать оставшиеся списки '
            'этим правилом и записывать их целиком, вместе с activeUsers:\n'
            '${offenders.join('\n')}',
      );
    });

    test('members и activeUsers пишутся правилом ВМЕСТЕ, а не порознь', () {
      // Пара, а не два отдельных числа: путь ухода, который позовёт
      // правило и запишет из него только members, забыв activeUsers,
      // воспроизведёт исходный дефект при живом правиле.
      final calls = 'chatAfterDeparture('.allMatches(source).length;
      final membersWrites = "'members': after.members".allMatches(source).length;
      final activeWrites =
          "'activeUsers': after.activeUsers".allMatches(source).length;

      expect(
        membersWrites,
        activeWrites,
        reason: 'Путь ухода пишет members и activeUsers порознь: '
            'members $membersWrites раз, activeUsers $activeWrites раз. '
            'Отметка присутствия обязана уходить вместе с членством.',
      );
      expect(
        calls,
        membersWrites,
        reason: 'Вызовов chatAfterDeparture $calls, а записей его результата '
            '$membersWrites. Либо правило зовут и не используют, либо путь '
            'ухода дописан мимо него.',
      );
    });
  });
}
