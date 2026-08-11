import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/month_marks.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ПОМЕТКИ МЕСЯЦА — правила взяты из макета `docs/design/mugam-8-teqvim.html`.
//
// Главная проверка здесь — АРИФМЕТИКА СЧЁТА, и она не про красоту: в самом
// макете «Rafael 8 + Teymur 6 + Şübhəli 2 + Boş 17» даёт 33 при 31 дне
// августа, если сложить всё подряд. Сходится оно только тогда, когда
// «под вопросом» считается ПОДМНОЖЕСТВОМ занятых, а не отдельной долей.

PersonalEvent _ev(
  String id,
  String date, {
  String owner = 'tey',
  String status = 'agreed',
}) =>
    PersonalEvent(
      id: id,
      ownerUid: owner,
      date: date,
      type: 'Toy',
      location: '',
      notes: '',
      participantUids: const [],
      isAgree: false,
      status: status,
    );

const _names = {'tey': 'Teymur Orucov', 'raf': 'Rafael Dagli'};

void main() {
  group('три буквы', () {
    test('берутся первые три, заглавными', () {
      expect(initialsOf('Rafael Dagli'), 'RAF');
      expect(initialsOf('Teymur Orucov'), 'TEY');
    });

    test('короткое имя не дополняется выдуманной буквой', () {
      // Придумать третью букву значит показать человеку имя, которого у него
      // нет.
      expect(initialsOf('Əli'), 'ƏLİ');
      expect(initialsOf('Ay'), 'AY');
      expect(initialsOf(''), '');
    });

    test('СТРОЧНАЯ «i» становится «İ», а заглавная «I» остаётся собой', () {
      // В азербайджанском это ДВЕ РАЗНЫЕ буквы: `i ↔ İ` и `ı ↔ I`. Dart по
      // умолчанию переводит `i` в латинскую `I`, то есть подменяет букву, —
      // поэтому строчная заменяется явно.
      //
      // А вот имя, написанное через `I`, трогать нельзя: `Ilqar` — это уже
      // другая буква, и «исправив» её на `İ`, мы переписали бы имя человека.
      // Первая редакция этой проверки ждала `İLQ` и была неверна.
      expect(initialsOf('ilqar'), 'İLQ');
      expect(initialsOf('İlqar'), 'İLQ');
      expect(initialsOf('Ilqar'), 'ILQ');
      expect(initialsOf('Ramil'), 'RAM');
    });

    test('пробелы по краям не съедают букву', () {
      expect(initialsOf('  Rafael'), 'RAF');
    });
  });

  group('пометка дня', () {
    test('пустой день пометки не получает', () {
      expect(dayMarkOf(const [], _names), isNull);
    });

    test('берётся САМЫЙ РАННИЙ вечер дня — как в списке под сеткой', () {
      final mark = dayMarkOf([
        _ev('late', '2026-08-03T22:03:00.000', owner: 'raf'),
        _ev('early', '2026-08-03T19:00:00.000', owner: 'tey'),
      ], _names);
      expect(mark!.ownerUid, 'tey');
      expect(mark.initials, 'TEY');
    });

    test('в силе — ЗАЛИТО', () {
      final mark = dayMarkOf([_ev('a', '2026-08-06T19:00:00.000')], _names);
      expect(mark!.shape, DayMarkShape.filled);
    });

    test('под вопросом — РАМКА', () {
      final mark = dayMarkOf(
          [_ev('a', '2026-08-11T19:00:00.000', status: 'unsettled')], _names);
      expect(mark!.shape, DayMarkShape.outlined);
    });

    test('под вопросом ХОТЬ ОДИН — рамка, даже если рядом целый вечер', () {
      // Рамка это предупреждение, и терять его из-за соседнего целого вечера
      // нельзя: человек прочтёт день как беспроблемный.
      final mark = dayMarkOf([
        _ev('ok', '2026-08-11T18:00:00.000'),
        _ev('doubt', '2026-08-11T21:00:00.000', status: 'unsettled'),
      ], _names);
      expect(mark!.shape, DayMarkShape.outlined);
    });

    test('имени нет в справочнике — букв нет, но пометка есть', () {
      // День занят, и молчать об этом нельзя, даже когда профиль не доехал.
      final mark = dayMarkOf([_ev('a', '2026-08-06T19:00:00.000')], const {});
      expect(mark, isNotNull);
      expect(mark!.initials, '');
    });
  });

  group('счёт под сеткой — арифметика макета', () {
    // Ровно та раскладка, что нарисована в mugam-8-teqvim: 8 дней Рафаэля,
    // 6 дней Теймура, из них два под вопросом (4 и 11), 31 день в августе.
    final marks = <int, DayMark>{
      for (final d in [1, 2, 5, 7, 8, 14, 28])
        d: const DayMark(
            ownerUid: 'raf', initials: 'RAF', shape: DayMarkShape.filled),
      4: const DayMark(
          ownerUid: 'raf', initials: 'RAF', shape: DayMarkShape.outlined),
      for (final d in [3, 6, 15, 19, 23])
        d: const DayMark(
            ownerUid: 'tey', initials: 'TEY', shape: DayMarkShape.filled),
      11: const DayMark(
          ownerUid: 'tey', initials: 'TEY', shape: DayMarkShape.outlined),
    };

    test('дни по людям совпадают с макетом: Рафаэль 8, Теймур 6', () {
      final t = monthTally(marks: marks, daysInMonth: 31);
      expect(t.byOwner['raf'], 8);
      expect(t.byOwner['tey'], 6);
    });

    test('под вопросом — 2, и это ПОДМНОЖЕСТВО занятых', () {
      final t = monthTally(marks: marks, daysInMonth: 31);
      expect(t.unsettledDays, 2);
      // Вот та самая проверка: если бы «под вопросом» вычиталось или
      // считалось отдельной долей, сумма развалилась бы.
      expect(t.busyDays, 14);
      expect(t.byOwner['raf']! + t.byOwner['tey']!, t.busyDays);
    });

    test('СУММА ДЕРЖИТСЯ: занятые плюс свободные — это все дни месяца', () {
      final t = monthTally(marks: marks, daysInMonth: 31);
      expect(t.freeDays, 17);
      expect(t.busyDays + t.freeDays, 31);
      expect(t.busyDays + t.freeDays, t.daysInMonth);
    });

    test('пустой месяц: занятых ноль, свободны все', () {
      final t = monthTally(marks: const {}, daysInMonth: 30);
      expect(t.busyDays, 0);
      expect(t.freeDays, 30);
      expect(t.unsettledDays, 0);
    });
  });
}
