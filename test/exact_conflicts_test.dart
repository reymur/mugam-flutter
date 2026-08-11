import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/firebase/models.dart';
import 'package:mugam_flutter/shared/widgets/event_conflict_banner.dart';

// N51 — совпадение минута в минуту показывает ВСЕХ, кто её занял.
//
// Наблюдалось 07.08 на устройстве: на 12 августа в 18:00 стояли своё
// мероприятие и чужое, где человек участник, — окно назвало одно и
// промолчало про второе. Человек уходит с экрана уверенным, что вечер
// занят одним делом, а ждут его в двух местах.
//
// Пряталось при этом систематически ЧУЖОЕ: перечень собирается как
// `[...свои, ...где я участник]`, и при равном времени вперёд выходит
// своё. То есть невидимым становилось ровно то мероприятие, где человека
// ждёт кто-то другой.
//
// ПОЧЕМУ ЭТИ СЛУЧАИ ПЕРЕЖИЛИ ШАГ 4 БЕЗ ПРАВКИ СМЫСЛА. С шага 4 занятость
// считается по ответу, а не по составу, — но события здесь строятся
// конструктором, то есть БЕЗ карты `answers`, и для них работает запасной
// путь: карты нет — «есть в составе» означает «идёт». Это ровно поведение
// 75 записей прода на 10.08, поэтому проверки N51 остались о том же, о чём
// были. Случаи с картой живут в `event_conflict_test.dart`.

const me = 'me-uid';
const other = 'other-uid';

PersonalEvent _ev(
  String id,
  String date, {
  String owner = me,
  List<String> people = const [],
  String status = 'agreed',
}) =>
    PersonalEvent(
      id: id,
      ownerUid: owner,
      date: date,
      type: 'Toy',
      location: '',
      notes: '',
      participantUids: people,
      isAgree: true,
      status: status,
    );

// Порядок как в форме: сначала свои, потом те, где человек участник.
// Именно он и решал, кого показать, когда показывали одного.
final _own = _ev('own', '2026-08-12T18:00:00.000');
final _foreign = _ev('foreign', '2026-08-12T18:00:00.000',
    owner: other, people: const [me]);
final _third = _ev('third', '2026-08-12T18:00:00.000',
    owner: other, people: const [me]);

void main() {
  group('два на одну минуту', () {
    test('возвращаются ОБА, а не первое', () {
      final got = exactConflictsAt(
        DateTime(2026, 8, 12, 18, 0),
        [_own, _foreign],
        currentUid: me,
      );
      expect(got.length, 2);
      expect(got.map((e) => e.id), containsAll(<String>['own', 'foreign']));
    });

    test('чужое не теряется независимо от порядка в перечне', () {
      // Порядок перечня — не свойство данных, а способ их сборки. Правило
      // обязано не зависеть от него вовсе: до починки именно он и решал,
      // кого человек увидит.
      final a = exactConflictsAt(DateTime(2026, 8, 12, 18, 0), [_own, _foreign],
          currentUid: me);
      final b = exactConflictsAt(DateTime(2026, 8, 12, 18, 0), [_foreign, _own],
          currentUid: me);
      expect(a.map((e) => e.id).toSet(), b.map((e) => e.id).toSet());
      expect(a.any((e) => e.id == 'foreign'), isTrue);
      expect(b.any((e) => e.id == 'foreign'), isTrue);
    });

    test('плашка называет число, а не молчит о нём', () {
      final spec = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 12, 18, 0),
        events: [_own, _foreign],
        currentUid: me,
      );
      expect(spec, isNotNull);
      expect(spec!.events.length, 2);
      expect(spec.title, contains('2'));
    });
  });

  group('три на одну минуту', () {
    test('возвращаются все три', () {
      final got = exactConflictsAt(
        DateTime(2026, 8, 12, 18, 0),
        [_own, _foreign, _third],
        currentUid: me,
      );
      expect(got.length, 3);
    });

    test('плашка перечисляет все три и называет число', () {
      final spec = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 12, 18, 0),
        events: [_own, _foreign, _third],
        currentUid: me,
      );
      expect(spec!.events.length, 3);
      expect(spec.title, contains('3'));
    });
  });

  group('разбор одного не освобождает минуту', () {
    test('после ухода из чужого остаётся своё — минута занята', () {
      // Главный случай пятого пункта. До починки он был недостижим: в
      // диалог уходило одно мероприятие, и «разобрал одно» означало
      // «разобрал все».
      final left = exactConflictsAt(
        DateTime(2026, 8, 12, 18, 0),
        [_own, _foreign],
        currentUid: me,
        resolvedIds: const {'foreign'},
      );
      expect(left.length, 1);
      expect(left.single.id, 'own');
    });

    test('когда разобраны все — минута свободна', () {
      final left = exactConflictsAt(
        DateTime(2026, 8, 12, 18, 0),
        [_own, _foreign],
        currentUid: me,
        resolvedIds: const {'foreign', 'own'},
      );
      expect(left, isEmpty);
    });

    test('разобранное не всплывает и в плашке', () {
      // Иначе человек чинит конфликт, а предупреждение продолжает
      // говорить о нём: список данных обновится только после закрытия
      // формы, и до тех пор экран противоречил бы сам себе.
      final spec = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 12, 18, 0),
        events: [_own, _foreign],
        currentUid: me,
        resolvedIds: const {'foreign'},
      );
      expect(spec!.events.map((e) => e.id), ['own']);
      expect(spec.title, isNot(contains('2')));
    });

    test('разобранное не мешает и счёту занятого ДНЯ', () {
      final spec = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 12, 15, 0),
        events: [_own, _foreign],
        currentUid: me,
        resolvedIds: const {'foreign'},
      );
      expect(spec!.events.map((e) => e.id), ['own']);
    });
  });
}
