import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/core/agreements/occupied_days.dart';
import 'package:mugam_flutter/firebase/models.dart';

// КАКИЕ СУТКИ ЧЕЛОВЕКА ЗАНЯТЫ — правило `occupiedDaysOf`.
//
// Заведено 25.08 работой «занятость в листах предложения». Своего в правиле
// только сборка, и потому тесты здесь проверяют СБОРКУ: что взяты все три
// готовых решения и что ни одно не потеряно по дороге. Каждое из трёх
// проверено и у себя дома — `day_role_test.dart`, `day_buckets_test.dart`, — и
// повторять там доказанное здесь незачем.
//
// СОБЫТИЕ СТРОИТСЯ ЧЕРЕЗ `fromFirestore`, А НЕ КОНСТРУКТОРОМ: карта ответов у
// модели закрыта (`_answers`), передать её снаружи `models.dart` нельзя вовсе,
// и единственная дорога внутрь — документ. То есть ровно тот путь, которым
// ответы приходят в проде (I55).

void main() {
  const me = 'me-uid';
  const other = 'other-uid';

  PersonalEvent event(
    String id, {
    String owner = other,
    String date = '2026-08-25T15:00:00.000',
    List<String> musicians = const [],
    Map<String, String>? answers,
    String status = 'agreed',
  }) => PersonalEvent.fromFirestore(id, {
    'ownerUid': owner,
    'date': date,
    'musicians': musicians,
    if (answers != null) 'answers': answers,
    'answersWrittenByOwner': true,
    'status': status,
  });

  Set<DateTime> daysOf({
    List<PersonalEvent> own = const [],
    List<PersonalEvent> asParticipant = const [],
    String uid = me,
  }) => occupiedDaysOf(own: own, asParticipant: asParticipant, uid: uid);

  group('что занимает сутки, а что нет', () {
    test('свой вечер занимает день', () {
      expect(
        daysOf(own: [event('e1', owner: me)]),
        {DateTime(2026, 8, 25)},
      );
    });

    test('согласие занимает день', () {
      expect(
        daysOf(
          asParticipant: [
            event(
              'e1',
              musicians: const [other, me],
              answers: const {other: kAnswerGoing, me: kAnswerGoing},
            ),
          ],
        ),
        {DateTime(2026, 8, 25)},
      );
    });

    // ПОЛОВИНА ВСЕЙ РАБОТЫ ИМЕННО ЗДЕСЬ: приглашение чужой календарь не
    // занимает (решение владельца 11.08, N112). Возьми правило по составу —
    // и музыканту красились бы дни, на которые его только зовут, то есть
    // приложение решало бы за него ещё до его ответа.
    test('приглашение день НЕ занимает', () {
      expect(
        daysOf(
          asParticipant: [
            event(
              'e1',
              musicians: const [other, me],
              answers: const {other: kAnswerGoing, me: kAnswerWaiting},
            ),
          ],
        ),
        isEmpty,
      );
    });

    test('отказ день не занимает', () {
      expect(
        daysOf(
          asParticipant: [
            event(
              'e1',
              musicians: const [other, me],
              answers: const {other: kAnswerGoing, me: kAnswerCant},
            ),
          ],
        ),
        isEmpty,
      );
    });

    test('чужой вечер без меня в составе день не занимает', () {
      expect(daysOf(asParticipant: [event('e1')]), isEmpty);
    });

    test('отменённый вечер день не занимает', () {
      expect(
        daysOf(own: [event('e1', owner: me, status: 'cancelled')]),
        isEmpty,
        reason: 'отменённый договор времени человека уже не занимает',
      );
    });
  });

  group('сборка: сутки, а не вечера', () {
    // Свой вечер приходит ОБОИМИ потоками — владелец числится и в своём
    // составе. Без дедупа по `id` набор дней остался бы верным по составу, и
    // потому эта проверка стоит на ЧИСЛЕ, а не на содержимом: она сторожит
    // то, что дедуп вообще есть, на случай, если однажды здесь появится
    // список вечеров.
    test('один вечер из обоих потоков даёт одни сутки', () {
      final e = event('e1', owner: me, musicians: const [me]);
      expect(daysOf(own: [e], asParticipant: [e]).length, 1);
    });

    test('два вечера в один день — одни сутки', () {
      expect(
        daysOf(
          own: [
            event('e1', owner: me, date: '2026-08-25T15:00:00.000'),
            event('e2', owner: me, date: '2026-08-25T21:00:00.000'),
          ],
        ),
        {DateTime(2026, 8, 25)},
      );
    });

    test('вечера разных дней дают разные сутки', () {
      expect(
        daysOf(
          own: [
            event('e1', owner: me, date: '2026-08-25T15:00:00.000'),
            event('e2', owner: me, date: '2026-08-27T15:00:00.000'),
          ],
        ),
        {DateTime(2026, 8, 25), DateTime(2026, 8, 27)},
      );
    });

    test('нечитаемая дата выбрасывается, а не падает в сегодня', () {
      expect(daysOf(own: [event('e1', owner: me, date: 'позавчера')]), isEmpty);
      expect(daysOf(own: [event('e2', owner: me, date: '')]), isEmpty);
    });
  });

  // ЗАЧЕМ ЭТОТ РАЗДЕЛ ОТДЕЛЬНО: `conflictEventsOnDay` — второе место, которое
  // задаёт тот же вопрос, — берёт голый `DateTime.parse` и сравнивает поля.
  // На записях с `Z` это сутки по Гринвичу. Здесь разбор другой, и проверка
  // стоит затем, чтобы «поправить как у соседа» не прошло молча (N161).
  group('Z-дата ложится в МЕСТНЫЕ сутки', () {
    test('момент в UTC не уезжает в чужой день', () {
      // Час взят ранний нарочно: при поясе восточнее Гринвича местная ночь
      // приходится на ПРЕДЫДУЩИЕ сутки UTC, и разбор без приведения к
      // местному времени ошибётся на день. В Баку (+04) так и есть.
      final localMoment = DateTime(2026, 8, 25, 1, 0);
      final iso = localMoment.toUtc().toIso8601String();
      expect(iso.endsWith('Z'), isTrue, reason: 'строка обязана быть с Z');

      final days = daysOf(own: [event('e1', owner: me, date: iso)]);
      expect(days, {DateTime(2026, 8, 25)});

      // ВТОРАЯ ПОЛОВИНА ПРОВЕРКИ ЕСТЬ НЕ ВЕЗДЕ, и это сказано прямо (I50):
      // на машине, стоящей в UTC, местные и гринвичские сутки совпадают, и
      // отличить один разбор от другого нечем в принципе. Где различие есть —
      // оно проверяется.
      final naive = DateTime.parse(iso);
      final naiveDay = DateTime(naive.year, naive.month, naive.day);
      if (naiveDay != DateTime(2026, 8, 25)) {
        expect(
          days,
          isNot(contains(naiveDay)),
          reason: 'сутки взяты по Гринвичу: разбор потерял приведение к '
              'местному времени (смещение машины '
              '${localMoment.timeZoneOffset.inHours} ч)',
        );
      }
    });

    test('плавающее время не трогается — вечер в 15:00 остаётся в своём дне', () {
      expect(
        daysOf(own: [event('e1', owner: me, date: '2026-08-25T15:00:00.000')]),
        {DateTime(2026, 8, 25)},
      );
    });
  });

  // ЧЕМ ИМЕННО ЗАНЯТ ДЕНЬ — вторая форма того же ответа, заведена 25.08:
  // сетка красит день предупредительно, и человек вправе спросить «чем?».
  group('вечера дня, а не только дни', () {
    test('вечер назван сам, а не только его дата', () {
      final byDay = occupiedEventsByDayOf(
        own: [event('e1', owner: me)],
        asParticipant: const [],
        uid: me,
      );
      expect(byDay[DateTime(2026, 8, 25)]!.single.id, 'e1');
    });

    // ВСЕ, А НЕ ПЕРВЫЙ (N51/I11). Два вечера в один день — обычная жизнь;
    // отдай мы один, второй пропал бы молча, и сигнатура скрыла бы это лучше,
    // чем `.first`.
    test('два вечера в один день — оба, и по времени', () {
      final byDay = occupiedEventsByDayOf(
        own: [
          event('поздний', owner: me, date: '2026-08-25T21:00:00.000'),
          event('ранний', owner: me, date: '2026-08-25T15:00:00.000'),
        ],
        asParticipant: const [],
        uid: me,
      );
      expect(
        byDay[DateTime(2026, 8, 25)]!.map((e) => e.id).toList(),
        ['ранний', 'поздний'],
        reason: 'порядок по времени — тот же, что у списка дня и пометки '
            'месяца, чтобы человек видел вечера одинаково везде',
      );
    });

    // ДНИ ВЫВЕДЕНЫ ИЗ ВЕЧЕРОВ, А НЕ СЧИТАНЫ ОТДЕЛЬНО. Два прохода разошлись
    // бы молча: набор сказал бы «занято», список оказался бы пуст.
    test('дни и вечера не расходятся — у каждого дня есть чем', () {
      final args = {
        'own': [
          event('e1', owner: me, date: '2026-08-25T15:00:00.000'),
          event('e2', owner: me, date: '2026-08-27T15:00:00.000'),
        ],
      };
      final days = occupiedDaysOf(
        own: args['own']!,
        asParticipant: const [],
        uid: me,
      );
      final byDay = occupiedEventsByDayOf(
        own: args['own']!,
        asParticipant: const [],
        uid: me,
      );
      expect(days, byDay.keys.toSet());
      for (final day in days) {
        expect(byDay[day], isNotEmpty);
      }
    });
  });

  group('края', () {
    // ПУСТОЙ ОТВЕТ ЗДЕСЬ ЗАКОННЫЙ И ЗНАЧИТ «ЗАНЯТЫХ НЕТ». Отличать его от
    // «мы не смотрели» это правило не умеет и не должно: на входе у него уже
    // готовые списки. Вопрос решается там, где видно состояние потоков —
    // `busyDaysProvider`, и на это есть свои проверки.
    test('пустые списки — пустой ответ', () {
      expect(daysOf(), isEmpty);
    });

    // Пустой uid `dayRoleOf` считает занятым ВСЁ — намеренно, это ложная
    // тревога, видная в тот же миг (`day_role.dart:181`). Проверка стоит не
    // ради поведения, а ради того, чтобы никто не «починил» его на
    // «свободен»: тихое освобождение календаря выглядит как порядок.
    test('пустой uid занимает всё — громко, а не тихо', () {
      expect(daysOf(own: [event('e1')], uid: ''), {DateTime(2026, 8, 25)});
    });
  });
}
