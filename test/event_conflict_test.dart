import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/firebase/models.dart';
import 'package:mugam_flutter/shared/widgets/event_conflict_banner.dart';

// Правила конфликта — общие у листа «İş təklif et» и календарного окна.
// Смысл общего кода здесь ровно в том, что оба экрана отвечают одинаково,
// и это закрепляется тестом, а не подразумевается: разойдись правило,
// ошибки не возникнет нигде — просто один экран промолчит там, где другой
// предупредит. Ровно так они и разошлись до 03.08, и заметил это человек
// глазами, а не код.

// ЧЕЙ ЭТО КАЛЕНДАРЬ. Все события ниже принадлежат `_me` — так было и до
// шага 4, просто спрашивать было некому: занятость стояла на составе, а не
// на ответе. Теперь у правила есть адресат, и он назван именем, чтобы в
// каждом вызове не гадать, откуда взялась строка.
const String _me = 'u1';
const String _other = 'u2';

PersonalEvent _ev(
  String id,
  String date, {
  String type = 'Toy',
  String location = '',
  String status = 'agreed',
}) => PersonalEvent(
  id: id,
  ownerUid: _me,
  date: date,
  type: type,
  location: location,
  notes: '',
  participantUids: const [],
  isAgree: true,
  status: status,
);

/// ЧУЖОЙ ВЕЧЕР С КАРТОЙ ОТВЕТОВ — строится ТОЛЬКО через `fromFirestore`.
///
/// Карту снаружи `models.dart` передать нельзя вовсе: и поле, и параметр
/// конструктора приватные (решение 10.08). Значит тест обязан идти той же
/// дорогой, что прод, — из документа, — и это не неудобство, а свойство:
/// событие с ответами в тесте невозможно собрать способом, которого нет в
/// проде.
PersonalEvent _foreign(
  String id,
  String date, {
  required String owner,
  required List<String> musicians,
  Map<String, dynamic>? answers,
}) => PersonalEvent.fromFirestore(id, {
  'ownerUid': owner,
  'date': date,
  'type': 'Toy',
  'musicians': musicians,
  'status': 'agreed',
  // `?answers` — ключа НЕТ вовсе, когда карты нет. Это не то же, что ключ со
  // значением `null`: на отсутствии поля стоит запасной путь шага 4, и
  // подсунуть сюда `null` значило бы проверять другой случай.
  'answers': ?answers,
});

