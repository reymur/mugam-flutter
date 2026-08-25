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

JobOffer offerWith({
  String id = 'offer-1',
  String createdBy = boss,
  String? withdrawnBy,
  String? acceptedBy,
  Map<String, List<String>> answers = const {},
}) => JobOffer(
  id: id,
  createdBy: createdBy,
  dates: const ['2026-08-09', '2026-08-10'],
  eventType: 'Toy',
  withdrawnBy: withdrawnBy,
  acceptedBy: acceptedBy,
  answers: answers,
);

void main() {
  // ОТОЗВАННОЕ УБИРАЕТСЯ ИЗ ЛЕНТЫ — И ТОЛЬКО У ТОГО, КТО ОТОЗВАЛ.
  //
  // **АСИММЕТРИЯ ЗДЕСЬ — ГЛАВНОЕ, И ОНА ПОСТОЯННАЯ.** Довод целиком записан
  // у самого правила; коротко: push об отзыве подавляется присутствием, и
  // тот, кто смотрит в чат, не получил бы ни уведомления, ни строки —
  // предложение исчезло бы у него на глазах. Уведомление эту дыру НЕ
  // закрывает, поэтому у получателя строка остаётся навсегда, а не «до
  // шага 4».
  group('отозванное предложение прячется только у инициатора', () {
    test('инициатор отозванного не видит', () {
      expect(
        offerRowHidden(offerWith(withdrawnBy: boss), viewerUid: boss),
        isTrue,
      );
    });

    // ГЛАВНАЯ ПРОВЕРКА НАБОРА: без неё асимметрия ничем не держится, и
    // «прячем у обоих» прошло бы зелёным.
    test('ПОЛУЧАТЕЛЬ отозванное видит — иначе оно исчезнет молча', () {
      expect(
        offerRowHidden(offerWith(withdrawnBy: boss), viewerUid: player),
        isFalse,
        reason: 'получатель перестал видеть отзыв. Push его не спасёт: он '
            'подавляется присутствием, и смотрящий в чат не узнает ничего',
      );
    });

    // ОБРАТНАЯ СТОРОНА: «прячем всегда» дало бы тот же зелёный вердикт у
    // первой проверки. Перечислены ВСЕ три остальных состояния поимённо —
    // забытое выглядело бы обычным (I34).
    test('живое, отвеченное и принятое остаются у обоих', () {
      for (final viewer in [boss, player]) {
        expect(offerRowHidden(offerWith(), viewerUid: viewer), isFalse,
            reason: 'предложение без ответа пропало у $viewer');
        expect(
          offerRowHidden(
            offerWith(answers: {player: const ['2026-08-09']}),
            viewerUid: viewer,
          ),
          isFalse,
          reason: 'отвеченное пропало у $viewer',
        );
        expect(
          offerRowHidden(offerWith(acceptedBy: boss), viewerUid: viewer),
          isFalse,
          reason: 'принятое пропало у $viewer — на нём держится вся память '
              'о договорённости',
        );
      }
    });

    // Порядок ветвей в `state` значим, и здесь он проверяется с той
    // стороны, где ошибка была бы тихой: отвеченное-и-отозванное — это
    // ОТОЗВАННОЕ.
    test('отвеченное, а потом отозванное — тоже прячется у инициатора', () {
      expect(
        offerRowHidden(
          offerWith(
            answers: {player: const ['2026-08-09']},
            withdrawnBy: boss,
          ),
          viewerUid: boss,
        ),
        isTrue,
      );
    });
  });

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

    // ЗДЕСЬ СТОЯЛА РАСТЯЖКА, ПРИВЯЗАННАЯ НЕ К ТОЙ НИТИ — СНЯТА 20.08 (N151).
    //
    // Тест назывался «музыкант видит содержимое, но кнопки ответа ещё нет»,
    // и над ним стоял комментарий: «Когда шаг 2 её подключит, ЭТОТ тест
    // обязан покраснеть». **Покраснеть он не мог.** `pumpInFeed` строит
    // `JobOfferCard` НАПРЯМУЮ и сам не передаёт `onOpenAnswer`, то есть
    // проверял договор виджета — «обработчика нет → кнопки нет», — верный
    // навсегда и после шага 2. О проводке в `job_offer_sheet.dart`, которую
    // он якобы сторожил, он не знал ничего. Вдобавок он дословно повторял
    // `вести некуда — кнопки нет, но ход предложен`
    // (`job_offer_card_widget_test.dart:158`).
    //
    // **Настоящий сторож проводки — в `job_offer_sheet_live_test.dart`:**
    // `получателю кнопка ответа нарисована — экран подключён`. Он поднимает
    // `JobOfferSheet`, то есть ту самую нить, которую натягивает шаг 2.
    //
    // Здесь остаётся то, что этот набор проверять и обязан: **карточка
    // показывает содержимое.** Утверждение наличия — само себе канарейка
    // (I31).
    testWidgets('музыкант видит содержимое предложения', (tester) async {
      await pumpInFeed(tester, viewer: player);

      expect(find.text('2 gün · Toy'), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-day-2026-08-09')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-day-2026-08-10')), findsOneWidget);
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
