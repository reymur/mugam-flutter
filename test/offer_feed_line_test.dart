import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';

// СТРОКА ПРЕДЛОЖЕНИЯ В ЛЕНТЕ — три состояния, и третье не сводится ко
// второму.
//
// «0 gün cavab» было бы верно по числу и неверно по смыслу: ноль отмеченных
// дней — это ОТКАЗ, а не ответ с количеством. Человек, листающий переписку,
// должен видеть разницу между «он назвал три дня» и «он не может ни в один»,
// не открывая экран.

const boss = 'boss-uid';
const player = 'player-uid';

JobOffer offer({Map<String, List<String>> answers = const {}}) => JobOffer(
  id: 'o',
  createdBy: boss,
  dates: const ['2026-09-14', '2026-09-15', '2026-09-20'],
  eventType: 'Toy',
  answers: answers,
);

void main() {
  group('строка в ленте', () {
    test('без ответа — предложение с числом дней и типом', () {
      expect(
        offerFeedLine(offer(), recipientUid: player),
        '3 gün təklif · Toy',
      );
    });

    test('ответили днями — «cavab» с их числом', () {
      expect(
        offerFeedLine(
          offer(answers: {player: const ['2026-09-14', '2026-09-20']}),
          recipientUid: player,
        ),
        '2 gün cavab',
      );
    });

    // ТРЕТЬЕ СОСТОЯНИЕ, названное отдельно.
    test('ответили нулём — это ОТКАЗ, а не «0 gün cavab»', () {
      final line = offerFeedLine(
        offer(answers: {player: const []}),
        recipientUid: player,
      );
      expect(line, 'gələ bilmir');
      expect(line.contains('0'), isFalse, reason: 'отказ показан числом');
    });

    // Слово стоит В ТЕКСТЕ, а не выводится из того, чьё сообщение: через
    // месяц при прокрутке сторона и цвет читаются плохо, слово — всегда.
    test('предложение и ответ различаются словом, а не только стороной', () {
      // Сравнение ТОЧНОЕ, а не по вхождению: `contains` по голому слову
      // прошёл бы и на строке, где это слово оказалось случайно, — и на
      // такую слабость справедливо ругается `guards_are_guards_test`.
      expect(offerFeedLine(offer(), recipientUid: player), '3 gün təklif · Toy');
      expect(
        offerFeedLine(
          offer(answers: {player: const ['2026-09-14']}),
          recipientUid: player,
        ),
        '1 gün cavab',
      );
    });
  });

  group('когда принимать нечего', () {
    test('до ответа — нечего', () {
      expect(canAcceptAnswer(offer(), recipientUid: player), isFalse);
    });

    // ГЛАВНОЕ: кнопка над пустым ответом создала бы НОЛЬ вечеров — обещание
    // действия без последствий.
    test('ответ нулём дней — принимать НЕЧЕГО', () {
      expect(
        canAcceptAnswer(offer(answers: {player: const []}), recipientUid: player),
        isFalse,
      );
    });

    test('ответ с днями — принимать есть что', () {
      expect(
        canAcceptAnswer(
          offer(answers: {player: const ['2026-09-14']}),
          recipientUid: player,
        ),
        isTrue,
      );
    });

    test('закрытый раунд принимать не даёт', () {
      final accepted = JobOffer(
        id: 'o',
        createdBy: boss,
        dates: const ['2026-09-14'],
        eventType: 'Toy',
        answers: const {player: ['2026-09-14']},
        acceptedBy: boss,
      );
      expect(canAcceptAnswer(accepted, recipientUid: player), isFalse);
    });
  });
}