void main() {
  group('что считается занятым', () {
    test('отменённое мероприятие времени не занимает', () {
      final events = [_ev('a', '2026-08-08T19:00:00', status: 'cancelled')];
      expect(
        exactConflictsAt(DateTime(2026, 8, 8, 19, 0), events, currentUid: _me),
        isEmpty,
      );
      expect(
        conflictEventsOnDay(DateTime(2026, 8, 8, 12, 0), events,
            currentUid: _me),
        isEmpty,
      );
    });

    test('правимое мероприятие не конфликтует само с собой', () {
      final events = [_ev('a', '2026-08-08T19:00:00')];
      expect(
        exactConflictsAt(DateTime(2026, 8, 8, 19, 0), events,
            currentUid: _me, excludeEventId: 'a'),
        isEmpty,
      );
      // Без исключения — конфликт находится.
      expect(
        exactConflictsAt(DateTime(2026, 8, 8, 19, 0), events, currentUid: _me)
            .single
            .id,
        'a',
      );
    });

    test('мероприятия дня идут по возрастанию времени', () {
      final events = [
        _ev('late', '2026-08-08T22:00:00'),
        _ev('early', '2026-08-08T09:00:00'),
        _ev('mid', '2026-08-08T14:30:00'),
        _ev('other', '2026-08-09T10:00:00'),
      ];
      final onDay = conflictEventsOnDay(DateTime(2026, 8, 8, 12, 0), events,
          currentUid: _me);
      expect(onDay.map((e) => e.id).toList(), ['early', 'mid', 'late']);
    });

    test('одно мероприятие, пришедшее двумя потоками, считается один раз', () {
      // Владелец числится и в собственном массиве участников, поэтому
      // склеенный список содержит его мероприятия дважды. Наблюдалось на
      // устройстве 03.08: календарь показывал «6 tədbiriniz var» там, где
      // лист предложения показывал «3».
      final own = _ev('a', '2026-08-03T19:00:00');
      final asParticipant = _ev('a', '2026-08-03T19:00:00');
      final events = [own, asParticipant];
      expect(
          conflictEventsOnDay(DateTime(2026, 8, 3, 12, 0), events,
                  currentUid: _me)
              .length,
          1);

      final b = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 3, 12, 0),
        events: events,
        currentUid: _me,
      );
      expect(b!.title, 'Bu gün sizin tədbiriniz var');
    });

    test('дубли не раздувают счёт в заголовке', () {
      final events = [
        _ev('a', '2026-08-03T19:00:00'),
        _ev('a', '2026-08-03T19:00:00'),
        _ev('b', '2026-08-03T22:03:00'),
        _ev('b', '2026-08-03T22:03:00'),
      ];
      final b = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 3, 12, 0),
        events: events,
        currentUid: _me,
      );
      expect(b!.title, 'Bu gün sizin 2 tədbiriniz var');
      expect(b.events.length, 2);
    });

    test('битая дата не роняет разбор и не считается конфликтом', () {
      final events = [_ev('bad', 'не дата'), _ev('empty', '')];
      expect(
          conflictEventsOnDay(DateTime(2026, 8, 8, 19, 0), events,
              currentUid: _me),
          isEmpty);
      expect(
          exactConflictsAt(DateTime(2026, 8, 8, 19, 0), events, currentUid: _me),
          isEmpty);
    });
  });

  // ЗАНЯТОСТЬ — СВОЙСТВО СОСТАВА, А НЕ ПРИГЛАШЕНИЯ (шаг 4, решение 11.08).
  //
  // Группа целиком про одно: до шага 4 занятым считался всякий вечер, где
  // человек есть в `musicians`, то есть где он имеет право ВИДЕТЬ. Теперь
  // занимает только тот, где он идёт.
  group('занятость считается по ответу, а не по составу', () {
    final at = DateTime(2026, 8, 8, 19, 0);

    test('приглашение без ответа чужой календарь НЕ занимает', () {
      final invited = _foreign('x', '2026-08-08T19:00:00',
          owner: _other,
          musicians: [_other, _me],
          answers: {_other: kAnswerGoing, _me: kAnswerWaiting});
      expect(
        conflictEventsOnDay(at, [invited], currentUid: _me),
        isEmpty,
        reason: 'ждём — это ещё не согласие, и блокировать им день нельзя',
      );
    });

    test('согласившийся участник занят', () {
      final going = _foreign('x', '2026-08-08T19:00:00',
          owner: _other,
          musicians: [_other, _me],
          answers: {_other: kAnswerGoing, _me: kAnswerGoing});
      expect(
        conflictEventsOnDay(at, [going], currentUid: _me).single.id,
        'x',
      );
    });

    test('отказавшийся участник НЕ занят', () {
      final cant = _foreign('x', '2026-08-08T19:00:00',
          owner: _other,
          musicians: [_other, _me],
          answers: {_other: kAnswerGoing, _me: kAnswerCant});
      expect(conflictEventsOnDay(at, [cant], currentUid: _me), isEmpty);
    });

    test('неспрошенный участник НЕ занят', () {
      // Карта есть, ключа нет — «его не спрашивали» (шаг 4). Это не то же,
      // что «спросили, молчит», но для занятости ответ у обоих один: без
      // согласия день не занят.
      final notAsked = _foreign('x', '2026-08-08T19:00:00',
          owner: _other,
          musicians: [_other, _me],
          answers: {_other: kAnswerGoing});
      expect(conflictEventsOnDay(at, [notAsked], currentUid: _me), isEmpty);
    });

    test('СТАРЫЙ документ без карты занимает по-прежнему', () {
      // 75 записей прода на 10.08 живут без поля `answers` вовсе. Для них
      // «есть в составе» и означало «идёт», и задним числом освобождать им
      // календарь нельзя: человек и правда туда идёт.
      final old = _foreign('x', '2026-08-08T19:00:00',
          owner: _other, musicians: [_other, _me]);
      expect(conflictEventsOnDay(at, [old], currentUid: _me).single.id, 'x');
    });

    test('ВЛАДЕЛЕЦ занят даже тогда, когда карта записала его ждущим', () {
      // N112: `answersForParticipants` ставит `waiting` всем новым, а у
      // договоров владелец в составе есть. Без строки `ownerUid == uid`
      // правка состава молча освободила бы владельцу его же вечер.
      final mine = _foreign('x', '2026-08-08T19:00:00',
          owner: _me,
          musicians: [_me, _other],
          answers: {_me: kAnswerWaiting, _other: kAnswerGoing});
      expect(conflictEventsOnDay(at, [mine], currentUid: _me).single.id, 'x');
    });

    test('пустой uid даёт ЗАНЯТО, а не пустой список', () {
      // Неизвестно, кто спрашивает, — это поломка вызывающего, и она обязана
      // быть заметной. `false` здесь выключил бы все предупреждения разом, и
      // выглядело бы это как «свободно» (I14).
      final any = _foreign('x', '2026-08-08T19:00:00',
          owner: _other,
          musicians: [_other],
          answers: {_other: kAnswerGoing});
      expect(conflictEventsOnDay(at, [any], currentUid: '').single.id, 'x');
    });
  });

  group('порядок случаев в плашке', () {
    final events = [_ev('a', '2026-08-08T19:00:00', location: 'Bakı')];

    test('свободное время — плашки нет', () {
      expect(
        resolveConflictBanner(
          selectedDate: DateTime(2026, 8, 10, 19, 0),
          events: events,
          currentUid: _me,
        ),
        isNull,
      );
    });

    test('точное совпадение минуты называет мероприятие', () {
      final b = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 8, 19, 0),
        events: events,
        currentUid: _me,
      );
      expect(b, isNotNull);
      expect(b!.title, 'Bu vaxtda sizin tədbiriniz var');
      expect(b.events.single.id, 'a');
    });

    test('занятый день — другое время того же дня', () {
      final b = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 8, 12, 0),
        events: events,
        currentUid: _me,
      );
      expect(b!.title, 'Bu gün sizin tədbiriniz var');
      expect(b.events.single.id, 'a');
    });

    test('несколько за день — число в заголовке и все в списке', () {
      final two = [
        _ev('a', '2026-08-08T19:00:00'),
        _ev('b', '2026-08-08T22:00:00'),
      ];
      final b = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 8, 12, 0),
        events: two,
        currentUid: _me,
      );
      expect(b!.title, 'Bu gün sizin 2 tədbiriniz var');
      expect(b.events.length, 2);
    });

    test('запрет на минуту старше находки', () {
      final b = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 8, 19, 0),
        events: events,
        currentUid: _me,
        blockedTime: DateTime(2026, 8, 8, 19, 0),
      );
      expect(b!.title, '19:00 artıq məşğuldur');
      expect(b.detail, 'Zəhmət olmasa başqa vaxt seçin');
      // Мероприятие всё равно доступно: человек попросил другое время, но
      // посмотреть, чем оно занято, ему нужно не меньше.
      expect(b.events.single.id, 'a');
    });

  });

  group('каждый запрет снимается своим действием', () {
    test('запрет на минуту снимается сдвигом времени', () {
      final blocked = DateTime(2026, 8, 8, 19, 0);
      expect(isConflictTimeBlocked(DateTime(2026, 8, 8, 19, 0), blocked), isTrue);
      expect(isConflictTimeBlocked(DateTime(2026, 8, 8, 19, 30), blocked), isFalse);
      // Тот же час и минута в ДРУГОЙ день запрет не снимают — сравнение
      // идёт по времени суток, а день закрывает второй запрет.
      expect(isConflictTimeBlocked(DateTime(2026, 8, 9, 19, 0), blocked), isTrue);
    });

  });

  group('строка мероприятия', () {
    test('пустые части не оставляют висящих разделителей', () {
      expect(
        eventConflictSummary(_ev('a', '2026-08-08T19:00:00', location: '')),
        'Toy · 19:00',
      );
      expect(
        eventConflictSummary(
            _ev('a', '2026-08-08T19:00:00', type: '', location: 'Bakı')),
        '19:00 · Bakı',
      );
    });
  });
}
