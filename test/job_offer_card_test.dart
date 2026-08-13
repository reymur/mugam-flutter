import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';

// ТАБЛИЦА «СОСТОЯНИЕ × РОЛЬ → КАКИЕ ДЕЙСТВИЯ ПРЕДЛОЖЕНЫ» — та самая, что
// названа в I32 выразимым следствием.
//
// ЗАЧЕМ ОНА, числом и случаями, а не «для порядка». Порядок ветвей в
// разметке механически не выразим: лишний `return` отличается от
// правильного только замыслом, а замысла в файле нет. Сторожа на очерёдность
// решений в этом проекте нет НИ ОДНОГО, и цена уже заплачена:
//
//   • N125 — участнику нечем ответить: блок «Cavabınız» осиротел при
//     пересборке карточки по макету. Тринадцать часов в проде на двух
//     трубках, при 569 зелёных тестах и 42 наборах из 42. Ни один тест не
//     утверждал, что участнику ПРЕДЛОЖЕНО действие;
//   • N108 — первая находка того же класса, оставалась умозрительной.
//
// Строка, которая поймала бы N125, здесь есть дословно: «получателю
// предложены отметки и отправка».
//
// САМА СЕБЕ КАНАРЕЙКА (I31): таблица утверждает НАЛИЧИЕ действий. Ослепни
// разбор — вернётся пустой набор, а пустого не ждёт ни одна строка, и набор
// покраснеет в тот же заход.
//
// ЧЕГО ЭТОТ НАБОР НЕ ЛОВИТ, сказано вместе с ним: он про то, ЧТО ПРЕДЛОЖЕНО,
// и молчит о том, КАК ЭТО ВЫГЛЯДИТ и куда нажатие ведёт. Кнопка может быть
// предложена таблицей и не нарисована виджетом — это ловится только
// widget-тестом либо руками на трубке.

const boss = 'boss-uid';
const player = 'player-uid';

JobOffer offer({
  Map<String, List<String>> answers = const {},
  String? acceptedBy,
  String? withdrawnBy,
}) {
  return JobOffer(
    id: 'offer-1',
    createdBy: boss,
    dates: const ['2026-08-09', '2026-08-10', '2026-08-11'],
    eventType: 'Toy',
    answers: answers,
    acceptedBy: acceptedBy,
    withdrawnBy: withdrawnBy,
  );
}

