import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// СТОРОЖ НА ПРОВОДКУ ОТМЕТКИ ВРЕМЕНИ (N181).
//
// Правило покрыто дважды и хорошо: правила Firestore держат подлинность
// времени (`last-action-at-rules.test.ts`, 12 вердиктов), ключ скрытия
// держит различение повторов (`event_deed_line_test.dart`). Обе проверки
// молчат об одном и том же: **пишет ли клиент это поле вообще.**
//
// Забудь его хоть один писатель — и всё останется зелёным, а на трубке
// вернётся ровно тот дефект, ради которого работа делалась: второй такой же
// уход останется спрятанным. Это I64 — проверять не наличие правила, а
// КАЖДОГО, КТО ПОД НЕГО ПОДПАДАЕТ.
//
// ВЕРДИКТ УТВЕРЖДАЕТ НАЛИЧИЕ, значит сам себе канарейка (I31): ослепни
// разбор — множество писателей опустеет, и падёт соседка ниже.
//
// ЧЕГО ЭТОТ СТОРОЖ НЕ ЛОВИТ, и это надо знать, иначе на него положатся шире
// его умения:
//   • он читает ИСХОДНИКИ, а не поведение. Писатель, кладущий поле в
//     переменную и пишущий переменную, ему невидим;
//   • он ничего не знает о СЕРВЕРНЫХ писателях (`functions/src`). Там своя
//     отметка и свои правила, и `lastActionType` пишет `markEventUnsettled`
//     мимо этого разбора;
//   • он не проверяет, что записанное время СЕРВЕРНОЕ — это дело правил
//     (`stampsTime`), и повторять его здесь значило бы завести второе место
//     с тем же правилом.

/// Файлы, где поступок пишется, а отметка времени ставится НЕ рядом.
///
/// Список ровно один, и он не «исключение на всякий случай» — у него есть
/// причина, и она проверяется чтением: `eventEditUpdate` собирает карту
/// полей и намеренно остаётся ЧИСТЫМ правилом, проверяемым без Firestore.
/// `FieldValue.serverTimestamp()` втащил бы туда зависимость от базы.
/// Отметку ставит единственный писатель этой карты —
/// `FirestoreService.updatePersonalEvent`, и вердикт на него стоит ниже.
const _stampedByWriter = <String>{
  'lib/core/agreements/event_edit.dart',
};

void main() {
  group('отметка времени поступка проведена до писателей (N181)', () {
    final deed = RegExp(r"'lastActionType':");
    final stamp = RegExp(r"'lastActionAt':");

    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => MapEntry(f.path, f.readAsStringSync()))
        .where((e) => deed.hasMatch(e.value))
        .toList();

    test('КАНАРЕЙКА: писатели поступка вообще находятся', () {
      // Без неё «нарушителей нет» и «разбор ослеп» дают один зелёный вывод.
      // Здесь названо число, а не только «не пусто» (I13): недосчитать
      // список незаметно нельзя, он сам говорит, кого не хватает.
      expect(files, isNotEmpty);
      final total = files.fold<int>(
        0,
        (n, e) => n + deed.allMatches(e.value).length,
      );
      expect(
        total,
        9,
        reason: 'писателей поступка стало $total вместо девяти — '
            'перечитать разбор в docs/plan.md и завести отметку новому',
      );
    });

    test('у каждого писателя поступка есть отметка времени', () {
      final missing = files
          .where((e) => !_stampedByWriter.contains(e.key))
          .where((e) => !stamp.hasMatch(e.value))
          .map((e) => e.key)
          .toList();
      expect(
        missing,
        isEmpty,
        reason: 'поступок пишется без времени: ${missing.join(', ')}. '
            'Ключ скрытия не различит повтор — вернётся N181.',
      );
    });

    test('число отметок сходится с числом поступков в каждом файле', () {
      // Один писатель на файл — случай редкий: в firestore_service.dart их
      // семь. Проверка «есть хоть одна отметка» пропустила бы файл, где
      // отметку поставили шестерым из семи. Сверяется СОСТАВ, а не факт.
      //
      // ПОПРАВКА НА ОДНУ, И ОНА НАСТОЯЩАЯ, А НЕ ПОСЛАБЛЕНИЕ. У
      // `firestore_service.dart` отметок восемь при семи поступках: восьмая
      // стоит в `updatePersonalEvent` и обслуживает ЧУЖУЮ карту — ту, что
      // собирает чистый `eventEditUpdate` из `_stampedByWriter`. То есть
      // лишняя отметка здесь ровно одна и ровно потому, что одно
      // исключение выше существует. Первая редакция этого вердикта считала
      // без поправки и покраснела на верном коде — ложная тревога, которая
      // стоила бы правки исправного места (I14).
      const servesExceptions = 'lib/firebase/firestore_service.dart';
      for (final e in files) {
        if (_stampedByWriter.contains(e.key)) continue;
        final extra = e.key == servesExceptions ? _stampedByWriter.length : 0;
        expect(
          stamp.allMatches(e.value).length,
          deed.allMatches(e.value).length + extra,
          reason: '${e.key}: поступков и отметок разное число',
        );
      }
    });

    test('писатель карты правки ставит отметку сам', () {
      // Вторая половина исключения выше. Без этого вердикта список
      // `_stampedByWriter` стал бы дырой: файл в нём освобождён от проверки,
      // и то, что отметку ставит кто-то другой, не проверялось бы ничем.
      final service =
          File('lib/firebase/firestore_service.dart').readAsStringSync();
      final i = service.indexOf('Future<void> updatePersonalEvent(');
      expect(i, greaterThan(0), reason: 'писатель карты правки не найден');
      final body = service.substring(i, i + 400);
      expect(
        body.contains("'lastActionAt': FieldValue.serverTimestamp()"),
        isTrue,
        reason: 'updatePersonalEvent перестал ставить время — а '
            'eventEditUpdate на него рассчитывает',
      );
      expect(
        body.contains("containsKey('lastActionType')"),
        isTrue,
        reason: 'время ставится безусловно — отметка без поступка попадёт '
            'в ключ строки, которой нет',
      );
    });
  });
}
