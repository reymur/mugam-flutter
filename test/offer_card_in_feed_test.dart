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

  group('что карточка показывает в ленте на шаге 1', () {
    Future<void> pumpInFeed(
      WidgetTester tester, {
      required String viewer,
      VoidCallback? onOpenAnswer,
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
    testWidgets('музыкант видит карточку, но кнопки ответа ещё нет', (
      tester,
    ) async {
      await pumpInFeed(tester, viewer: player);

      // Карточка на месте: заголовок и дни нарисованы.
      expect(find.text('2 gün · Toy'), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-day-2026-08-09')), findsOneWidget);

      // А хода — нет, потому что вести некуда.
      expect(find.byKey(const ValueKey('offer-open-answer')), findsNothing);
    });

    // Работодателю на шаге 1 доступно ВСЁ, что не требует чужого экрана:
    // отзыв — его собственный ход и в подключении не нуждается.
    testWidgets('работодатель видит ожидание и может отозвать', (tester) async {
      await pumpInFeed(tester, viewer: boss);

      // Фраза целиком: подстрока не поймала бы неверное окончание у имени.
      expect(find.text('Teymurdan cavab gözlənilir'), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-withdraw')), findsOneWidget);
    });
  });
}
