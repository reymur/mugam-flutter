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

JobOffer offer({
  Map<String, List<String>> answers = const {},
  String? acceptedBy,
  String? withdrawnBy,
  List<String>? dates,
}) => JobOffer(
  id: 'o',
  createdBy: boss,
  dates: dates ?? const ['2026-09-14', '2026-09-15', '2026-09-20'],
  eventType: 'Toy',
  answers: answers,
  acceptedBy: acceptedBy,
  withdrawnBy: withdrawnBy,
);

void main() {
  group('строка в ленте', () {
    // ПЯТЬ СОСТОЯНИЙ, И СПИСОК ВЗЯТ ИЗ БАЗЫ, А НЕ ИЗ ФУНКЦИИ (N144).
    //
    // Правила разрешают ровно три хода записи — `answers`,
    // `acceptedBy`+`acceptedAt`, `withdrawnBy`+`withdrawnAt`, — значит
    // признаков в документе три; их сочетания дают четыре состояния, а
    // внутри «ответили» есть расщепление по пустому списку дней. Пять.
    //
    // До 19.08 функция знала три, и восемь тестов этого не ловили: список
    // состояний был взят из той же головы, что писала функцию. Поэтому
    // здесь он выписан ПОИМЁННО и сверяется весь, а не выборочно.

    test('ответа нет — ждём ответа', () {
      expect(
        offerFeedLine(offer(), recipientUid: player),
        '14–15, 20 sentyabr · 3 gün · Toy · cavab gözlənilir',
      );
    });

    test('ответили днями — ДВА числа: отмеченные из предложенных', () {
      expect(
        offerFeedLine(
          offer(answers: {player: const ['2026-09-14', '2026-09-20']}),
          recipientUid: player,
        ),
        '14, 20 sentyabr · 2/3 gün · Toy · cavab',
      );
    });

    // ЧИСЛА СОВПАЛИ — ДРОБИ НЕТ. Замечено глазами 25.08: «1/1 gün» ничего
    // не сообщает вторым числом, а выглядит как поломка.
    //
    // Утверждается И НАЛИЧИЕ «3 gün», И ОТСУТСТВИЕ «3/3 gün». Одного
    // первого мало: «3/3 gün» содержит «3 gün» подстрокой, и проверка на
    // одно вхождение прошла бы зелёной при живой дроби (I31).
    test('согласился на все предложенные — одно число, а не «3/3»', () {
      final line = offerFeedLine(
        offer(
          answers: {
            player: const ['2026-09-14', '2026-09-15', '2026-09-20'],
          },
        ),
        recipientUid: player,
      );
      expect(line, '14–15, 20 sentyabr · 3 gün · Toy · cavab');
      expect(line.contains('3/3'), isFalse);
    });

    test('согласился на единственный предложенный — «1 gün», не «1/1»', () {
      final line = offerFeedLine(
        offer(
          dates: const ['2026-09-14'],
          answers: {player: const ['2026-09-14']},
        ),
        recipientUid: player,
      );
      expect(line, '14 sentyabr · 1 gün · Toy · cavab');
      expect(line.contains('1/1'), isFalse);
    });

    // ОБРАТНАЯ СТОРОНА, И БЕЗ НЕЁ ДВЕ ПРЕДЫДУЩИЕ НИЧЕГО НЕ ЗНАЧАТ: снятие
    // дроби вообще дало бы те же два зелёных теста. Дробь обязана остаться
    // там, где числа РАЗНЫЕ.
    test('согласился не на все — дробь на месте', () {
      final line = offerFeedLine(
        offer(answers: {player: const ['2026-09-14']}),
        recipientUid: player,
      );
      expect(line.contains('1/3 gün'), isTrue);
    });

    // ТРЕТЬЕ НЕ СВОДИТСЯ КО ВТОРОМУ.
    test('ответили нулём — это ОТКАЗ, а не «0 gün cavab»', () {
      final line = offerFeedLine(
        offer(answers: {player: const []}),
        recipientUid: player,
      );
      expect(line, '14–15, 20 sentyabr · 3 gün · Toy · gələ bilmir');
      expect(
        line.contains('0 gün'),
        isFalse,
        reason: 'отказ показан числом отмеченных',
      );
    });

    // ЧЕТВЁРТОЕ И ПЯТОЕ — ИХ ФУНКЦИЯ НЕ ЗНАЛА ВОВСЕ.
    test('принято — своё слово, а не «cavab»', () {
      final line = offerFeedLine(
        offer(answers: {player: const ['2026-09-14', '2026-09-20']},
            acceptedBy: boss),
        recipientUid: player,
      );
      expect(line, '14, 20 sentyabr · 2/3 gün · Toy · qəbul edildi');
    });

    // КАНАРЕЙКА НА ВТОРОЕ ЧИСЛО, БЕЗУСЛОВНАЯ.
    //
    // Ловит функцию, которая показывает два числа ВСЕГДА: в трёх
    // состояниях второго числа быть не должно — до ответа отмечать нечего,
    // у отказа отмеченных ноль по смыслу, у отозванного ответа могло не
    // быть вовсе. «0/3» там верно по числу и неверно по смыслу.
    //
    // Без неё достаточно было бы поставить двойную форму везде, и обе
    // проверки выше остались бы зелёными.
    test('в трёх состояниях число ОДНО, а не два', () {
      final single = <String, String>{
        'ждём ответа': offerFeedLine(offer(), recipientUid: player),
        'gələ bilmir': offerFeedLine(
          offer(answers: {player: const []}),
          recipientUid: player,
        ),
        'отозвано': offerFeedLine(offer(withdrawnBy: boss), recipientUid: player),
      };

      expect(single.length, 3);
      single.forEach((state, line) {
        expect(
          line.contains('/'),
          isFalse,
          reason: 'в состоянии «$state» второго числа быть не должно: $line',
        );
      });
    });

    test('в двух состояниях число ДВА, а не одно', () {
      final paired = <String, String>{
        'ответили': offerFeedLine(
          offer(answers: {player: const ['2026-09-14']}),
          recipientUid: player,
        ),
        'принято': offerFeedLine(
          offer(answers: {player: const ['2026-09-14']}, acceptedBy: boss),
          recipientUid: player,
        ),
      };

      expect(paired.length, 2);
      paired.forEach((state, line) {
        expect(
          line.contains('1/3 gün'),
          isTrue,
          reason: 'в состоянии «$state» нужны оба числа: $line',
        );
      });
    });

    test('отозвано — своё слово, и число ПРЕДЛОЖЕННЫХ', () {
      // Отозвать можно и до ответа, поэтому отмеченных может не быть
      // вовсе: показывается то, на сколько звали.
      expect(
        offerFeedLine(offer(withdrawnBy: boss), recipientUid: player),
        '14–15, 20 sentyabr · 3 gün · Toy · geri götürüldü',
      );
    });

    test('отозвано ПОСЛЕ ответа — всё равно отозвано', () {
      // Порядок ветвей в `JobOffer.state` значим: отзыв старше ответа.
      expect(
        offerFeedLine(
          offer(answers: {player: const ['2026-09-14']}, withdrawnBy: boss),
          recipientUid: player,
        ),
        '14–15, 20 sentyabr · 3 gün · Toy · geri götürüldü',
      );
    });

    // КАНАРЕЙКА НА ПОЛНОТУ РАЗБОРА, БЕЗУСЛОВНАЯ.
    //
    // Пять состояний обязаны дать ПЯТЬ РАЗНЫХ строк. Без этой проверки
    // достаточно было бы вернуть одно и то же слово из двух веток, и
    // каждая отдельная проверка выше осталась бы зелёной ровно у той,
    // которую ей показали.
    test('пять состояний дают пять разных строк', () {
      final lines = <String>{
        offerFeedLine(offer(), recipientUid: player),
        offerFeedLine(
          offer(answers: {player: const ['2026-09-14']}),
          recipientUid: player,
        ),
        offerFeedLine(offer(answers: {player: const []}), recipientUid: player),
        offerFeedLine(
          offer(answers: {player: const ['2026-09-14']}, acceptedBy: boss),
          recipientUid: player,
        ),
        offerFeedLine(offer(withdrawnBy: boss), recipientUid: player),
      };
      expect(lines.length, 5, reason: 'состояния слились: $lines');
    });

    // Тип работы стоит в КАЖДОМ состоянии: через месяц при прокрутке надо
    // понять, о чём речь, не открывая, — а исход к тому времени любой.
    test('тип работы назван во всех пяти', () {
      final all = [
        offerFeedLine(offer(), recipientUid: player),
        offerFeedLine(
          offer(answers: {player: const ['2026-09-14']}),
          recipientUid: player,
        ),
        offerFeedLine(offer(answers: {player: const []}), recipientUid: player),
        offerFeedLine(
          offer(answers: {player: const ['2026-09-14']}, acceptedBy: boss),
          recipientUid: player,
        ),
        offerFeedLine(offer(withdrawnBy: boss), recipientUid: player),
      ];
      expect(all.length, 5);
      for (final line in all) {
        expect(line, contains('· Toy ·'), reason: 'тип потерян: $line');
      }
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
