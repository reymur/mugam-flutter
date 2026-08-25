import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/features/job_offer/busy_days.dart';
import 'package:mugam_flutter/firebase/firestore_service.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ПОСТАВЩИК ЗАНЯТОСТИ ДЛЯ СЕТОК ВЫБОРА ДНЯ — `busyDaysProvider`.
//
// Заведён 25.08. Правило «какие сутки заняты» проверяется отдельно
// (`occupied_days_test.dart`); здесь проверяется ВТОРАЯ ПОЛОВИНА, ради которой
// поставщик и заведён: **знаем ли мы ответ вообще.**
//
// Пустая сетка читается как «всё свободно», то есть как утверждение, которого
// мы не делали. Поэтому каждая проверка ниже отвечает на один вопрос: при
// каком состоянии потоков лист имеет право молчать, а при каком обязан сказать
// словами.
//
// ЧЕГО ЭТОТ НАБОР НЕ ПРОВЕРЯЕТ (I50): что листы этот ответ ПОКАЗЫВАЮТ. Дорога
// «поставщик → лист ответа» проверена в `job_offer_sheet_live_test.dart`
// настоящей проводкой; дорога «поставщик → лист набора дней» — сторожем по
// исходникам (`source_invariants_test.dart`), потому что точка вызова
// `proposeJobOffer` тестом не достаётся: она ходит в Auth и в Firestore до
// показа листа.

