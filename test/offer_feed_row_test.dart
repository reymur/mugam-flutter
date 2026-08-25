import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';
import 'package:mugam_flutter/features/job_offer/widgets/offer_feed_row.dart';

// СТРОКА ПРЕДЛОЖЕНИЯ В ЛЕНТЕ — даты вместо чисел (25.08) и подпись автора
// (N164).
//
// ПОЧЕМУ ДАТЫ. Замер прода 25.08 (`runQuery` по `offers`): из 19 предложений
// два приняты, и оба дают ровно «1/2 gün · Toy · qəbul edildi» — при том что
// у одного дни 25–26 августа, у другого 22–23. **Два разных дела, в ленте
// неразличимых.** Число говорит сколько, человеку нужно какие.
//
// ПОЧЕМУ ПОДПИСЬ. До 25.08 строка рисовалась во всю ширину, без стороны и без
// имени: своё и чужое предложение выглядели одинаково, хотя обычные сообщения
// в той же ленте различаются стороной (N164).

const boss = 'boss-uid';
const player = 'player-uid';

JobOffer offer({
  String createdBy = boss,
  List<String>? dates,
  Map<String, List<String>> answers = const {},
  String? acceptedBy,
  String? withdrawnBy,
  String eventType = 'Toy',
}) => JobOffer(
  id: 'offer-1',
  createdBy: createdBy,
  dates: dates ?? const ['2026-08-25', '2026-08-26'],
  eventType: eventType,
  answers: answers,
  acceptedBy: acceptedBy,
  withdrawnBy: withdrawnBy,
);

