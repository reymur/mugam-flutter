import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/navigation/app_tabs.dart';
import 'package:mugam_flutter/shared/widgets/custom_tab_bar.dart';

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
      router = File('lib/navigation/app_router.dart').readAsStringSync();
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
}
