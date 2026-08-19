import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';
import 'package:mugam_flutter/features/job_offer/widgets/job_offer_card.dart';

// ШАГ 1 — КАРТОЧКА В ЛЕНТЕ. Проверяется РЕШЕНИЕ, а не разметка.
//
// Экран целиком поднять здесь нечем: `ChatScreen` тянет Firebase. Поэтому
// проверяется то, что из него вынуто, — `offerCardFor`, отвечающая на
// «показывать ли это сообщение карточкой». Ровно этого сторожа не хватало
// в N125: там виджет ответа был жив, а на экране его не было, и 569
// зелёных тестов этого не заметили.
//
// **ЧЕГО ЭТОТ НАБОР НЕ ПРОВЕРЯЕТ, СКАЗАНО ПРЯМО (I50):** что карточка
// действительно подставлена в `_buildMessageBubble` и что ранний выход
// стоит ДО системных сообщений. Это порядок ветвей в разметке, он
// механически не выразим, и сторожа на него в проекте нет ни одного (I32).
// Здесь проверяется решение; связь решения с разметкой держится тем, что
// вызов один, и `grep -n "offerCardFor" lib` его показывает.

const boss = 'boss-uid';
const player = 'player-uid';

JobOffer offerWith({String id = 'offer-1', String createdBy = boss}) => JobOffer(
  id: id,
  createdBy: createdBy,
  dates: const ['2026-08-09', '2026-08-10'],
  eventType: 'Toy',
);

void main() {
  group('какое сообщение показывается карточкой (шаг 1)', () {
    test('нет ссылки — карточки нет', () {
      expect(offerCardFor(null, {'offer-1': offerWith()}), isNull);
    });

    test('ссылка есть и документ пришёл — карточка та самая', () {
      final o = offerWith();
      expect(offerCardFor('offer-1', {'offer-1': o}), same(o));
    });

    // ТРЕТИЙ ИСХОД, РАДИ КОТОРОГО НАБОР И ЗАВЕДЁН. На экране он неотличим
    // от первого, а по причине — совсем другой: документ ещё не доехал
    // либо удалён руками. Обычное сообщение здесь — задуманное поведение,
    // а не пропущенный случай.
    test('ссылка есть, документа нет — карточки нет, и это не поломка', () {
      expect(offerCardFor('offer-1', const {}), isNull);
    });

    test('чужая ссылка не подхватывает соседнее предложение', () {
      expect(
        offerCardFor('offer-2', {'offer-1': offerWith()}),
        isNull,
        reason: 'карточка взяла предложение, к этому сообщению не относящееся',
      );
    });
  });

  // ГРУППА ПЕРЕИМЕНОВАНА 19.08: карточки в ленте больше нет.
  //
  // В переписке стоит короткая строка, карточка переехала в
  // `JobOfferSheet`. Проверки те же и остались верными — они всегда
  // были про КАРТОЧКУ, а не про место, где она стоит.
  group('что карточка показывает в листе', () {
    Future<void> pumpInFeed(
      WidgetTester tester, {
      required String viewer,
      VoidCallback? onOpenAnswer,
      VoidCallback? onWithdraw,
    }) async {
      final o = offerWith();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: JobOfferCard(
                offer: o,
                viewerUid: viewer,
                recipientUid: player,
                initiatorName: 'Rafael',
                recipientName: 'Teymur',
                onOpenAnswer: onOpenAnswer,
                onWithdraw: onWithdraw,
              ),
            ),
          ),
        ),
      );
    }

    // СОСТОЯНИЕ ШАГА 1 ЗАПИСАНО ТЕСТОМ, А НЕ ТОЛЬКО СЛОВАМИ В ПЛАНЕ.
    //
    // Экран ответа не подключён, значит `onOpenAnswer` не передаётся, и
    // кнопки нет. Когда шаг 2 её подключит, ЭТОТ тест обязан покраснеть —
    // и тем самым напомнить, что состояние изменилось.
    testWidgets('музыкант видит содержимое, но кнопки ответа ещё нет', (
      tester,
    ) async {
      await pumpInFeed(tester, viewer: player);

      // Карточка на месте: заголовок и дни нарисованы.
      expect(find.text('2 gün · Toy'), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-day-2026-08-09')), findsOneWidget);

      // А хода — нет, потому что вести некуда.
      expect(find.byKey(const ValueKey('offer-open-answer')), findsNothing);
    });

    // ОТЗЫВ РИСУЕТСЯ ТОЛЬКО ТОГДА, КОГДА ЕМУ ЕСТЬ КУДА ВЕСТИ — то же
    // правило, что у кнопки ответа, распространённое 19.08 на приём и
    // отзыв. Поэтому здесь обработчик ПЕРЕДАЁТСЯ: без него кнопки не
    // будет, и это верно, а не сломано.
    testWidgets('работодатель видит ожидание и может отозвать', (tester) async {
      await pumpInFeed(tester, viewer: boss, onWithdraw: () {});

      // Фраза целиком: подстрока не поймала бы неверное окончание у имени.
      expect(find.text('Teymurdan cavab gözlənilir'), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-withdraw')), findsOneWidget);
    });
  });
}