void main() {
  const me = 'me-uid';
  const other = 'other-uid';

  PersonalEvent event(String id, {String owner = me, String date = '2026-08-25T15:00:00.000'}) =>
      PersonalEvent.fromFirestore(id, {
        'ownerUid': owner,
        'date': date,
        'musicians': const <String>[],
        'answersWrittenByOwner': true,
        'status': 'agreed',
      });

  /// Потоки календаря, ключом — ЧЕЙ календарь. Ключ важен: спросив не того,
  /// поставщик получит пустой поток, и это видно (проверка «спрашивается
  /// календарь того же человека»).
  ProviderContainer withCalendar({
    Map<String, List<PersonalEvent>>? own,
    Map<String, List<PersonalEvent>>? asParticipant,
    bool ownFails = false,
  }) {
    Stream<List<PersonalEvent>> streamFor(
      Map<String, List<PersonalEvent>>? map,
      String uid,
    ) {
      // `null` — поток ещё не ответил. Не пустой список: пустой список это
      // ОТВЕТ «ничего нет», и подменять им молчание значило бы стереть ровно
      // то различие, ради которого написан этот файл.
      if (map == null) return StreamController<List<PersonalEvent>>().stream;
      return Stream.value(map[uid] ?? const <PersonalEvent>[]);
    }

    final container = ProviderContainer(
      overrides: [
        personalEventsProvider.overrideWith((ref, uid) {
          if (ownFails) {
            return Stream<List<PersonalEvent>>.error(
              StateError('нет доступа к календарю'),
            );
          }
          return streamFor(own, uid);
        }),
        eventsAsParticipantProvider.overrideWith(
          (ref, uid) => streamFor(asParticipant, uid),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<BusyDays> busyFor(ProviderContainer container, String uid) async {
    container.listen(busyDaysProvider(uid), (_, _) {});
    await pumpEventQueue();
    return container.read(busyDaysProvider(uid));
  }

  // КАНАРЕЙКА ПЕРВОЙ И БЕЗУСЛОВНАЯ. Без неё все проверки «не знаем» ниже
  // зелены и на поставщике, который не умеет узнать НИЧЕГО: «не знаем» — их
  // ожидаемый ответ, и слепота выглядела бы как успех (I31).
  test('оба потока ответили — занятость известна и доехала', () async {
    final container = withCalendar(
      own: {
        me: [event('e1')],
      },
      asParticipant: const {},
    );

    final busy = await busyFor(container, me);
    expect(busy.known, isTrue);
    expect(busy.days, {'2026-08-25'});
  });

  test('занятых нет — это ОТВЕТ, а не молчание', () async {
    final container = withCalendar(own: const {}, asParticipant: const {});

    final busy = await busyFor(container, me);
    expect(busy.known, isTrue, reason: 'мы посмотрели, и предупреждать не о чем');
    expect(busy.days, isEmpty);
  });

  group('«не знаем» — и лист обязан сказать это словами', () {
    test('свой поток молчит — «не знаем», а не «свободно»', () async {
      final container = withCalendar(own: null, asParticipant: const {});

      final busy = await busyFor(container, me);
      expect(busy.known, isFalse);
      expect(busy.days, isEmpty);
    });

    // ЖДЁМ ОБОИХ, и это не перестраховка. Свои вечера и те, где человек в
    // составе, приходят РАЗНЫМИ запросами; ответь один — половина занятости
    // выглядела бы как вся, и день, занятый чужим вечером, показался бы
    // свободным. Тот же довод дословно стоит в `agreements_screen.dart:3702`.
    test('второй поток молчит — «не знаем», хотя первый уже ответил', () async {
      final container = withCalendar(
        own: {
          me: [event('e1')],
        },
        asParticipant: null,
      );

      final busy = await busyFor(container, me);
      expect(busy.known, isFalse);
      expect(
        busy.days,
        isEmpty,
        reason: 'половина занятости не отдаётся как вся',
      );
    });

    // ОТКАЗ СЛИТ С ЗАГРУЗКОЙ НАМЕРЕННО (решение владельца 25.08): отдельная
    // строка на отказ объясняла бы человеку нашу поломку, а не его дело.
    // Сторона слияния безопасная — «не знаем», а не «свободно».
    test('поток отказал — «не знаем», а не «свободно»', () async {
      final container = withCalendar(
        own: const {},
        asParticipant: const {},
        ownFails: true,
      );

      final busy = await busyFor(container, me);
      expect(busy.known, isFalse);
      expect(busy.days, isEmpty);
    });

    // ТОТ САМЫЙ ОТДЕЛЬНЫЙ ТЕСТ (требование владельца 25.08).
    //
    // `viewerUid` в листе предложения имеет третью ветвь `''`
    // (`job_offer_sheet.dart:266-269`), и она переворачивает замысел молча.
    // `dayRoleOf` при пустом uid считает занятым ВСЁ — ложная тревога, видная
    // сразу. Но запрос `where('ownerUid', isEqualTo: '')` вернул бы НОЛЬ
    // документов, и на выходе вышел бы пустой набор с видом «знаем: всё
    // свободно» — то есть ровно наоборот, тихо и в опасную сторону.
    //
    // Потоки здесь ОТВЕЧАЮТ (пустым списком, как ответил бы Firestore на
    // пустой uid) — иначе проверка прошла бы по причине «поток молчит» и не
    // сказала бы ничего про сам пустой uid.
    test('пустой uid — «не знаем», а не «свободно»', () async {
      final container = withCalendar(own: const {}, asParticipant: const {});

      final busy = await busyFor(container, '');
      expect(
        busy.known,
        isFalse,
        reason: 'спрашивать не за кого — значит не знаем, а не «свободен»',
      );
      expect(busy.days, isEmpty);
    });
  });

  // Занятость — свойство ЧЕЛОВЕКА, и спросить надо его календарь. Проверка
  // держится на том, что у чужого ключа поток пуст: спроси поставщик не того,
  // ответ был бы «занятых нет» — то есть неправдой, неотличимой от правды.
  test('спрашивается календарь ТОГО ЖЕ человека', () async {
    final container = withCalendar(
      own: {
        other: [event('e1', owner: other)],
      },
      asParticipant: const {},
    );

    final mine = await busyFor(container, me);
    expect(mine.known, isTrue);
    expect(mine.days, isEmpty, reason: 'чужая занятость не моя');

    final theirs = await busyFor(container, other);
    expect(theirs.days, {'2026-08-25'}, reason: 'канарейка: событие вообще есть');
  });
}
