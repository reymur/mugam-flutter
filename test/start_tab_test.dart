import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mugam_flutter/core/settings/image_quality_settings.dart'
    show sharedPreferencesProvider;
import 'package:mugam_flutter/core/settings/start_tab_settings.dart';
import 'package:mugam_flutter/navigation/app_tabs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/source_text.dart';

// «Tətbiq açılır…» — с какой вкладки открывается приложение.
//
// Настройка про устройство, а не про человека, поэтому живёт в
// SharedPreferences. Хранится ИМЯ вкладки: номер пережил бы перестановку
// панели молча и увёл бы человека не туда.

void main() {
  group('resolveStartPath — разбор сохранённого имени', () {
    test('ничего не сохранено — первая вкладка', () {
      expect(resolveStartPath(null), kStartPath);
      expect(resolveStartPath(''), kStartPath);
    });

    test('сохранено живое имя — путь этой вкладки', () {
      for (final tab in kAppTabs) {
        expect(resolveStartPath(tab.id), tab.path);
      }
    });

    test('ИСЧЕЗНУВШЕЕ имя — откат на первую вкладку, а не пустой экран', () {
      // Главная опасность этой настройки, и она наступает без единого
      // действия человека: сохранённое имя переживает обновление
      // приложения, а состав панели меняется — вкладка уезжает в
      // «Tezliklə» и обратно (N60). Без отката человек получил бы экран
      // ниоткуда в момент, когда сам ни на что не нажимал.
      expect(resolveStartPath('board'), kStartPath);
      expect(resolveStartPath('market'), kStartPath);
      expect(resolveStartPath('вкладка-которой-нет'), kStartPath);
    });

    test('путь возвращается ТОТ ЖЕ, что у вкладки в панели', () {
      // Иначе настройка увела бы на путь, которого в панели нет вовсе, и
      // человек оказался бы на экране без нижней панели.
      for (final tab in kAppTabs) {
        expect(kAppTabs.map((t) => t.path), contains(resolveStartPath(tab.id)));
      }
    });
  });

  group('состав списка настройки', () {
    test('предлагаются ровно вкладки панели — сверка ИМЁН, не количества', () {
      // I13: сторож, считающий не то, молчит так же, как сторож, которому
      // нечего сказать. Список имён недосчитать незаметно нельзя.
      final offered = kAppTabs.map((t) => t.id).toList();
      expect(
        offered,
        equals(const ['agreements', 'home', 'search', 'chats', 'profile', 'soon']),
        reason: 'состав панели изменился — список настройки строится из '
            'kAppTabs и меняется вместе с ней, но проверить состав всё '
            'равно надо: настройка предлагает то же, что панель показывает',
      );
    });
  });

  group('НАБЛЮДАЕМОЕ ПОВЕДЕНИЕ — то, без чего повторится N57', () {
    // Настройка, у которой значение сохраняется, а действия не видно, —
    // ровно тот дефект: поведение есть, наблюдать нечем, и подмена не
    // может провалиться ни при какой перестановке. Поэтому проверяется
    // не «в prefs записалось», а «приложение открылось ТАМ».
    Future<String> openedPathFor(String? savedTabId) async {
      SharedPreferences.setMockInitialValues(
        savedTabId == null ? {} : {startTabKey: savedTabId},
      );
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      return resolveStartPath(container.read(startTabProvider));
    }

    testWidgets('с сохранённой «Axtar» приложение открывается на «Axtar»',
        (tester) async {
      final path = await openedPathFor('search');
      final search = kAppTabs.firstWhere((t) => t.id == 'search');
      expect(path, search.path);

      // И это ДЕЙСТВИТЕЛЬНО приводит на экран поиска, а не просто равно
      // строке: маршрут отрабатывается настоящим роутером.
      final router = GoRouter(
        initialLocation: path,
        routes: [
          for (final tab in kAppTabs)
            GoRoute(
              path: tab.path,
              builder: (c, s) => Scaffold(body: Center(child: Text(tab.label))),
            ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(find.text(search.label), findsOneWidget);
      expect(
        find.text(kAppTabs.first.label),
        findsNothing,
        reason: 'открылась первая вкладка вместо сохранённой — настройка '
            'записывается, но ни на что не влияет',
      );
    });

    testWidgets('ничего не сохранено — открывается первая вкладка',
        (tester) async {
      expect(await openedPathFor(null), kStartPath);
    });

    testWidgets('сохранена вкладка, которой больше нет — первая вкладка',
        (tester) async {
      expect(await openedPathFor('market'), kStartPath);
    });

    test('выбор сохраняется между запусками', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      await container.read(startTabProvider.notifier).setTab('chats');
      expect(container.read(startTabProvider), 'chats');
      // Следующий запуск читает то же самое с диска, а не из памяти.
      expect(prefs.getString(startTabKey), 'chats');

      final next = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(next.dispose);
      expect(resolveStartPath(next.read(startTabProvider)),
          kAppTabs.firstWhere((t) => t.id == 'chats').path);
    });
  });

  group('сторож: настройка применена в единственном месте запуска', () {
    test('AuthGateScreen спрашивает resolveStartPath, а не kStartPath', () {
      // Проверка текстовая, поэтому смотрит на КОД без комментариев (I12):
      // разбор рядом цитирует то, что проверяется.
      final gate = _codeOf('lib/navigation/auth_gate_screen.dart');
      expect(
        gate.contains('resolveStartPath'),
        isTrue,
        reason: 'экран запуска снова уводит на жёсткий kStartPath — '
            'настройка сохраняется и не делает ничего',
      );
    });
  });
}

String _codeOf(String path) {
  return (const LineSplitter())
      .convert(File(path).readAsStringSync())
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}
