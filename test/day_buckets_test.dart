import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/day_buckets.dart';
import 'package:mugam_flutter/core/time/event_local_time.dart';
import 'package:mugam_flutter/firebase/models.dart';

import 'support/source_text.dart';

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
  group('разложение по дням — один проход вместо прохода на каждый день', () {
    final own = [
      ev('a', '2026-08-09T12:00:00.000'),
      ev('b', '2026-08-09T19:00:00.000'),
      ev('c', '2026-08-11T20:04:00.000'),
      ev('cancelled', '2026-08-09T21:00:00.000', status: 'cancelled'),
    ];

    test('складывает мероприятия одного дня вместе', () {
      final byDay = eventsByDay(own: own, asParticipant: const []);
      expect(byDay[DateTime(2026, 8, 9)]?.length, 2);
      expect(byDay[DateTime(2026, 8, 11)]?.length, 1);
    });

    test('отменённые не попадают — правило то же, что у остальных', () {
      final byDay = eventsByDay(own: own, asParticipant: const []);
      final ids = (byDay[DateTime(2026, 8, 9)] ?? []).map((e) => e.id);
      expect(ids, isNot(contains('cancelled')));
    });

    test('пустой день ключа не заводит', () {
      final byDay = eventsByDay(own: own, asParticipant: const []);
      expect(byDay.containsKey(DateTime(2026, 8, 10)), isFalse);
    });

    // ГЛАВНАЯ ИЗ ЧЕТЫРЁХ: сетка месяца спрашивает разложением, а всё
    // остальное — поимённо, и разойдись эти два ответа, кружок на числе
    // снова разъедется с тем, что открывается по нажатию (N74).
    test('разложение и одиночный вопрос дают ОДНО И ТО ЖЕ', () {
      final byDay = eventsByDay(own: own, asParticipant: const []);
      for (final day in [
        DateTime(2026, 8, 9),
        DateTime(2026, 8, 10),
        DateTime(2026, 8, 11),
      ]) {
        final single =
            eventsOfDay(own: own, asParticipant: const [], day: day);
        final fromMap = byDay[day] ?? const <PersonalEvent>[];
        expect(
          single.map((e) => e.id).toList(),
          fromMap.map((e) => e.id).toList(),
          reason: 'день $day: разложение и одиночный вопрос разошлись',
        );
      }
    });
  });


  group('дневной экран подключён и открывается первым (работа 6, вариант А)', () {
    // Наблюдаемого поведения тут проверить нечем без Firebase, поэтому
    // сторож текстовый — но он держит ровно то, что можно потерять
    // молча: экран, написанный и никуда не подключённый, выглядит
    // сделанной работой ровно так же, как подключённый (N57).
    //
    // Смотрит на КОД без комментариев (I12): разбор рядом цитирует то,
    // что проверяется.
    String codeOf(String path) => (const LineSplitter())
        .convert(File(path).readAsStringSync())
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('DayScreen подключён к «Kalendar» и стоит видом по умолчанию', () {
      final screen =
          codeOf('lib/features/agreements/screens/agreements_screen.dart');
      expect(
        // Класс, а не форма записи: первая редакция искала точную строку
        // `const DayScreen()` и упала на верной работе, когда экран
        // обернули в `Expanded`. Сторож, знающий один способ написать то
        // же самое, — это N67 у меня же.
        RegExp(r'\bDayScreen\s*\(').hasMatch(screen),
        isTrue,
        reason: 'дневной экран отключён — он написан, но человек его не '
            'видит, а отличить это от «сделано» нечем',
      );
      // Вид по умолчанию проверяется ПАРОЙ: закладка «Təqvim» открывается
      // первой в шапке, а внутри неё режим — день. Порознь каждая
      // половина ничего не значит: правильная закладка с сеткой месяца и
      // правильный режим на непоказанной закладке одинаково оставляют
      // человека без его вечера.
      expect(
        RegExp(r"_mainView\s*=\s*'calendar'").hasMatch(screen),
        isTrue,
        reason: 'вкладка открывается не календарём',
      );
      expect(
        RegExp(r"_calendarMode\s*=\s*'gun'").hasMatch(screen),
        isTrue,
        reason: 'внутри календаря вид по умолчанию больше не день: открыл '
            '— и не увидел свой вечер, ради чего экран и делался',
      );
    });

    test('день и месяц — ОДНА закладка, переключателем (не четвёртой)', () {
      final screen =
          codeOf('lib/features/agreements/screens/agreements_screen.dart');
      expect(
        screen.contains("view: 'day'"),
        isFalse,
        reason: 'день снова стал четвёртой закладкой в шапке. На трубке '
            'четыре подписи теснятся и разъезжаются по высоте, а день и '
            'месяц — один вопрос на разном расстоянии, им место в одном '
            'переключателе',
      );
      expect(
        RegExp(r"_calendarMode\s*=\s*'gun'").hasMatch(screen),
        isTrue,
        reason: 'закладка «Təqvim» больше не открывается днём — человек '
            'снова попадает на сетку месяца вместо своего вечера',
      );
    });

    test('нажатие на день отвечает ПОД СЕТКОЙ, а не уводит на «Tədbirlər»', () {
      // N68: молчание неотличимо от промаха. Проверяются обе половины —
      // что ответ есть и что он не уносит человека с сетки: в разговоре
      // спрашивают про несколько дат подряд.
      final screen =
          codeOf('lib/features/agreements/screens/agreements_screen.dart');
      // СЧИТАЕТСЯ ВЫЗОВ, А НЕ ОБЪЯВЛЕНИЕ. Первая редакция проверяла
      // `contains('_buildSelectedDayAnswer(')` — и не упала, когда я снял
      // сам вызов из сборки экрана: имя осталось в объявлении метода.
      // Сторож доказывал, что метод НАПИСАН, а нужно — что он ЗОВЁТСЯ.
      // Это ровно тот дефект, ради которого сторож на подключение
      // дневного экрана и заводился, только теперь у меня самого.
      expect(
        '_buildSelectedDayAnswer('.allMatches(screen).length,
        greaterThanOrEqualTo(2),
        reason: 'ответ на выбранный день не вызывается (объявление без '
            'вызова) — пустой день снова молчит',
      );
      final tap = screen.substring(
        screen.indexOf('void _onDayTap('),
        screen.indexOf('void _onDayLongPress('),
      );
      expect(
        tap.contains("_mainView = 'tedbirler'"),
        isFalse,
        reason: 'нажатие на день снова уводит на другую закладку — сетка '
            'уходит с экрана, и следующий вопрос «а 10-го?» начинается '
            'заново',
      );
    });

    test('набора числа с клавиатуры нет — прыжок через список месяцев', () {
      final screen =
          codeOf('lib/features/agreements/screens/agreements_screen.dart');
      expect(
        '_openMonthJump'.allMatches(screen).length,
        greaterThanOrEqualTo(2),
        reason: 'прыжок по месяцам объявлен, но не подключён к заголовку — '
            'до далёкой даты снова только листанием',
      );
    });

    test('файл дневного экрана на месте', () {
      expect(File('lib/features/day/screens/day_screen.dart').existsSync(),
          isTrue);
    });
  });

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

  // N74 — КРУЖОК НА СЕТКЕ И ОТВЕТ ПОД НЕЙ СЧИТАЮТ ОДНИМ ПРАВИЛОМ.
  //
  // Снято на устройстве 07.08: у 9 avqust кружок говорил «4», под сеткой
  // стояли три мероприятия. Оба числа — на одном экране, одновременно.
  // Причина: сетка считала своё («мои» плюс «где я участник», фильтр по
  // дате, длина), не зная ни про отменённые, ни про повторы.
  //
  // Проверяется правило, а не экран: порченый счёт внутри build() не
  // виден ни одному тесту, поэтому он и уехал в core.
  group('мероприятия дня — одно правило для кружка и для ответа (N74)', () {
    final day = DateTime(2026, 8, 9);

    test('отменённое не считается', () {
      final events = eventsOfDay(
        own: [
          ev('живое', '2026-08-09T12:00:00.000'),
          ev('отменённое', '2026-08-09T16:00:00.000', status: 'cancelled'),
        ],
        asParticipant: const [],
        day: day,
      );
      expect(events.length, 1, reason: 'отменённое попало в счёт дня');
      expect(events.single.id, 'живое');
    });

    test('одно мероприятие в обоих списках считается один раз', () {
      // Владелец он же участник — документ приходит дважды. Кружок,
      // считавший длину, показывал бы два.
      final same = ev('одно и то же', '2026-08-09T12:00:00.000');
      final events = eventsOfDay(
        own: [same],
        asParticipant: [same],
        day: day,
      );
      expect(events.length, 1, reason: 'повтор по id не склеен');
    });

    test('чужой день не считается', () {
      final events = eventsOfDay(
        own: [
          ev('девятое', '2026-08-09T12:00:00.000'),
          ev('десятое', '2026-08-10T12:00:00.000'),
        ],
        asParticipant: const [],
        day: day,
      );
      expect(events.map((e) => e.id), ['девятое']);
    });

    test('кружок и ответ под сеткой дают ОДНО число', () {
      // Тот самый случай с устройства, собранный из данных: четыре
      // документа на 9 avqust, из них одно отменено и одно — повтор.
      // Прежде сетка сказала бы «4», ответ — «3». Теперь оба зовут одно
      // правило, и сойтись они обязаны по построению.
      final shared = ev('повтор', '2026-08-09T16:06:00.000');
      final own = [
        ev('первое', '2026-08-09T12:00:00.000'),
        ev('отменённое', '2026-08-09T18:00:00.000', status: 'cancelled'),
        shared,
      ];
      final asParticipant = [shared, ev('третье', '2026-08-09T16:06:00.000')];

      final naCetke = eventsOfDay(
        own: own,
        asParticipant: asParticipant,
        day: day,
      ).length;
      final podSetkoj = buildDayBuckets(
        own: own,
        asParticipant: asParticipant,
        now: day,
      ).today.length;

      expect(naCetke, podSetkoj,
          reason: 'кружок говорит $naCetke, ответ под сеткой $podSetkoj — '
              'ровно расхождение, снятое на устройстве 07.08 (N74)');
      expect(naCetke, 3);
    });
  });
}
