import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';

// КУДА ВЕДЁТ НАЖАТИЕ НА СТРОКУ ПРЕДЛОЖЕНИЯ — таблица роль × состояние.
//
// Проверяются ВСЕ ВОСЕМЬ клеток, а не выборочные: две роли на четыре
// состояния. Выборочная проверка здесь бесполезна по устройству — клетки
// независимы, и пропущенная не выводится из соседних.
//
// ЗАКРЫТЫЙ РАУНД РЕШЁН АВТОРОМ 19.08: лист открывается на просмотр, кнопок
// внутри нет. Довод — «человек захочет увидеть, на каких днях сошлись, а
// идти в календарь — не одно касание». Отдельного листа под это НЕ
// заводится: при `accepted`/`withdrawn` `offerCardActions` отдаёт всё
// `false`, то есть лист предложения сам собой выходит просмотром.

const boss = 'boss-uid';
const player = 'player-uid';

JobOffer offer({
  Map<String, List<String>> answers = const {},
  String? acceptedBy,
  String? withdrawnBy,
}) => JobOffer(
  id: 'o',
  createdBy: boss,
  dates: const ['2026-09-14', '2026-09-15'],
  eventType: 'Toy',
  answers: answers,
  acceptedBy: acceptedBy,
  withdrawnBy: withdrawnBy,
);

JobOffer get _awaiting => offer();
JobOffer get _answered => offer(answers: {player: const ['2026-09-14']});
JobOffer get _accepted => offer(
  answers: {player: const ['2026-09-14']},
  acceptedBy: boss,
);
JobOffer get _withdrawn => offer(withdrawnBy: boss);

void main() {
  group('таблица: роль × состояние → какой лист', () {
    // ЧЕТЫРЕ КЛЕТКИ ИНИЦИАТОРА.

    test('инициатор, ответа нет → лист предложения', () {
      expect(offerSheetFor(_awaiting, boss), OfferSheet.offer);
    });

    test('инициатор, ответили → лист ПРИЁМА', () {
      expect(offerSheetFor(_answered, boss), OfferSheet.accept);
    });

    test('инициатор, принято → лист предложения (просмотр)', () {
      expect(offerSheetFor(_accepted, boss), OfferSheet.offer);
    });

    test('инициатор, отозвано → лист предложения (просмотр)', () {
      expect(offerSheetFor(_withdrawn, boss), OfferSheet.offer);
    });

    // ЧЕТЫРЕ КЛЕТКИ ПОЛУЧАТЕЛЯ.

    test('получатель, ответа нет → лист ОТВЕТА', () {
      expect(offerSheetFor(_awaiting, player), OfferSheet.answer);
    });

    // Раунд открыт — значит переответить можно, и вести надо туда же.
    test('получатель, ответили → лист ОТВЕТА', () {
      expect(offerSheetFor(_answered, player), OfferSheet.answer);
    });

    test('получатель, принято → лист предложения (просмотр)', () {
      expect(offerSheetFor(_accepted, player), OfferSheet.offer);
    });

    test('получатель, отозвано → лист предложения (просмотр)', () {
      expect(offerSheetFor(_withdrawn, player), OfferSheet.offer);
    });

    // КАНАРЕЙКА, БЕЗУСЛОВНАЯ: таблица обязана быть заполнена целиком и
    // обязана РАЗЛИЧАТЬ.
    //
    // Без неё функция, возвращающая всегда один и тот же лист, прошла бы
    // ровно те клетки, где этот лист и ожидается, — а таких пять из
    // восьми. Здесь названо и число клеток, и число разных ответов.
    test('восемь клеток, и они не сводятся к одному ответу', () {
      final table = <OfferSheet>[
        offerSheetFor(_awaiting, boss),
        offerSheetFor(_answered, boss),
        offerSheetFor(_accepted, boss),
        offerSheetFor(_withdrawn, boss),
        offerSheetFor(_awaiting, player),
        offerSheetFor(_answered, player),
        offerSheetFor(_accepted, player),
        offerSheetFor(_withdrawn, player),
      ];

      expect(table.length, 8, reason: 'клеток должно быть восемь');
      expect(
        table.toSet().length,
        3,
        reason: 'все три листа обязаны встретиться: $table',
      );
      expect(table.toSet(), containsAll(OfferSheet.values));
    });

    // ЗАКРЫТЫЙ РАУНД ВЕДЁТ В ОДНО МЕСТО ОБЕИМ СТОРОНАМ — отдельной
    // строкой, потому что это и есть решение автора 19.08, а не следствие
    // порядка ветвей.
    test('в закрытом раунде роль на выбор листа НЕ влияет', () {
      expect(
        offerSheetFor(_accepted, boss),
        offerSheetFor(_accepted, player),
      );
      expect(
        offerSheetFor(_withdrawn, boss),
        offerSheetFor(_withdrawn, player),
      );
    });

    // ПОРЯДОК ВЕТВЕЙ: отзыв старше ответа. Отвеченное-и-отозванное ведёт на
    // просмотр, а не в лист приёма.
    test('отозвано после ответа — просмотр, а не приём', () {
      final both = offer(
        answers: {player: const ['2026-09-14']},
        withdrawnBy: boss,
      );
      expect(offerSheetFor(both, boss), OfferSheet.offer);
      expect(offerSheetFor(both, player), OfferSheet.offer);
    });

    // СВЯЗЬ С РАЗБОРОМ ДЕЙСТВИЙ: просмотр без кнопок держится не этим
    // выбором, а `offerCardActions`. Проверяется здесь же, иначе «лист
    // открывается» и «в нём нет кнопок» окажутся двумя не связанными
    // утверждениями, и первое переживёт второе.
    test('в листе просмотра действий не предложено никому', () {
      for (final o in [_accepted, _withdrawn]) {
        for (final uid in [boss, player]) {
          expect(offerSheetFor(o, uid), OfferSheet.offer);
          expect(offerCardActions(o, uid).isReadOnly, isTrue);
        }
      }
    });
  });
}
