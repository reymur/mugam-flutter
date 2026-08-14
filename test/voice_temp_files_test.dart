import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/audio/voice_temp_files.dart';
import 'package:mugam_flutter/core/job_offer/day_details.dart';
import 'package:mugam_flutter/features/job_offer/screens/job_offer_days_sheet.dart';

// ЗАПИСЬ, СДЕЛАННАЯ И НЕ ОТПРАВЛЕННАЯ, ОБЯЗАНА ПРОПАСТЬ С ДИСКА.
//
// Вопрос владельца 14.08 дословно: «проверь, что она правда пропадает, а не
// остаётся файлом на телефоне. Мусор, который никто не подберёт, копится
// молча».
//
// Проверяется НАСТОЯЩИМИ ФАЙЛАМИ, а не заглушкой: заглушка ответила бы, что
// мы позвали удаление, и промолчала бы о том, удалилось ли. Это ровно та
// разница, из-за которой уборку и вынесли из листа в отдельную функцию с
// числом на выходе.

void main() {
  group('уборка временных записей — настоящими файлами', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('voice_test');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    File makeFile(String name) {
      final f = File('${dir.path}/$name')..writeAsStringSync('звук');
      expect(f.existsSync(), isTrue, reason: 'файл не создался — тест слеп');
      return f;
    }

    test('файл действительно исчезает с диска', () {
      final a = makeFile('a.m4a');
      final b = makeFile('b.m4a');

      final removed = deleteVoiceTempFiles([a.path, b.path]);

      expect(removed, 2);
      expect(a.existsSync(), isFalse, reason: 'запись осталась на диске');
      expect(b.existsSync(), isFalse, reason: 'запись осталась на диске');
    });

    // Тот же файл после копирования деталей принадлежит нескольким дням.
    // Второй заход по нему законно не находит ничего, и это не сбой.
    test('повторный путь не считается удалённым дважды', () {
      final a = makeFile('a.m4a');
      expect(deleteVoiceTempFiles([a.path, a.path]), 1);
    });

    test('несуществующий путь не роняет уборку', () {
      expect(deleteVoiceTempFiles(['${dir.path}/нет-такого.m4a']), 0);
    });

    test('пустой список — ноль, и без обращения к диску', () {
      expect(deleteVoiceTempFiles(const []), 0);
    });
  });

  // ВТОРАЯ ПОЛОВИНА: уборку надо не только уметь, но и ПОЗВАТЬ — и позвать
  // ровно тогда, когда лист закрыт БЕЗ отправки.
  group('лист зовёт уборку в нужный момент', () {
    Future<void> pumpSheet(
      WidgetTester tester, {
      required void Function(Set<String>) onDiscard,
      required void Function() onSent,
      required GlobalKey<NavigatorState> nav,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: Scaffold(
            body: JobOfferDaysSheet(
              initialMonth: DateTime(2026, 8),
              now: DateTime(2026, 8, 1),
              initialDates: const ['2026-08-14'],
              onDiscardVoiceFiles: onDiscard,
              onRecordVoice: (iso) async =>
                  const DayDetails(voicePath: '/tmp/запись.m4a'),
              onSend: ({required dates, required eventType, required details}) {
                onSent();
              },
            ),
          ),
        ),
      );
    }

    testWidgets('закрыт без отправки — уборка позвана с путём записи', (
      tester,
    ) async {
      Set<String>? discarded;
      final nav = GlobalKey<NavigatorState>();
      await pumpSheet(
        tester,
        nav: nav,
        onDiscard: (p) => discarded = p,
        onSent: () {},
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-mic-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-mic-2026-08-14')));
      await tester.pumpAndSettle();

      // Снимаем лист — это и есть «закрыл, не отправив».
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();

      expect(discarded, isNotNull, reason: 'уборка не позвана вовсе');
      expect(discarded, {'/tmp/запись.m4a'});
    });

    // ПАРА К ПРЕДЫДУЩЕМУ. Без неё «уборка позвана» было бы верно и для
    // листа, который стирает только что отправленную запись, — а её файл
    // ещё нужен: он грузится при отправке.
    testWidgets('после отправки уборка НЕ зовётся', (tester) async {
      var discardCalls = 0;
      var sent = false;
      final nav = GlobalKey<NavigatorState>();
      await pumpSheet(
        tester,
        nav: nav,
        onDiscard: (_) => discardCalls += 1,
        onSent: () => sent = true,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-mic-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-mic-2026-08-14')));
      await tester.pumpAndSettle();
      // Тип обязателен — без него кнопка не работает.
      await tester.tap(find.byKey(const ValueKey('offer-type-Toy')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-send-days')));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();

      expect(sent, isTrue, reason: 'отправка не сработала — тест не о том');
      expect(
        discardCalls,
        0,
        reason: 'уборка стёрла запись, которую только что отправили',
      );
    });
  });
}
