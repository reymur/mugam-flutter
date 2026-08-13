import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/month_marks.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ПОМЕТКИ МЕСЯЦА — правила взяты из макета `docs/design/mugam-8-teqvim.html`.
//
// Главная проверка здесь — АРИФМЕТИКА СЧЁТА, и она не про красоту: в самом
// макете «Rafael 8 + Teymur 6 + Şübhəli 2 + Boş 17» даёт 33 при 31 дне
// августа, если сложить всё подряд. Сходится оно только тогда, когда
// «под вопросом» считается ПОДМНОЖЕСТВОМ занятых, а не отдельной долей.

// СОБЫТИЕ СТРОИТСЯ ЧЕРЕЗ `fromFirestore`, А НЕ КОНСТРУКТОРОМ (переведено
// 12.08). Причина не в стиле: с этого дня пометка дня зависит от ОТВЕТА
// человека (N126), а карта ответов у модели закрыта — параметр конструктора
// назван `_answers` и снаружи `models.dart` недоступен. Единственная дорога
// внутрь — документ, то есть ровно тот путь, которым ответы приходят в проде
// (I55).
PersonalEvent _ev(
  String id,
  String date, {
  String owner = 'tey',
  String status = 'agreed',
  List<String> musicians = const [],
  Map<String, String> answers = const {},
}) =>
    PersonalEvent.fromFirestore(id, {
      'ownerUid': owner,
      'date': date,
      'type': 'Toy',
      'status': status,
      'musicians': musicians,
      if (answers.isNotEmpty) 'answers': answers,
      'answersWrittenByOwner': true,
    });

