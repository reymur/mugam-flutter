import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/calendar_filter.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ШАГ 5 — вкладка «Müqavilələr» становится фильтром календаря.
//
// СВЕРКА ИДЁТ СОСТАВОМ, А НЕ ЧИСЛОМ (I13). «27 против 27» верно и тогда,
// когда один договор потерян, а вместо него затесался посторонний;
// равенство множеств само называет, кого не хватает. Поэтому здесь всюду
// сравниваются наборы id, и там, где сравнивается число, оно стоит РЯДОМ с
// составом, а не вместо него.

PersonalEvent _ev(String id, {required bool isAgree}) => PersonalEvent(
      id: id,
      ownerUid: 'owner',
      date: '2026-08-12T19:00:00.000',
      type: 'Toy',
      location: '',
      notes: '',
      participantUids: const [],
      isAgree: isAgree,
    );

void main() {
  final agree1 = _ev('a1', isAgree: true);
  final agree2 = _ev('a2', isAgree: true);
  final plain1 = _ev('p1', isAgree: false);
  final plain2 = _ev('p2', isAgree: false);
  final all = [agree1, plain1, agree2, plain2];

  group('фильтр отбирает тем же признаком, что вкладка', () {
    test('«только договоры» даёт РОВНО договоры, поимённо', () {
      final got = applyCalendarFilter(all, CalendarFilter.agreements);
      expect(got.map((e) => e.id).toSet(), {'a1', 'a2'});
    });

    test('РАЗНОСТЬ В ОБЕ СТОРОНЫ ПУСТА — так и проверяем, а не «совпало»', () {
      // Та же форма, которой сверяется прод: множество из вкладки против
      // множества из фильтра. Одна разность пуста и при потере, если
      // одновременно что-то лишнее добавилось, — поэтому обе.
      final fromTab = all.where((e) => e.isAgree).map((e) => e.id).toSet();
      final fromFilter = applyCalendarFilter(all, CalendarFilter.agreements)
          .map((e) => e.id)
          .toSet();
      expect(fromTab.difference(fromFilter), isEmpty,
          reason: 'есть во вкладке, нет в фильтре');
      expect(fromFilter.difference(fromTab), isEmpty,
          reason: 'есть в фильтре, нет во вкладке');
    });

    test('«всё» не теряет и не переставляет — тот же список', () {
      final got = applyCalendarFilter(all, CalendarFilter.all);
      expect(got.map((e) => e.id).toList(), ['a1', 'p1', 'a2', 'p2']);
    });

    test('сумма держится: договоры плюс обычные — это всё', () {
      // Третье место, где число проверяется арифметикой между двумя другими
      // (I13): два правдоподобных числа ловятся только сложением.
      final agree = applyCalendarFilter(all, CalendarFilter.agreements);
      final plain = all.where((e) => !e.isAgree).toList();
      expect(agree.length + plain.length, all.length);
      expect(
        {...agree.map((e) => e.id), ...plain.map((e) => e.id)},
        all.map((e) => e.id).toSet(),
      );
    });

    test('пустой вход даёт пустой выход, а не выдумку', () {
      expect(applyCalendarFilter(const [], CalendarFilter.agreements), isEmpty);
      expect(applyCalendarFilter(const [], CalendarFilter.all), isEmpty);
    });
  });

  group('надписи', () {
    test('у каждого положения своё слово, и они разные', () {
      final labels = CalendarFilter.values.map(calendarFilterLabel).toList();
      expect(labels.where((s) => s.isEmpty), isEmpty);
      expect(labels.toSet().length, CalendarFilter.values.length);
    });

    test('слово «договор» пока ЕСТЬ — оно уйдёт после сверки, не вместе с ней',
        () {
      // Проверка стоит нарочно: пока фильтр сверяют с вкладкой, он обязан
      // называться тем же словом. Уберут слово раньше сверки — эта проверка
      // покраснеет и напомнит порядок.
      expect(calendarFilterLabel(CalendarFilter.agreements), 'Müqavilələr');
    });
  });
}