void main() {
  group('состояние предложения', () {
    test('без ответов — ждём ответа', () {
      expect(offer().state, OfferState.awaitingAnswer);
    });

    test('есть отметки — отвечено', () {
      expect(
        offer(answers: {player: const ['2026-08-09']}).state,
        OfferState.answered,
      );
    });

    // ПУСТОЙ СПИСОК — ЭТО ОТВЕТ, А НЕ ЕГО ОТСУТСТВИЕ. «Не могу ни на один
    // день»: отдельного отказа в этой работе нет, неотмеченные дни и значат
    // «нет». Свести это с молчанием в одно значило бы потерять различие
    // между отказом и неответом (I47).
    test('пустой список отметок — это ОТВЕТ «не могу ни на один»', () {
      final o = offer(answers: {player: const []});
      expect(o.state, OfferState.answered);
      expect(o.hasAnswered(player), isTrue);
      expect(o.pickedBy(player), isEmpty);
    });

    test('молчание отличается от отказа', () {
      expect(offer().hasAnswered(player), isFalse);
      expect(offer(answers: {player: const []}).hasAnswered(player), isTrue);
    });

    // Порядок ветвей значим: отвеченное-и-отозванное — отозванное.
    test('отзыв старше ответа', () {
      expect(
        offer(answers: {player: const ['2026-08-09']}, withdrawnBy: boss).state,
        OfferState.withdrawn,
      );
    });

    test('принятие старше ответа', () {
      expect(
        offer(answers: {player: const ['2026-08-09']}, acceptedBy: boss).state,
        OfferState.accepted,
      );
    });
  });

  group('неотмеченные дни — «10, 12 — yox»', () {
    test('считаются как остаток от предложенных', () {
      final o = offer(answers: {player: const ['2026-08-09', '2026-08-11']});
      expect(o.declinedBy(player), ['2026-08-10']);
    });

    // До ответа неотмеченных нет: иначе карточка сказала бы «отказался от
    // всех» тому, кого ещё не спрашивали.
    test('до ответа неотмеченных НЕТ, а не «все»', () {
      expect(offer().declinedBy(player), isEmpty);
    });

    test('ответ нулём дней делает неотмеченными все', () {
      final o = offer(answers: {player: const []});
      expect(o.declinedBy(player).length, 3);
    });
  });

  group('таблица: состояние × роль → что предложено', () {
    // ЭТА СТРОКА ПОЙМАЛА БЫ N125.
    test('получателю предложены отметки и отправка, пока раунд открыт', () {
      final a = offerCardActions(offer(), player);
      expect(a.canPickDays, isTrue);
      expect(a.canSend, isTrue);
      expect(a.canRecordVoice, isTrue);
    });

    test('получатель переотмечает и после своего ответа', () {
      final a = offerCardActions(
        offer(answers: {player: const ['2026-08-09']}),
        player,
      );
      expect(a.canPickDays, isTrue);
      expect(a.canSend, isTrue);
    });

    test('получателю НЕ предложено ни принять, ни отозвать', () {
      final a = offerCardActions(
        offer(answers: {player: const ['2026-08-09']}),
        player,
      );
      expect(a.canAccept, isFalse);
      expect(a.canWithdraw, isFalse);
    });

    test('инициатору не предложено отмечать дни', () {
      expect(offerCardActions(offer(), boss).canPickDays, isFalse);
    });

    // Принимать нечего, пока не ответили: кнопка там означала бы согласие с
    // пустотой.
    test('инициатору «принять» предложено ТОЛЬКО после ответа', () {
      expect(offerCardActions(offer(), boss).canAccept, isFalse);
      expect(
        offerCardActions(
          offer(answers: {player: const ['2026-08-09']}),
          boss,
        ).canAccept,
        isTrue,
      );
    });

    // Ответ нулём дней — тоже ответ, и принять его можно: работодатель
    // видит «0 gün», и это его решение, а не запрет приложения.
    test('ответ нулём дней инициатор всё равно может принять', () {
      expect(
        offerCardActions(offer(answers: {player: const []}), boss).canAccept,
        isTrue,
      );
    });

    test('инициатору отзыв предложен, пока раунд открыт', () {
      expect(offerCardActions(offer(), boss).canWithdraw, isTrue);
      expect(
        offerCardActions(
          offer(answers: {player: const ['2026-08-09']}),
          boss,
        ).canWithdraw,
        isTrue,
      );
    });

    test('голос предложен обеим сторонам, пока раунд открыт', () {
      expect(offerCardActions(offer(), boss).canRecordVoice, isTrue);
      expect(offerCardActions(offer(), player).canRecordVoice, isTrue);
    });
  });

  group('закрытый раунд не предлагает ничего и никому', () {
    test('после принятия — обе стороны только смотрят', () {
      final o = offer(
        answers: {player: const ['2026-08-09']},
        acceptedBy: boss,
      );
      expect(offerCardActions(o, boss).isReadOnly, isTrue);
      expect(offerCardActions(o, player).isReadOnly, isTrue);
    });

    test('после отзыва — обе стороны только смотрят', () {
      final o = offer(withdrawnBy: boss);
      expect(offerCardActions(o, boss).isReadOnly, isTrue);
      expect(offerCardActions(o, player).isReadOnly, isTrue);
    });

    // Правило это держит своим `roundOpen()`, и здесь стоит вторая половина
    // той же защиты — на стороне показа. Обе нужны: правило не даст записать,
    // экран не даст нажать, и человек не увидит кнопку, которая откажет.
    test('принятое не предлагается отозвать', () {
      final o = offer(acceptedBy: boss);
      expect(offerCardActions(o, boss).canWithdraw, isFalse);
    });
  });

  group('роль принадлежит предложению, а не человеку (N127)', () {
    test('создатель — инициатор, второй — получатель', () {
      expect(offer().roleOf(boss), OfferRole.initiator);
      expect(offer().roleOf(player), OfferRole.recipient);
    });

    // Тот же человек в другом предложении — другая роль. Роли на уровне
    // чата нет и заводить её не надо: позвать на работу может любой
    // участник.
    test('в предложении от второго роли меняются местами', () {
      final theirs = JobOffer(
        id: 'offer-2',
        createdBy: player,
        dates: const ['2026-08-20'],
        eventType: 'Toy',
      );
      expect(theirs.roleOf(player), OfferRole.initiator);
      expect(theirs.roleOf(boss), OfferRole.recipient);
      expect(offerCardActions(theirs, boss).canPickDays, isTrue);
    });
  });

  group('чтение документа', () {
    test('мягкое чтение переживает мусор в полях', () {
      final o = JobOffer.fromMap('x', {
        'createdBy': boss,
        'dates': ['2026-08-09', 7, null],
        'eventType': 'Toy',
        'answers': {
          player: ['2026-08-09', 5],
          9: ['2026-08-10'],
        },
      });
      expect(o.dates, ['2026-08-09']);
      expect(o.pickedBy(player), ['2026-08-09']);
      expect(o.answers.containsKey('9'), isFalse);
    });

    test('пустой документ не роняет карточку', () {
      final o = JobOffer.fromMap('x', {});
      expect(o.dates, isEmpty);
      expect(o.state, OfferState.awaitingAnswer);
    });
  });
}