/// Чьими глазами смотрим в проверках ниже. Совпадает с владельцем по
/// умолчанию у [_ev] — значит обычный вечер для него занят, и старые
/// проверки продолжают спрашивать ровно то, что спрашивали.
const _me = 'tey';

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
      expect(dayMarkOf(const [], _names, currentUid: _me), isNull);
    });

    test('берётся САМЫЙ РАННИЙ вечер дня — как в списке под сеткой', () {
      final mark = dayMarkOf([
        // Чужой вечер, но я в нём иду — значит он мой день занимает.
        _ev('late', '2026-08-03T22:03:00.000',
            owner: 'raf', musicians: const ['raf', _me],
            answers: const {'raf': 'going', _me: 'going'}),
        _ev('early', '2026-08-03T19:00:00.000', owner: 'tey'),
      ], _names, currentUid: _me);
      expect(mark!.ownerUid, 'tey');
      expect(mark.initials, 'TEY');
    });

    test('в силе — ЗАЛИТО', () {
      final mark = dayMarkOf(
          [_ev('a', '2026-08-06T19:00:00.000')], _names, currentUid: _me);
      expect(mark!.shape, DayMarkShape.filled);
    });

    test('под вопросом — РАМКА', () {
      final mark = dayMarkOf(
          [_ev('a', '2026-08-11T19:00:00.000', status: 'unsettled')], _names,
          currentUid: _me);
      expect(mark!.shape, DayMarkShape.outlined);
    });

    test('под вопросом ХОТЬ ОДИН — рамка, даже если рядом целый вечер', () {
      // Рамка это предупреждение, и терять его из-за соседнего целого вечера
      // нельзя: человек прочтёт день как беспроблемный.
      final mark = dayMarkOf([
        _ev('ok', '2026-08-11T18:00:00.000'),
        _ev('doubt', '2026-08-11T21:00:00.000', status: 'unsettled'),
      ], _names, currentUid: _me);
      expect(mark!.shape, DayMarkShape.outlined);
    });

    test('имени нет в справочнике — букв нет, но пометка есть', () {
      // День занят, и молчать об этом нельзя, даже когда профиль не доехал.
      final mark = dayMarkOf(
          [_ev('a', '2026-08-06T19:00:00.000')], const {}, currentUid: _me);
      expect(mark, isNotNull);
      expect(mark!.initials, '');
    });
  });

  // --- ПРИГЛАШЕНИЯ НА СЕТКЕ (N126, заведено 12.08) ---
  group('приглашение помечает день, но НЕ занимает его', () {
    PersonalEvent invitation(String date, {String answer = 'waiting'}) =>
        _ev('inv', date,
            owner: 'raf',
            musicians: const ['raf', _me],
            answers: {'raf': 'going', _me: answer});

    test('ТОЛЬКО приглашение — пометка есть, занявшего НЕТ', () {
      final mark =
          dayMarkOf([invitation('2026-08-14T20:00:00.000')], _names,
              currentUid: _me);
      expect(mark, isNotNull, reason: 'день не пуст — меня спрашивают');
      expect(mark!.invited, isTrue);
      expect(mark.occupied, isFalse, reason: 'приглашение день не занимает');
      expect(mark.ownerUid, isNull);
      expect(mark.shape, isNull,
          reason: 'форма описывает занявший вечер, а его нет');
    });

    test('ОТКАЗ — день НЕ занят, но след остаётся серой точкой', () {
      // Вторая половина N126: человек уже отказался, а приложение показывало
      // день занятым.
      //
      // ПОПРАВЛЕНО 12.08 по виду на трубке. Сперва здесь стояло «дня на сетке
      // нет вовсе», и это было МОЁ решение, а не авторское: отказанный день
      // становился неотличим от пустого. Автор потребовал след — «тухлую
      // серую точку»: день свободен, но видно, что вопрос здесь был и
      // разобран.
      final mark = dayMarkOf(
          [invitation('2026-08-14T20:00:00.000', answer: 'cant')], _names,
          currentUid: _me);
      expect(mark, isNotNull);
      expect(mark!.handledTrace, isTrue);
      expect(mark.unseenInvitations, 0, reason: 'отвеченное не ждёт просмотра');
      expect(mark.occupied, isFalse, reason: 'отказ день не занимает');
      expect(mark.invited, isFalse, reason: 'вопрос уже разобран');
      expect(mark.ownerUid, isNull);
      expect(mark.shape, isNull);
    });

    test('ЧИСЛО СТАРШЕ СЛЕДА: одно приглашение и один отказ в один день', () {
      // Неотвеченный вопрос важнее разобранного: серая точка ничего не
      // требует, золотое число требует. Показать след поверх числа значило бы
      // спрятать дело за отчётом о сделанном.
      final mark = dayMarkOf([
        invitation('2026-08-14T18:00:00.000', answer: 'cant'),
        _ev('inv2', '2026-08-14T20:00:00.000',
            owner: 'raf',
            musicians: const ['raf', _me],
            answers: const {'raf': 'going', _me: 'waiting'}),
      ], _names, currentUid: _me);
      expect(mark!.unseenInvitations, 1);
      expect(mark.handledTrace, isFalse, reason: 'пока есть число — следа нет');
    });

    // --- ЧИСЛО НЕПРОСМОТРЕННЫХ (решение автора 12.08) ---

    test('ТРИ приглашения, ни одного не смотрел — на клетке 3', () {
      final day = [
        for (final id in ['a', 'b', 'c'])
          _ev(id, '2026-08-14T20:00:00.000',
              owner: 'raf',
              musicians: const ['raf', _me],
              answers: const {'raf': 'going', _me: 'waiting'}),
      ];
      final mark = dayMarkOf(day, _names, currentUid: _me);
      expect(mark!.unseenInvitations, 3);
      expect(mark.occupied, isFalse, reason: 'приглашения день не занимают');
    });

    test('одно просмотрено — 2, все просмотрены — числа нет, остался след', () {
      final day = [
        for (final id in ['a', 'b'])
          _ev(id, '2026-08-14T20:00:00.000',
              owner: 'raf',
              musicians: const ['raf', _me],
              answers: const {'raf': 'going', _me: 'waiting'}),
      ];
      final one = dayMarkOf(day, _names,
          currentUid: _me, seenInvitationIds: const {'a'});
      expect(one!.unseenInvitations, 1);
      expect(one.handledTrace, isFalse);

      final all = dayMarkOf(day, _names,
          currentUid: _me, seenInvitationIds: const {'a', 'b'});
      expect(all!.unseenInvitations, 0);
      expect(all.handledTrace, isTrue, reason: 'разобранное оставляет след');
      expect(all.occupied, isFalse);
    });

    test('СВОЙ ВЕЧЕР И ЧИСЛО РЯДОМ — занятость числа не отменяет', () {
      final mark = dayMarkOf([
        _ev('mine', '2026-08-14T18:00:00.000'),
        _ev('inv', '2026-08-14T20:00:00.000',
            owner: 'raf',
            musicians: const ['raf', _me],
            answers: const {'raf': 'going', _me: 'waiting'}),
      ], _names, currentUid: _me);
      expect(mark!.occupied, isTrue);
      expect(mark.ownerUid, _me);
      expect(mark.unseenInvitations, 1);
    });

    test('вышел из состава — дня на сетке нет вовсе', () {
      final mark = dayMarkOf(
          [invitation('2026-08-14T20:00:00.000', answer: 'left')], _names,
          currentUid: _me);
      expect(mark, isNull);
    });

    test('согласился — день занят, приглашения больше нет', () {
      final mark = dayMarkOf(
          [invitation('2026-08-14T20:00:00.000', answer: 'going')], _names,
          currentUid: _me);
      expect(mark!.occupied, isTrue);
      expect(mark.invited, isFalse);
      expect(mark.ownerUid, 'raf');
    });

    test('СВОЙ ВЕЧЕР И ПРИГЛАШЕНИЕ В ОДИН ДЕНЬ — видно и то и другое', () {
      // Ради этого случая занятость и приглашение разведены в два поля, а не
      // в одно значение: слить их значило бы потерять одно из двух.
      final mark = dayMarkOf([
        _ev('mine', '2026-08-14T18:00:00.000'),
        invitation('2026-08-14T20:00:00.000'),
      ], _names, currentUid: _me);
      expect(mark!.occupied, isTrue);
      expect(mark.ownerUid, _me);
      expect(mark.invited, isTrue);
    });

    test('«под вопросом» СЧИТАЕТСЯ ПО ЗАНИМАЮЩИМ, а не по всем', () {
      // Вечер, на который меня зовут, своим «под вопросом» ничего не говорит
      // о моём дне, пока я не согласился. Иначе чужая неопределённость
      // рисовала бы рамку на моём целом вечере.
      final mark = dayMarkOf([
        _ev('mine', '2026-08-14T18:00:00.000'),
        _ev('inv', '2026-08-14T20:00:00.000',
            owner: 'raf',
            status: 'unsettled',
            musicians: const ['raf', _me],
            answers: const {'raf': 'going', _me: 'waiting'}),
      ], _names, currentUid: _me);
      expect(mark!.shape, DayMarkShape.filled);
      expect(mark.invited, isTrue);
    });

    test('СОСЕДКА-КАНАРЕЙКА: чужими глазами тот же день читается иначе', () {
      // Утверждения «дня нет» выше ломались бы молча, если бы правило
      // ослепло и отвечало `null` на всё. Здесь ОДИН И ТОТ ЖЕ вход даёт три
      // разных ответа трём разным парам глаз — значит правило видит данные, а
      // не отвечает наизусть.
      final e = invitation('2026-08-14T20:00:00.000', answer: 'cant');
      // Владелец — день занят.
      final owner = dayMarkOf([e], _names, currentUid: 'raf');
      expect(owner!.occupied, isTrue);
      expect(owner.ownerUid, 'raf');
      // Отказавшийся — день свободен, но со следом.
      final me = dayMarkOf([e], _names, currentUid: _me);
      expect(me!.occupied, isFalse);
      expect(me.handledTrace, isTrue);
      expect(me.unseenInvitations, 0);
      // Посторонний — дня нет вовсе.
      expect(dayMarkOf([e], _names, currentUid: 'stranger'), isNull);
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
      expect(t.invitedOnlyDays, 0, reason: 'в этой раскладке приглашений нет');
      expect(t.addsUp, isTrue);
    });

    test('пустой месяц: занятых ноль, свободны все', () {
      final t = monthTally(marks: const {}, daysInMonth: 30);
      expect(t.busyDays, 0);
      expect(t.freeDays, 30);
      expect(t.unsettledDays, 0);
      expect(t.invitedOnlyDays, 0);
      expect(t.addsUp, isTrue);
    });
  });

  // --- ТРЕТЬЯ ДОЛЯ В СЧЁТЕ (N126) ---
  group('счёт с приглашениями — третья доля, а не подмножество', () {
    test('день с одним приглашением: не занят, не свободен, СЧИТАЕТСЯ ОТДЕЛЬНО',
        () {
      final t = monthTally(
        marks: {
          1: const DayMark(
              ownerUid: 'raf', initials: 'RAF', shape: DayMarkShape.filled),
          2: const DayMark(unseenInvitations: 1),
        },
        daysInMonth: 31,
      );
      expect(t.busyDays, 1, reason: 'приглашение в занятые не идёт');
      expect(t.invitedOnlyDays, 1);
      expect(t.byOwner.containsKey(null), isFalse);
      expect(t.byOwner.length, 1,
          reason: 'приписать приглашение владельцу чужого вечера нельзя');
      // ВОТ ТА САМАЯ АРИФМЕТИКА: 1 + 1 + 29 = 31. До приглашений долей было
      // две и сумма сходилась тождественно; с третьей — уже нет, и потому
      // она проверяется, а не подразумевается (I13).
      expect(t.freeDays, 29);
      expect(t.busyDays + t.invitedOnlyDays + t.freeDays, 31);
      expect(t.addsUp, isTrue);
    });

    test('ДЕНЬ С ОТКАЗОМ — СВОБОДЕН, хотя пометка у него есть', () {
      // Ловушка, ради которой проверка и написана: прежде свободные считались
      // как «дни без пометки» (`daysInMonth - marks.length`). У отказанного
      // дня пометка ЕСТЬ — значит он выпал бы и из занятых, и из свободных, и
      // сумма недосчиталась бы на один день за каждый отказ. Молча: никто не
      // складывает доли глазами.
      final t = monthTally(
        marks: {
          1: const DayMark(
              ownerUid: 'raf', initials: 'RAF', shape: DayMarkShape.filled),
          2: const DayMark(handledTrace: true),
        },
        daysInMonth: 31,
      );
      expect(t.busyDays, 1);
      expect(t.invitedOnlyDays, 0, reason: 'отказ — не приглашение');
      expect(t.freeDays, 30, reason: 'отказанный день свободен');
      expect(t.busyDays + t.invitedOnlyDays + t.freeDays, 31);
      expect(t.addsUp, isTrue);
    });

    test('приглашение РЯДОМ с занятым днём считается один раз — как занятый',
        () {
      // Иначе один день попал бы в две доли, и сумма вышла бы за число дней
      // месяца — ровно та ошибка, которой в макете «33 при 31 дне».
      final t = monthTally(
        marks: {
          1: const DayMark(
              ownerUid: 'raf',
              initials: 'RAF',
              shape: DayMarkShape.filled,
              unseenInvitations: 1),
        },
        daysInMonth: 31,
      );
      expect(t.busyDays, 1);
      expect(t.invitedOnlyDays, 0);
      expect(t.addsUp, isTrue);
    });
  });
}
