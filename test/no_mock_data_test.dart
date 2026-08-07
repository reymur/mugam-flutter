import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

// Вшитые в код данные, показанные живым людям (уборка 07.08).
//
// На главном экране стояли два списка-заглушки: `_fallbackEvents` (четыре
// майских концерта) и `_fallbackRooms`. Показывались они по условию
// «список из базы пуст», а в проде обе коллекции были ПУСТЫ — 0
// документов в `events`, 0 в `rooms`. То есть условие было истинно
// всегда, и заглушка была не запасным вариантом, а единственным: люди
// видели выдумку и считали её расписанием.
//
// Опасность у такой заглушки одна и та же всегда: она выглядит рабочим
// экраном. Пока она на месте, пустоту в базе нечем заметить — ни глазом,
// ни тестом. Поэтому проверка не «списков нет в этом файле», а «нигде в
// приложении нет данных, притворяющихся пришедшими с сервера».

void main() {
  test('в коде нет вшитых списков, выдаваемых за содержимое', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      // Комментарии не в счёт: разбор дефекта рядом называет то, что
      // проверяется (I12).
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      if (RegExp(r'_fallback(Events|Rooms|Musicians|Chats)\b').hasMatch(code)) {
        offenders.add(f.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'вшитые данные вернулись в ${offenders.join(", ")}. Экран, '
          'показывающий выдуманное вместо пустого, не даёт заметить, что с '
          'сервера не пришло ничего.',
    );
  });

  test('коллекций events и rooms не осталось ни в коде, ни в правилах', () {
    final rules = File('firestore.rules')
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(
      rules.contains('match /events/'),
      isFalse,
      reason: 'правило-заглушка на events вернулось — доступ открыт к тому, '
          'чего в проде нет и что ничем не читается',
    );
    expect(rules.contains('match /rooms/'), isFalse);

    final service =
        readCode('lib/firebase/firestore_service.dart');
    expect(service.contains('fetchEvents()'), isFalse);
    expect(service.contains('fetchRooms()'), isFalse);
    expect(service.contains("collection('events')"), isFalse);
    expect(service.contains("collection('rooms')"), isFalse);
  });
}