void main() {
  group('какие даты в каждом состоянии', () {
    String line(JobOffer o) => offerFeedLine(o, recipientUid: player);

    test('ждём ответа — ПРЕДЛОЖЕННЫЕ дни', () {
      expect(line(offer()), '25–26 avqust · 2 gün · Toy · cavab gözlənilir');
    });

    // ОТВЕТИЛИ — ОТМЕЧЕННЫЕ: строка отвечает на «что сейчас в силе».
    // Отказанные дни видны в листе строкой «— yox», и повторять их здесь
    // значит показывать то, чего уже нет.
    //
    // **Число остаётся ДВОЙНЫМ, и это не украшение.** Решение 19.08: «3 gün ·
    // qəbul edildi» не говорило, сколько предлагали, а показывать одно из
    // двух значит выбирать за читателя. Даты вытеснили бы «из скольких», не
    // будь числа рядом.
    test('ответили — ОТМЕЧЕННЫЕ дни и два числа', () {
      expect(
        line(
          offer(
            dates: const ['2026-08-27', '2026-08-28', '2026-08-29'],
            answers: {
              player: const ['2026-08-28', '2026-08-29'],
            },
          ),
        ),
        '28–29 avqust · 2/3 gün · Toy · cavab',
      );
    });

    // ОТКАЗ — ПРЕДЛОЖЕННЫЕ дни (решение владельца 25.08).
    //
    // **РИСК НАЗВАН ЗДЕСЬ, чтобы следующий не «починил» несоответствие.** В
    // четырёх состояниях даты отвечают на «что в силе»; здесь в силе НЕТ
    // НИЧЕГО, и они отвечают на «о чём спрашивали». Один вид, два смысла
    // (I47). Различает **слово состояния**, а не даты.
    //
    // Убрать даты нельзя: два отказа снова стали бы неразличимы — ровно тот
    // дефект, ради которого даты и заводились.
    test('не может ни в один — ПРЕДЛОЖЕННЫЕ дни, одно число', () {
      expect(
        line(offer(answers: {player: const []})),
        '25–26 avqust · 2 gün · Toy · gələ bilmir',
      );
    });

    test('принято — ОТМЕЧЕННЫЕ дни и два числа', () {
      expect(
        line(
          offer(
            answers: {
              player: const ['2026-08-25'],
            },
            acceptedBy: boss,
          ),
        ),
        '25 avqust · 1/2 gün · Toy · qəbul edildi',
      );
    });

    test('отозвано — ПРЕДЛОЖЕННЫЕ дни: в силе не осталось ничего', () {
      expect(
        line(offer(withdrawnBy: boss)),
        '25–26 avqust · 2 gün · Toy · geri götürüldü',
      );
    });

    // ТО, РАДИ ЧЕГО ВСЯ ПРАВКА, и это настоящие два документа из прода
    // (`2OUMbfWR` и `iGaE4pu5`, замер 25.08). До неё обе строки читались
    // «1/2 gün · Toy · qəbul edildi» — одинаково.
    test('два разных принятых предложения теперь различимы', () {
      final a = line(
        offer(
          dates: const ['2026-08-25', '2026-08-26'],
          answers: {
            player: const ['2026-08-25'],
          },
          acceptedBy: boss,
        ),
      );
      final b = line(
        offer(
          dates: const ['2026-08-22', '2026-08-23'],
          answers: {
            player: const ['2026-08-22'],
          },
          acceptedBy: boss,
        ),
      );
      expect(a, isNot(b));
    });
  });

  group('чьё это предложение — N164', () {
    test('своё подписано «Sən təklif etdin»', () {
      expect(
        offerAuthorLine(offer(), viewerUid: boss, initiatorName: 'Rafael'),
        'Sən təklif etdin',
      );
    });

    test('чужое названо по имени', () {
      expect(
        offerAuthorLine(offer(), viewerUid: player, initiatorName: 'Rafael'),
        'Rafael təklif edir',
      );
    });

    // Не знать зовущего неприятно, но «‌ təklif edir» выглядело бы поломкой.
    test('имени нет — «Naməlum», а не пустое место', () {
      expect(
        offerAuthorLine(offer(), viewerUid: player, initiatorName: '   '),
        'Naməlum təklif edir',
      );
    });
  });

  group('строка на экране', () {
    Future<void> pumpRow(
      WidgetTester tester, {
      required JobOffer o,
      String viewer = player,
      String name = 'Rafael',
    }) async {
      // Ширина экрана — та же, что у трубки, на которой мерили: 393 pt.
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfferFeedRow(
              offer: o,
              viewerUid: viewer,
              recipientUid: player,
              initiatorName: name,
            ),
          ),
        ),
      );
    }

    testWidgets('обе стороны подписаны, ни одна не молчит', (tester) async {
      await pumpRow(tester, o: offer(), viewer: player);
      expect(find.text('Rafael təklif edir'), findsOneWidget);

      await pumpRow(tester, o: offer(), viewer: boss);
      expect(find.text('Sən təklif etdin'), findsOneWidget);
    });

    // ДЛИННАЯ СТРОКА ПЕРЕНОСИТСЯ, А НЕ ОБРЕЗАЕТСЯ.
    //
    // Набор настоящий, самый длинный в проде: 18 дат, 14–31 августа. Тип
    // взят на пределе правил — 24 знака (`eventType.size() <= 24`).
    // Обрезка съела бы конец, где стоит состояние.
    testWidgets('самая длинная строка переносится, а не теряет хвост', (
      tester,
    ) async {
      final long = offer(
        dates: [
          for (var d = 14; d <= 31; d++)
            '2026-08-${d.toString().padLeft(2, '0')}',
        ],
        eventType: 'A' * 24,
      );
      await pumpRow(tester, o: long);

      final expected = offerFeedLine(long, recipientUid: player);
      final finder = find.text(expected);
      expect(
        finder,
        findsOneWidget,
        reason: 'строка потеряла часть текста — значит обрезана, а не '
            'перенесена',
      );

      final widget = tester.widget<Text>(finder);
      expect(widget.maxLines, isNull, reason: 'предел строк = обрезка');
      expect(widget.overflow, isNot(TextOverflow.ellipsis));

      // Высота больше одной строки — перенос действительно случился.
      final oneLine = tester.getSize(find.text('Rafael təklif edir')).height;
      expect(
        tester.getSize(finder).height,
        greaterThan(oneLine * 1.5),
        reason: 'текст уместился в одну строку — проверка ничего не доказала',
      );
    });

    // --- ЧЕГО ЭТОТ НАБОР ПРОВЕРИТЬ НЕ МОЖЕТ, И ЭТО СКАЗАНО ПРЯМО (I50) ---
    //
    // **Сколько знаков влезает на трубке — тестом не достаётся.** В прогоне
    // шрифт подменён: каждый знак рисуется квадратом в кегль, то есть 14 pt
    // вместо измеренных 6,84. Любая строка ленты переносится здесь, даже
    // самая короткая, — проверка «переносится» выше поэтому доказывает, что
    // виджет УМЕЕТ переносить, а не что ЭТА строка перенесётся на телефоне.
    //
    // **Числа, снятые с трубки, и что из них следует** (25.08): под текст
    // 295 pt, 6,84 pt на знак → **43 знака**. Типовая строка
    // «25–26 avqust · 2 gün · Toy · cavab gözlənilir» — **45 знаков**, то
    // есть на два длиннее: у самого частого состояния (12 предложений из 19
    // в проде) строка встанет в две. Это **известная цена**, а не находка:
    // перенос выбран вместо обрезки нарочно.
    //
    // Сторожа на длину здесь НЕТ намеренно: проверка «не длиннее 43» падала
    // бы и от улучшения — например от короткого имени месяца, — а от роста
    // строку и так держат правила (`eventType.size() <= 24`).
  });
}
