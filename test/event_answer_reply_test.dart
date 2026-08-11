import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answer_reply.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ШАГ 4, ПУНКТ 3 — ВОПРОС О ЗАНЯТОСТИ В МОМЕНТ СОГЛАСИЯ.
//
// Проверяется правило, а не окно: окно показывает то, что правило нашло, и
// разойдись они, ошибки не возникнет нигде — просто человек согласится на два
// вечера разом и узнает об этом в день события.

const me = 'me-uid';
const other = 'other-uid';

PersonalEvent _ev(
  String id,
  String date, {
  String owner = me,
  List<String> people = const [],
  Map<String, dynamic>? answers,
  String status = 'agreed',
}) =>
    PersonalEvent.fromFirestore(id, {
      'ownerUid': owner,
      'date': date,
      'type': 'Toy',
      'musicians': people,
      'status': status,
      'answers': ?answers,
    });

/// Вечер, на который отвечают: чужой, я в составе и пока жду.
final _target = _ev('target', '2026-08-12T18:00:00.000',
    owner: other,
    people: const [other, me],
    answers: const {other: 'going', me: 'waiting'});

void main() {
  group('когда вопрос ЗАДАЁТСЯ', () {
    test('своё мероприятие минута в минуту — спрашиваем', () {
      final mine = _ev('mine', '2026-08-12T18:00:00.000');
      final got = answerConflicts(
        target: _target,
        myEvents: [mine],
        currentUid: me,
        answer: kAnswerGoing,
      );
      expect(got.single.id, 'mine');
    });

    test('ВСЕ занявшие минуту, а не первый (N51)', () {
      final mine = _ev('mine', '2026-08-12T18:00:00.000');
      final foreign = _ev('foreign', '2026-08-12T18:00:00.000',
          owner: other,
          people: const [other, me],
          answers: const {other: 'going', me: 'going'});
      final got = answerConflicts(
        target: _target,
        myEvents: [mine, foreign],
        currentUid: me,
        answer: kAnswerGoing,
      );
      expect(got.map((e) => e.id).toSet(), {'mine', 'foreign'});
    });
  });

  group('когда вопрос МОЛЧИТ — и это решение, а не упущение', () {
    test('занят лишь ДЕНЬ — не спрашиваем', () {
      // Два мероприятия в один день — обычная жизнь (решение владельца
      // 03.08). Вопрос, который задают всегда, перестают читать.
      final sameDay = _ev('same-day', '2026-08-12T12:00:00.000');
      expect(
        answerConflicts(
          target: _target,
          myEvents: [sameDay],
          currentUid: me,
          answer: kAnswerGoing,
        ),
        isEmpty,
      );
    });

    test('ответ «не могу» вопроса не поднимает', () {
      // Человек освобождает время, а не занимает его. Спрашивать не о чем.
      final mine = _ev('mine', '2026-08-12T18:00:00.000');
      expect(
        answerConflicts(
          target: _target,
          myEvents: [mine],
          currentUid: me,
          answer: kAnswerCant,
        ),
        isEmpty,
      );
    });

    test('САМ ВЕЧЕР исключается всегда — иначе конфликтует сам с собой', () {
      // Решение владельца 11.08. При смене ответа с «иду» на «иду» документ
      // занят мною же, и без исключения окно спрашивало бы про тот самый
      // вечер, на который человек и отвечает.
      final answeredGoing = _ev('target', '2026-08-12T18:00:00.000',
          owner: other,
          people: const [other, me],
          answers: const {other: 'going', me: 'going'});
      expect(
        answerConflicts(
          target: answeredGoing,
          myEvents: [answeredGoing],
          currentUid: me,
          answer: kAnswerGoing,
        ),
        isEmpty,
      );
    });

    test('ПРИГЛАШЕНИЕ без ответа минуту не занимает', () {
      // Прямое следствие шага 4: занятость — свойство состава. Иначе
      // приглашение мешало бы согласиться на настоящий вечер.
      final invited = _ev('invited', '2026-08-12T18:00:00.000',
          owner: other,
          people: const [other, me],
          answers: const {other: 'going', me: 'waiting'});
      expect(
        answerConflicts(
          target: _target,
          myEvents: [invited],
          currentUid: me,
          answer: kAnswerGoing,
        ),
        isEmpty,
      );
    });

    test('битая дата вечера — молчим, а не выдумываем занятость', () {
      final broken = _ev('broken', 'не дата',
          owner: other,
          people: const [other, me],
          answers: const {other: 'going', me: 'waiting'});
      final mine = _ev('mine', '2026-08-12T18:00:00.000');
      expect(
        answerConflicts(
          target: broken,
          myEvents: [mine],
          currentUid: me,
          answer: kAnswerGoing,
        ),
        isEmpty,
      );
    });
  });

  // ЗАНЯТЫЙ ДЕНЬ — ПЛАШКОЙ, А НЕ ВОПРОСОМ (макет `mugam-6-kart.html`).
  group('плашка о занятом дне', () {
    test('другое время того же дня попадает в плашку', () {
      final sameDay = _ev('same-day', '2026-08-12T12:00:00.000');
      final got = answerDayNotice(
          target: _target, myEvents: [sameDay], currentUid: me);
      expect(got.single.id, 'same-day');
    });

    test('ЗАНЯВШЕЕ ТУ ЖЕ МИНУТУ в плашку НЕ попадает — оно в окне', () {
      // Иначе один вечер сказал бы о себе дважды: и плашкой, и вопросом.
      // Разделение проверяется здесь, потому что склейка была бы не ошибкой
      // вида, а двойным предупреждением об одном.
      final exact = _ev('exact', '2026-08-12T18:00:00.000');
      final sameDay = _ev('same-day', '2026-08-12T12:00:00.000');
      final notice = answerDayNotice(
          target: _target, myEvents: [exact, sameDay], currentUid: me);
      final asked = answerConflicts(
        target: _target,
        myEvents: [exact, sameDay],
        currentUid: me,
        answer: kAnswerGoing,
      );
      expect(notice.map((e) => e.id), ['same-day']);
      expect(asked.map((e) => e.id), ['exact']);
      // Состав, а не количество (I13): пересечение должно быть пустым.
      expect(
        notice.map((e) => e.id).toSet().intersection(
              asked.map((e) => e.id).toSet(),
            ),
        isEmpty,
      );
    });

    test('сам вечер в свою же плашку не попадает', () {
      expect(
        answerDayNotice(
            target: _target, myEvents: [_target], currentUid: me),
        isEmpty,
      );
    });

    test('приглашение без ответа в плашку не попадает', () {
      // Занятость — свойство состава: показать «день занят» из-за
      // приглашения значило бы вернуть занятость приглашениям с заднего
      // хода, теперь уже на экране.
      final invited = _ev('invited', '2026-08-12T12:00:00.000',
          owner: other,
          people: const [other, me],
          answers: const {other: 'going', me: 'waiting'});
      expect(
        answerDayNotice(
            target: _target, myEvents: [invited], currentUid: me),
        isEmpty,
      );
    });
  });

  // N39: ГЛАВНЫЙ ИНВАРИАНТ ОКНА.
  //
  // Там дефектом была подмена вопроса ВЛАДЕНИЕМ: набор ответов зависел от
  // того, чьё мешающее мероприятие, при том что ответ от этого не зависел, — и
  // главная кнопка правила чужой документ. Здесь ни один ответ мешающего
  // документа не касается, значит и ветки по владению быть не должно.
  group('N39: набор ответов не зависит от владения мешающим вечером', () {
    test('свой и чужой мешающий вечер дают ОДИН И ТОТ ЖЕ набор', () {
      // Утверждение записано исполняемо, а не комментарием: функция владения
      // не принимает вовсе, и проверка падает, если его туда заведут.
      expect(answerConflictChoices(), {
        AnswerConflictChoice.view,
        AnswerConflictChoice.goAnyway,
        AnswerConflictChoice.cannotGo,
      });
    });

    test('ЗАКРЫТИЕ ОКНА — отдельный исход, а не «не могу» (I47)', () {
      // Человек мог выйти подумать. Записать за него отказ значило бы
      // ответить вместо него, а сливаются эти два случая молча — первый же
      // рефакторинг сделает `null` синонимом отказа и ничего не заметит.
      expect(answerAfterConflict(null), isNull);
      expect(answerAfterConflict(null),
          isNot(answerAfterConflict(AnswerConflictChoice.cannotGo)));
    });

    test('«посмотреть» тоже ничего не пишет — это отсрочка, а не ответ', () {
      expect(answerAfterConflict(AnswerConflictChoice.view), isNull);
    });

    test('оба пишущих ответа пишут РАЗНОЕ и из известного набора', () {
      final go = answerAfterConflict(AnswerConflictChoice.goAnyway);
      final cant = answerAfterConflict(AnswerConflictChoice.cannotGo);
      expect(go, kAnswerGoing);
      expect(cant, kAnswerCant);
      expect(go, isNot(cant));
      // Значение обязано быть из набора, который умеет читать `answerOf`:
      // чужая строка прочиталась бы как «не спрашивали» (шаг 4).
      expect(kEventAnswers.contains(go!), isTrue);
      expect(kEventAnswers.contains(cant!), isTrue);
    });

    test('ни один ответ не трогает чужой документ — их ровно три', () {
      // Четвёртый ответ вида «удалить мешающее» / «заменить» здесь не просто
      // неудобен, а НЕВЫРАЗИМ: правило шага 4 разрешает участнику тронуть
      // ровно свой ключ, и сервер откажет, что бы ни было нажато.
      expect(answerConflictChoices().length, 3);
      expect(
        answerConflictChoices().map((c) => c.name).toSet(),
        {'view', 'goAnyway', 'cannotGo'},
      );
    });
  });
}
