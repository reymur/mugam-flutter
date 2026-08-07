import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/navigation/app_tabs.dart';
import 'package:mugam_flutter/shared/widgets/custom_tab_bar.dart';

import 'support/source_text.dart';

// N60 — пять экранов ушли из панели, но не из приложения.
//
// Опасность у этой правки одна и названа владельцем заранее: **через
// месяц их вычистят как мёртвый код**. Комментарий рядом с маршрутом от
// этого не спасает — он защищает строку, а не класс. Спасает тест: тот,
// кто удалит экран, увидит красный, а не пустое место.

const _hidden = <String, String>{
  '/board': 'lib/features/board/screens/board_screen.dart',
  '/gigs': 'lib/features/gigs/screens/gigs_screen.dart',
  '/market': 'lib/features/market/screens/market_screen.dart',
  '/stories': 'lib/features/stories/screens/stories_screen.dart',
  '/video': 'lib/features/video/screens/video_screen.dart',
};

void main() {
  group('спрятанные экраны живы и достижимы (N60)', () {
    late String router;

    setUpAll(() {
      router = readCode('lib/navigation/app_router.dart');
    });

    test('файл каждого экрана на месте', () {
      for (final entry in _hidden.entries) {
        expect(
          File(entry.value).existsSync(),
          isTrue,
          reason: 'Экран ${entry.key} удалён (${entry.value}). Он убран из '
              'панели, но не из приложения: работа по нему записана в '
              'реестре (N60), и удалять его нельзя, пока она там стоит.',
        );
      }
    });

    test('маршрут каждого объявлен верхним уровнем', () {
      for (final path in _hidden.keys) {
        expect(
          router.contains("path: '$path'"),
          isTrue,
          reason: 'Маршрут $path исчез. Без него экран недостижим вовсе — '
              '«спрятан» превращается в «выброшен», а на эти пути в '
              'приложении не ссылается больше ничто (проверено 07.08).',
        );
      }
    });

    test('спрятанного нет в панели, а в «Tezliklə» — есть', () {
      final tabPaths = kAppTabs.map((t) => t.path).toSet();
      final soonPaths = kSoonFeatures.map((f) => f.path).toSet();
      for (final path in _hidden.keys) {
        expect(tabPaths.contains(path), isFalse, reason: '$path снова в панели');
        expect(
          soonPaths.contains(path),
          isTrue,
          reason: '$path пропал из «Tezliklə» — экран есть, а человеку о нём '
              'не сказано нигде',
        );
      }
    });

    test('«Tezliklə» не обещает того, чего нет', () {
      // Строка ведёт по пути — путь обязан существовать. Иначе список
      // однажды пообещает экран, который убрали.
      for (final f in kSoonFeatures) {
        final path = f.path;
        if (path == null) continue;
        expect(
          router.contains("path: '$path'"),
          isTrue,
          reason: 'строка «${f.title}» ведёт на $path, а такого маршрута нет',
        );
      }
    });
  });

  group('панель на шесть вкладок', () {
    test('состав и первая вкладка — стартовая', () {
      expect(kAppTabs.length, 6);
      expect(kAppTabs.first.id, 'agreements');
      expect(kStartPath, kAppTabs.first.path);
    });

    testWidgets('на узком экране помещается целиком, без листания',
        (tester) async {
      // 320 pt — самый узкий из живых экранов (iPhone SE первого
      // поколения). Проверяется не «выглядит нормально», а два факта:
      // подписи всех шести на месте и горизонтального списка в панели
      // нет вовсе.
      tester.view.physicalSize = const Size(320 * 3, 568 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: CustomTabBar(currentIndex: 0, onTap: (_) {}),
        ),
      ));
      await tester.pumpAndSettle();

      for (final tab in kAppTabs) {
        expect(
          find.text(tab.label),
          findsOneWidget,
          reason: 'на узком экране не видно вкладку «${tab.label}»',
        );
      }
      expect(
        find.byType(Scrollable),
        findsNothing,
        reason: 'панель снова листается вбок — при шести вкладках это '
            'прячет от человека часть панели без нужды',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('на широком экране тоже целиком', (tester) async {
      tester.view.physicalSize = const Size(430 * 3, 932 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: CustomTabBar(currentIndex: 0, onTap: (_) {}),
        ),
      ));
      await tester.pumpAndSettle();

      for (final tab in kAppTabs) {
        expect(find.text(tab.label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('счётчик непрочитанного виден — то самое наблюдаемое поведение (N57)', () {
    // Отсутствие этой проверки и породило находку: бейдж висел на номере
    // вкладки, а число в панель не передавалось вовсе, поэтому подмену
    // вкладки было нечем заметить. Проверяется не «переменная передана»,
    // а то, что человек ВИДИТ: есть число при непрочитанном и нет ничего
    // при нуле.
    Future<void> pumpBar(WidgetTester tester, int unread) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          bottomNavigationBar: CustomTabBar(
            currentIndex: 0,
            onTap: (_) {},
            unreadCount: unread,
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('при ненулевом числе бейдж есть', (tester) async {
      await pumpBar(tester, 3);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('при нуле бейджа нет вовсе', (tester) async {
      await pumpBar(tester, 0);
      expect(find.text('0'), findsNothing);
    });

    test('оболочка ДЕЙСТВИТЕЛЬНО передаёт число в панель', () {
      // Найдено проверкой возвратом в день написания: убрал передачу из
      // `MainShell` — ни один тест не упал, потому что все они дёргают
      // панель напрямую. Это ровно N57 на шаг выше: панель умеет
      // показывать бейдж, а получить число ей неоткуда, и заметить это
      // нечем.
      //
      // Проверка текстовая, поэтому смотрит на КОД без комментариев
      // (I12): разбор дефекта рядом цитирует то, что проверяется.
      final shell = File('lib/navigation/main_shell.dart')
          .readAsStringSync()
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
          .join('\n');

      expect(
        RegExp(r'unreadCount:\s*\w+').hasMatch(shell),
        isTrue,
        reason: 'MainShell перестал передавать счётчик в панель — бейдж '
            'снова не показывается никогда (N57)',
      );
      expect(
        shell.contains('chatsProvider'),
        isTrue,
        reason: 'число берётся не из потока чатов — значит либо считается '
            'заново, либо пришло из воздуха',
      );
      expect(
        shell.contains('unreadCount > 0'),
        isTrue,
        reason: 'считаются не ЧАТЫ с непрочитанным: «29 сообщений» вместо '
            '«3 разговора» — разные вещи, решение владельца 07.08',
      );
    });

    testWidgets('бейдж стоит на вкладке MESAJ, а не на первой попавшейся',
        (tester) async {
      await pumpBar(tester, 5);
      final badge = find.text('5');
      expect(badge, findsOneWidget);
      // Ищем подпись вкладки, внутри которой нарисован бейдж: имя, а не
      // номер (N57). Перестановка вкладок этот тест не сломает — он
      // спрашивает про «MESAJ», а не про шестую позицию.
      final tab = kAppTabs.firstWhere((t) => t.id == kUnreadBadgeTabId);
      final column = find.ancestor(
        of: badge,
        matching: find.ancestor(of: find.text(tab.label), matching: find.byType(Column)),
      );
      expect(column, findsWidgets);
    });
  });
}
