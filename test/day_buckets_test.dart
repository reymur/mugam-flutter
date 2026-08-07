import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/day_buckets.dart';
import 'package:mugam_flutter/core/time/event_local_time.dart';
import 'package:mugam_flutter/firebase/models.dart';

// Главный экран как ДЕНЬ (работа 6 плана).
//
// Проверяется правило раскладки, а не экран: порченое правило внутри
// build() не видно ни одному тесту, поэтому оно и вынесено в core.

PersonalEvent ev(String id, String date, {String status = 'agreed'}) {
  return PersonalEvent(
    id: id,
    ownerUid: 'me',
    date: date,
    type: 'Toy',
    location: 'Bakı',
    notes: '',
    participantUids: const [],
    isAgree: true,
    status: status,
  );
}

void main() {
  // Полдень намеренно: раскладка не должна зависеть от того, в какой час
  // суток человек открыл приложение.
  final now = DateTime(2026, 8, 7, 12, 0);

  group('раскладка по дням', () {
    test('сегодня, завтра и неделя расходятся по своим местам', () {
      final b = buildDayBuckets(
        own: [
          ev('t1', '2026-08-07T20:00:00.000'),
          ev('t2', '2026-08-08T19:00:00.000'),
          ev('t3', '2026-08-12T18:00:00.000'),
        ],
        asParticipant: const [],
        now: now,
      );
      expect(b.today.map((e) => e.id), ['t1']);
      expect(b.tomorrow.map((e) => e.id), ['t2']);
      expect(b.week.length, 7, reason: 'неделя — всегда семь строк');
      expect(
        b.week.expand((d) => d.events).map((e) => e.id),
        ['t3'],
      );
      expect(b.next, isNull);
    });

    test('внутри дня — по времени, а не по порядку прихода', () {
      final b = buildDayBuckets(
        own: [
          ev('поздний', '2026-08-07T22:00:00.000'),
          ev('ранний', '2026-08-07T10:00:00.000'),
          ev('дневной', '2026-08-07T15:00:00.000'),
        ],
        asParticipant: const [],
        now: now,
      );
      expect(b.today.map((e) => e.id), ['ранний', 'дневной', 'поздний']);
    });

    test('края суток: 00:01 сегодня и 23:59 сегодня — оба сегодня', () {
      // Час внутри суток не должен выталкивать мероприятие в соседний
      // день: сравниваются СУТКИ, а не моменты.
      final b = buildDayBuckets(
        own: [
          ev('едва начался день', '2026-08-07T00:01:00.000'),
          ev('поздний вечер', '2026-08-07T23:59:00.000'),
        ],
        asParticipant: const [],
        now: now,
      );
      expect(b.today.length, 2);
      expect(b.tomorrow, isEmpty);
    });

    test('23:59 вчера — не показывается вовсе, день смотрит вперёд', () {
      final b = buildDayBuckets(
        own: [ev('вчерашний', '2026-08-06T23:59:00.000')],
        asParticipant: const [],
        now: now,
      );
      expect(b.today, isEmpty);
      expect(b.weekHasNothing, isTrue);
      expect(b.next, isNull);
    });

    test('семь дней вперёд, а не до конца календарной недели', () {
      // 07.08.2026 — пятница. «До конца недели» опустошило бы экран в
      // воскресенье при полном календаре; окно считается от завтра.
      final b = buildDayBuckets(
        own: [
          ev('через неделю', '2026-08-15T18:00:00.000'),
          ev('на границе', '2026-08-15T23:00:00.000'),
          ev('за границей', '2026-08-16T18:00:00.000'),
        ],
        asParticipant: const [],
        now: now,
      );
      expect(
        b.week.expand((d) => d.events).map((e) => e.id),
        ['через неделю', 'на границе'],
      );
      expect(b.next?.id, 'за границей');
    });

    test('ближайшее за окном названо, чтобы пустой экран не молчал', () {
      final b = buildDayBuckets(
        own: [
          ev('сентябрьский', '2026-09-09T18:00:00.000'),
          ev('октябрьский', '2026-10-01T18:00:00.000'),
        ],
        asParticipant: const [],
        now: now,
      );
      expect(b.next?.id, 'сентябрьский',
          reason: 'названо не первое попавшееся, а ближайшее');
    });
  });

  group('что выбрасывается', () {
    test('дедуп по id: хозяин и участник — один вечер, а не два', () {
      // ДВА РАЗНЫХ ОБЪЕКТА с одним id — так и приходит из Firestore: два
      // потока разбирают один документ каждый по себе. Первая редакция
      // теста подавала ОДИН объект в оба списка, и тогда дедуп проходил
      // бы при любом ключе, включающем тождество, — проверка не могла
      // провалиться (I9). Поймано возвратом: снятие дедупа не уронило
      // ни одного теста.
      final b = buildDayBuckets(
        own: [ev('один', '2026-08-07T20:00:00.000')],
        asParticipant: [ev('один', '2026-08-07T20:00:00.000')],
        now: now,
      );
      expect(b.today.length, 1);
      expect(b.today.single.id, 'один');
    });

    test('отменённое не показывается', () {
      final b = buildDayBuckets(
        own: [ev('отменён', '2026-08-07T20:00:00.000', status: 'cancelled')],
        asParticipant: const [],
        now: now,
      );
      expect(b.today, isEmpty);
    });

    test('нечитаемая дата выбрасывается, а НЕ падает в «сегодня»', () {
      // Иначе испорченная строка притворилась бы сегодняшним вечером —
      // неправда ровно на том экране, ради правдивости которого он и
      // переписывается.
      final b = buildDayBuckets(
        own: [ev('битый', 'позавчера'), ev('пустой', '')],
        asParticipant: const [],
        now: now,
      );
      expect(b.today, isEmpty);
      expect(b.isEmpty, isTrue);
    });
  });

  group('Z-даты попадают в ПРАВИЛЬНЫЙ день (условие правильности экрана)', () {
    test('момент в UTC приводится к местному времени', () {
      // 13 записей прода из 72 хранят дату с `Z`. Без приведения `.hour`
      // даёт час по Гринвичу — в Баку это −4 часа, и вечернее
      // мероприятие уезжает в чужие сутки.
      final local = eventLocalDateTime('2026-06-30T05:41:41.000Z');
      final asFloating = DateTime.parse('2026-06-30T05:41:41.000Z');
      expect(local!.isUtc, isFalse);
      expect(local, asFloating.toLocal());
    });

    test('плавающее время НЕ трогается — toy в 16:00 остаётся в 16:00', () {
      final d = eventLocalDateTime('2026-08-28T16:00:00.000')!;
      expect(d.hour, 16);
      expect(d.isUtc, isFalse);
    });

    test('микросекунды разбираются, а не отбрасывают запись', () {
      expect(eventLocalDateTime('2026-07-29T18:12:37.122341'), isNotNull);
    });

    test('нечитаемое даёт null, а не «сегодня»', () {
      expect(eventLocalDateTime('позавчера'), isNull);
      expect(eventLocalDateTime(''), isNull);
      expect(eventDay('позавчера'), isNull);
    });

    test('показ и раскладка берут время из ОДНОГО места', () {
      // Разойдись они — человек увидел бы карточку под заголовком
      // «Sabah» со временем сегодняшнего вечера, и каждая сторона по
      // отдельности выглядела бы правильной (N58).
      const iso = '2026-06-30T21:00:00.000Z';
      final day = eventDay(iso)!;
      final time = eventLocalDateTime(iso)!;
      expect(day, DateTime(time.year, time.month, time.day));
    });
  });

  group('пустой день внутри недели и пустая неделя — РАЗНЫЕ состояния', () {
    // Требование владельца 07.08: второе не должно собираться из семи
    // первых. «Этот день свободен» — сведение об одном дне; «впереди
    // неделя пустая» — сведение обо всей неделе, и экран отвечает на них
    // по-разному. Семь строк «boş» подряд — не ответ, а семикратно
    // повторённое молчание. Тест на каждое ПОРОЗНЬ.

    test('пустой день ВНУТРИ занятой недели — строка есть и она пустая', () {
      final b = buildDayBuckets(
        own: [
          ev('в понедельник', '2026-08-10T19:00:00.000'),
          ev('в среду', '2026-08-12T19:00:00.000'),
        ],
        asParticipant: const [],
        now: now,
      );
      expect(b.week.length, 7);
      expect(b.weekHasNothing, isFalse, reason: 'неделя не пуста');

      final tuesday =
          b.week.firstWhere((d) => d.day == DateTime(2026, 8, 11));
      expect(tuesday.isEmpty, isTrue,
          reason: '11 августа свободно — строка обязана быть и быть пустой');

      // И ровно один пустой день не делает неделю пустой.
      expect(b.week.where((d) => d.isEmpty).length, 5);
    });

    test('ПУСТАЯ НЕДЕЛЯ — своё состояние, а не семь пустых дней', () {
      final b = buildDayBuckets(
        own: [ev('сегодня', '2026-08-07T20:00:00.000')],
        asParticipant: const [],
        now: now,
      );
      expect(b.weekHasNothing, isTrue);
      // Строки при этом НЕ исчезают: правило отдаёт факт, а решение
      // рисовать ли семь «boş» — за экраном.
      expect(b.week.length, 7);
      expect(b.week.every((d) => d.isEmpty), isTrue);
    });

    test('одно мероприятие в неделе — уже не пустая неделя', () {
      // Граница между двумя состояниями: она проходит по ОДНОМУ
      // мероприятию, а не по большинству дней.
      final b = buildDayBuckets(
        own: [ev('единственное', '2026-08-14T19:00:00.000')],
        asParticipant: const [],
        now: now,
      );
      expect(b.weekHasNothing, isFalse);
      expect(b.week.where((d) => d.isEmpty).length, 6);
    });

    test('дни идут подряд и по порядку, без пропусков', () {
      final b = buildDayBuckets(own: const [], asParticipant: const [], now: now);
      final days = b.week.map((d) => d.day).toList();
      expect(days.first, DateTime(2026, 8, 9), reason: 'первый день — послезавтра');
      expect(days.last, DateTime(2026, 8, 15));
      for (var i = 1; i < days.length; i++) {
        expect(days[i].difference(days[i - 1]).inDays, 1,
            reason: 'в списке пропущен день — человеку пришлось бы считать '
                'даты в уме');
      }
    });

    test('несколько мероприятий в одном дне — все в его строке, по времени', () {
      final b = buildDayBuckets(
        own: [
          ev('вечер', '2026-08-09T20:00:00.000'),
          ev('утро', '2026-08-09T09:00:00.000'),
        ],
        asParticipant: const [],
        now: now,
      );
      final day = b.week.firstWhere((d) => d.day == DateTime(2026, 8, 9));
      expect(day.events.map((e) => e.id), ['утро', 'вечер']);
    });
  });

  group('пустой день отвечает, а не молчит', () {
    DayBuckets buckets(List<PersonalEvent> events) => buildDayBuckets(
          own: events,
          asParticipant: const [],
          now: now,
        );

    test('сегодня пусто, завтра есть — «Bu gün boşsunuz»', () {
      final b = buckets([ev('завтра', '2026-08-08T19:00:00.000')]);
      expect(emptyDayAnswer(b), EmptyDayAnswer.freeToday);
    });

    test('сегодня и завтра пусто, дальше есть — назван оба дня', () {
      final b = buckets([ev('в среду', '2026-08-12T19:00:00.000')]);
      expect(emptyDayAnswer(b), EmptyDayAnswer.freeBothDays);
    });

    test('пусто и за окном недели — тоже «оба дня», ближайшее названо', () {
      final b = buckets([ev('в сентябре', '2026-09-09T19:00:00.000')]);
      expect(emptyDayAnswer(b), EmptyDayAnswer.freeBothDays);
      expect(b.next?.id, 'в сентябре');
    });

    test('впереди нет ничего — «Təqvim boşdur»', () {
      expect(emptyDayAnswer(buckets(const [])), EmptyDayAnswer.calendarEmpty);
    });

    test('есть дела сегодня — отвечать нечего', () {
      final b = buckets([ev('сегодня', '2026-08-07T20:00:00.000')]);
      expect(emptyDayAnswer(b), EmptyDayAnswer.hasEventsToday);
    });

    test('прошедшее не делает календарь непустым', () {
      // Иначе человек с одним прошлогодним мероприятием никогда не
      // увидел бы «Təqvim boşdur» и не понял бы, что добавить нечего.
      final b = buckets([ev('в прошлом', '2026-01-01T19:00:00.000')]);
      expect(emptyDayAnswer(b), EmptyDayAnswer.calendarEmpty);
    });
  });
}
