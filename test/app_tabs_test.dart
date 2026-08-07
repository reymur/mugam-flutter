import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/navigation/app_tabs.dart';

import 'support/source_text.dart';

// N57/N58 — состав и порядок нижней панели.
//
// Порядок был записан ДВАЖДЫ: списком в `custom_tab_bar.dart` и порядком
// веток в `app_router.dart`. Связаны они были ничем, кроме совпадения:
// панель отдаёт номер вкладки в `goBranch(index)`, и обе стороны верны,
// только пока порядки одинаковы. Перестановка одной вкладки уводила бы
// человека не на тот экран — молча, потому что каждый список по
// отдельности выглядит правильным.
//
// Теперь порядок один (`app_tabs.dart`), и разойтись ему негде. Тесты
// ниже держат ровно это: у панели и роутера нет второго источника, а
// признаки вешаются на ИМЯ вкладки, а не на её номер.

void main() {
  test('порядок вкладок описан ровно в одном месте', () {
    // Проверяется не значение, а отсутствие второго списка: копия,
    // сделанная «чтобы не тянуть импорт», и есть исходный дефект.
    final bar = readCode('lib/shared/widgets/custom_tab_bar.dart');
    final router = readCode('lib/navigation/app_router.dart');

    // ПРОВЕРЯЕТСЯ ОБХОД СПИСКА, А НЕ УПОМИНАНИЕ ЕГО ИМЕНИ.
    //
    // Прежде здесь стояло `bar.contains('kAppTabs')`, и обход сторожей
    // 07.08 показал, что этого мало: панель, построенная по
    // `[kAppTabs[1], kAppTabs[0]]`, — то есть с переставленными руками
    // вкладками — упоминание списка сохраняет и проходит насквозь.
    // Сторож ловил ИСХОДНУЮ ФОРМУ дефекта (второй литеральный список) и
    // не ловил его КЛАСС (порядок, собранный где-то ещё).
    expect(
      RegExp(r'for \(final [^)]*\) in kAppTabs(\.indexed)?\)').hasMatch(bar),
      isTrue,
      reason: 'панель перестала обходить kAppTabs целиком и по порядку — '
          'значит порядок снова собирается где-то ещё (N58)',
    );
    expect(
      bar.contains('kAppTabs['),
      isFalse,
      reason: 'панель лезет в список по НОМЕРУ. Любая выборка или '
          'перестановка руками — это второй порядок, только записанный '
          'через первый: расходиться им ничто не мешает',
    );
    expect(
      RegExp(r"\('[^']+',\s*'[A-ZƏİÜÖ]+'\)").hasMatch(bar),
      isFalse,
      reason: 'в панели снова появился собственный список вкладок (N58)',
    );
    expect(
      router.contains('for (final tab in kAppTabs)'),
      isTrue,
      reason: 'ветки роутера перестали строиться из того же списка (N58)',
    );
  });

  test('у каждой вкладки есть экран, и лишних экранов нет', () {
    // Ветка без экрана — чёрный экран вместо вкладки; экран без вкладки —
    // мёртвый код, до которого не дойти.
    final router = readCode('lib/navigation/app_router.dart');
    final mapped = RegExp(r"^\s*'([a-z]+)':\s*\w+\.new,", multiLine: true)
        .allMatches(router)
        .map((m) => m.group(1)!)
        .toSet();
    final ids = kAppTabs.map((t) => t.id).toSet();

    expect(mapped.difference(ids), isEmpty, reason: 'экран без вкладки');
    expect(ids.difference(mapped), isEmpty, reason: 'вкладка без экрана');
  });

  test('признаки вешаются на имя вкладки, а не на её номер (N57)', () {
    // Прежде бейдж непрочитанного стоял на `_kChatsIndex = 8`. Число не
    // могло провалиться ни при какой перестановке: `MainShell` не
    // передавал счётчик вовсе, бейдж не рисовался, и подмена вкладки
    // ничем бы себя не выдала. Код, у которого нет наблюдаемого
    // поведения, не может выдать свою поломку.
    final bar = readCode('lib/shared/widgets/custom_tab_bar.dart');
    expect(
      RegExp(r'_k\w*Index\s*=\s*\d').hasMatch(bar),
      isFalse,
      reason: 'вкладка снова опознаётся номером (N57)',
    );
    // Не `contains('kUnreadBadgeTabId')`: имя есть в файле и от одного
    // импорта. Проверяется СРАВНЕНИЕ — то, ради чего константа заведена.
    expect(
      RegExp(r'==\s*kUnreadBadgeTabId').hasMatch(bar),
      isTrue,
      reason: 'бейдж больше не сверяется с вкладкой по имени константы',
    );
    expect(
      kAppTabs.any((t) => t.id == kUnreadBadgeTabId),
      isTrue,
      reason: 'бейдж повешен на вкладку, которой нет в списке',
    );
  });

  test('имена и пути вкладок не повторяются', () {
    expect(kAppTabs.map((t) => t.id).toSet().length, kAppTabs.length);
    expect(kAppTabs.map((t) => t.path).toSet().length, kAppTabs.length);
  });
}
