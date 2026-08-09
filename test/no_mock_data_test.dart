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
    // КАНАРЕЙКА живёт в том же обходе, а не рядом с ним: считается тем же
    // циклом, по тем же файлам, после того же снятия комментариев и тем
    // же `hasMatch`. Проверка ниже утверждает ОТСУТСТВИЕ, а такое
    // утверждение ослепший разбор подтверждает МОЛЧА (I31): не
    // прочиталось ни одного файла — список нарушителей пуст, сторож
    // зелёный. Отличить «вшитых списков нет» от «обход не видит ничего»
    // изнутри нечем, поэтому рядом считается то, что разбор ОБЯЗАН найти.
    var scanned = 0;
    var canary = 0;
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      // Комментарии не в счёт: разбор дефекта рядом называет то, что
      // проверяется (I12).
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      scanned += 1;
      if (RegExp(r'\bWidget\s+build\s*\(').hasMatch(code)) canary += 1;
      if (RegExp(r'_fallback(Events|Rooms|Musicians|Chats)\b').hasMatch(code)) {
        offenders.add(f.path);
      }
    }
    expect(
      scanned,
      greaterThan(0),
      reason: 'обход не прочитал НИ ОДНОГО файла в lib/. Пустой список '
          'нарушителей ниже означал бы не «вшитых данных нет», а «искать '
          'было негде» — рабочий каталог теста или путь сменились.',
    );
    expect(
      canary,
      greaterThan(0),
      reason: 'файлы прочитаны ($scanned штук), но `Widget build(` не нашёлся '
          'ни в одном — значит сломался не поиск заглушек, а сам разбор: '
          'снятие комментариев съело код либо регулярка перестала работать. '
          'Пустой список нарушителей ниже в этом случае не значит ничего.',
    );
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
    // КАНАРЕЙКИ к шести утверждениям отсутствия ниже — по одной на каждый
    // читаемый файл, ТЕМ ЖЕ `contains` и по той же строке (I31). Без них
    // «правила-заглушки не вернулись» и «файл прочитался пустым» дают
    // один и тот же зелёный вывод: пустая строка не содержит ничего, в
    // том числе и запрещённого.
    expect(
      rules.contains('match /chats/'),
      isTrue,
      reason: 'в прочитанных правилах нет даже `match /chats/` — читается не '
          'тот файл или не читается вовсе. Шесть проверок ниже в этом '
          'случае зелены не потому, что заглушек нет.',
    );
    expect(
      rules.contains('match /events/'),
      isFalse,
      reason: 'правило-заглушка на events вернулось — доступ открыт к тому, '
          'чего в проде нет и что ничем не читается',
    );
    expect(rules.contains('match /rooms/'), isFalse);

    final service =
        readCode('lib/firebase/firestore_service.dart');
    expect(
      service.contains("collection('chats')"),
      isTrue,
      reason: 'в прочитанной службе нет ни одного `collection(\'chats\')` — '
          'путь сменился или файл пуст. Четыре проверки ниже тогда ничего '
          'не проверяют.',
    );
    expect(service.contains('fetchEvents()'), isFalse);
    expect(service.contains('fetchRooms()'), isFalse);
    expect(service.contains("collection('events')"), isFalse);
    expect(service.contains("collection('rooms')"), isFalse);
  });
}
