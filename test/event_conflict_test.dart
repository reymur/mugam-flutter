import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/firebase/models.dart';
import 'package:mugam_flutter/shared/widgets/event_conflict_banner.dart';

// Правила конфликта — общие у листа «İş təklif et» и календарного окна.
// Смысл общего кода здесь ровно в том, что оба экрана отвечают одинаково,
// и это закрепляется тестом, а не подразумевается: разойдись правило,
// ошибки не возникнет нигде — просто один экран промолчит там, где другой
// предупредит. Ровно так они и разошлись до 03.08, и заметил это человек
// глазами, а не код.

PersonalEvent _ev(
  String id,
  String date, {
  String type = 'Toy',
  String location = '',
  String status = 'agreed',
}) => PersonalEvent(
  id: id,
  ownerUid: 'u1',
  date: date,
  type: type,
  location: location,
  notes: '',
  participantUids: const [],
  isAgree: true,
  status: status,
);

void main() {
  group('что считается занятым', () {
    test('отменённое мероприятие времени не занимает', () {
      final events = [_ev('a', '2026-08-08T19:00:00', status: 'cancelled')];
      expect(
        exactConflictsAt(DateTime(2026, 8, 8, 19, 0), events),
        isEmpty,
      );
      expect(
        conflictEventsOnDay(DateTime(2026, 8, 8, 12, 0), events),
        isEmpty,
      );
    });

    test('правимое мероприятие не конфликтует само с собой', () {
      final events = [_ev('a', '2026-08-08T19:00:00')];
      expect(
        exactConflictsAt(DateTime(2026, 8, 8, 19, 0), events,
            excludeEventId: 'a'),
        isEmpty,
      );
      // Без исключения — конфликт находится.
      expect(
        exactConflictsAt(DateTime(2026, 8, 8, 19, 0), events).single.id,
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
      final onDay = conflictEventsOnDay(DateTime(2026, 8, 8, 12, 0), events);
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
      expect(conflictEventsOnDay(DateTime(2026, 8, 3, 12, 0), events).length, 1);

      final b = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 3, 12, 0),
        events: events,
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
      );
      expect(b!.title, 'Bu gün sizin 2 tədbiriniz var');
      expect(b.events.length, 2);
    });

    test('битая дата не роняет разбор и не считается конфликтом', () {
      final events = [_ev('bad', 'не дата'), _ev('empty', '')];
      expect(conflictEventsOnDay(DateTime(2026, 8, 8, 19, 0), events), isEmpty);
      expect(exactConflictsAt(DateTime(2026, 8, 8, 19, 0), events), isEmpty);
    });
  });

  group('порядок случаев в плашке', () {
    final events = [_ev('a', '2026-08-08T19:00:00', location: 'Bakı')];

    test('свободное время — плашки нет', () {
      expect(
        resolveConflictBanner(
          selectedDate: DateTime(2026, 8, 10, 19, 0),
          events: events,
        ),
        isNull,
      );
    });

    test('точное совпадение минуты называет мероприятие', () {
      final b = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 8, 19, 0),
        events: events,
      );
      expect(b, isNotNull);
      expect(b!.title, 'Bu vaxtda sizin tədbiriniz var');
      expect(b.events.single.id, 'a');
    });

    test('занятый день — другое время того же дня', () {
      final b = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 8, 12, 0),
        events: events,
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
      );
      expect(b!.title, 'Bu gün sizin 2 tədbiriniz var');
      expect(b.events.length, 2);
    });

    test('запрет на минуту старше находки', () {
      final b = resolveConflictBanner(
        selectedDate: DateTime(2026, 8, 8, 19, 0),
        events: events,
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
