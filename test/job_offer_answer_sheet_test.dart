import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';
import 'package:mugam_flutter/core/theme/colors.dart';
import 'package:mugam_flutter/features/job_offer/busy_days.dart';
import 'package:mugam_flutter/features/job_offer/screens/job_offer_accept_sheet.dart';
import 'package:mugam_flutter/features/job_offer/screens/job_offer_answer_sheet.dart';

// ЭКРАНЫ ОТВЕТА И ПРИЁМА.
//
// Главное требование автора, вокруг которого и написан набор: ПРИГЛАШЁННЫЙ
// ВИДИТ предложенные дни и свои занятые, но НАЖИМАЕМЫ ТОЛЬКО ПРЕДЛОЖЕННЫЕ.
// Ни одного лишнего дня.
//
// Это вторая половина правила `answerFitsOffer`: сервер отметку постороннего
// дня отвергнет, и экран обязан отвергать её тоже. Иначе человек тапает, а
// запись молча отказывает — на экране это «нажал, и ничего».

const boss = 'boss-uid';
const player = 'player-uid';

JobOffer offer({
  List<String>? dates,
  Map<String, List<String>> answers = const {},
}) => JobOffer(
  id: 'offer-1',
  createdBy: boss,
  dates: dates ?? const ['2026-09-14', '2026-09-15', '2026-09-20'],
  eventType: 'Toy',
  answers: answers,
);

Set<String> tappableDays(WidgetTester tester) {
  const prefix = 'offer-cell-';
  final out = <String>{};
  for (final w in tester.widgetList<GestureDetector>(
    find.byType(GestureDetector),
  )) {
    final k = w.key;
    if (k is ValueKey<String> && k.value.startsWith(prefix) && w.onTap != null) {
      out.add(k.value.substring(prefix.length));
    }
  }
  return out;
}

void main() {
  group('экран ответа приглашённого', () {
    Future<void> pump(
      WidgetTester tester, {
      JobOffer? o,
      Set<String> busy = const {},
      void Function(List<String>)? onSend,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JobOfferAnswerSheet(
              offer: o ?? offer(),
              myUid: player,
              initiatorName: 'Rafael',
              busyDays: busy,
              now: DateTime(2026, 9, 1),
              onSend: onSend ?? (_) {},
            ),
          ),
        ),
      );
    }

    // ГЛАВНЫЙ ТЕСТ ФАЙЛА. Сверяется СОСТАВ нажимаемых дней, а не наличие
    // названных (I13): проверка «14-е нажимается, 21-е нет» прошла бы и
    // тогда, когда нажимается ещё полмесяца сверх предложенного.
    testWidgets('нажимаемы РОВНО предложенные дни, ни одного лишнего', (
      tester,
    ) async {
      await pump(tester);
      expect(tappableDays(tester), {
        '2026-09-14',
        '2026-09-15',
        '2026-09-20',
      });
    });

    testWidgets('занятый день предложения ВЫБИРАЕТСЯ — это предупреждение', (
      tester,
    ) async {
      // Занятость сообщает, а не запрещает: решает человек.
      await pump(tester, busy: {'2026-09-15'});
      expect(tappableDays(tester).contains('2026-09-15'), isTrue);
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-15')));
      await tester.pump();
      expect(find.text('1 gün · 15'), findsOneWidget);
    });

    testWidgets('занятый день ВНЕ предложения всё равно не нажимается', (
      tester,
    ) async {
      await pump(tester, busy: {'2026-09-21'});
      expect(tappableDays(tester).contains('2026-09-21'), isFalse);
    });

    // ПРОШЕДШАЯ ЗАНЯТОСТЬ НЕ ЗАЛИВАЕТСЯ — решение владельца 25.08, по виду
    // на трубке в первый же день подключения.
    //
    // **Довод в одну строку:** заливка здесь не сообщение о календаре, а
    // предупреждение о выборе; на прошедшем дне выбора нет, предупреждать не
    // о чем, а лишняя краска учит глаз игнорировать тот самый цвет, который
    // завтра должен остановить руку.
    //
    // **ОБЕ ПОЛОВИНЫ ПРОВЕРЯЮТСЯ, И ВТОРАЯ НЕ ЛИШНЯЯ:** «прошедший не залит»
    // в одиночку зелено и при заливке, сломанной вовсе. Канарейка рядом
    // требует, чтобы будущий БЫЛ залит, и падает от такой поломки первой.
    group('занятость прошедшего дня не показывается', () {
      // «Сегодня» у набора — 1 сентября 2026 (`pump`), поэтому 28 августа
      // прошедшее, а 2 сентября будущее; оба видны в сетке августа, которая
      // тянется с 27 июля по 6 сентября.
      JobOffer acrossToday() =>
          offer(dates: const ['2026-08-28', '2026-09-02']);

      Color? cellColor(WidgetTester tester, String iso) {
        final container = tester.widget<Container>(
          find
              .descendant(
                of: find.byKey(ValueKey('offer-cell-$iso')),
                matching: find.byType(Container),
              )
              .first,
        );
        return (container.decoration as BoxDecoration?)?.color;
      }

      testWidgets('занятый ПРОШЕДШИЙ день предложения не залит', (
        tester,
      ) async {
        await pump(tester, o: acrossToday(), busy: {'2026-08-28'});
        expect(cellColor(tester, '2026-08-28'), Colors.transparent);
      });

      // КАНАРЕЙКА. Без неё проверка выше зелена и на сетке, разучившейся
      // заливать вообще.
      testWidgets('занятый БУДУЩИЙ день предложения залит', (tester) async {
        await pump(tester, o: acrossToday(), busy: {'2026-09-02'});
        expect(cellColor(tester, '2026-09-02'), kOwnerOther.withAlpha(41));
      });

      // Строка под сеткой обязана молчать вместе с заливкой: сказать «занятые
      // дни тоже можно выбрать» там, где не покрашено ни одной клетки, значит
      // объяснять то, чего человек не видит.
      testWidgets('занятость только в прошлом — строки про выбор нет', (
        tester,
      ) async {
        await pump(tester, o: acrossToday(), busy: {'2026-08-28'});
        expect(find.text(kBusyPickableLine), findsNothing);
      });

      testWidgets('занятость впереди — строка про выбор есть', (tester) async {
        await pump(tester, o: acrossToday(), busy: {'2026-09-02'});
        expect(find.text(kBusyPickableLine), findsOneWidget);
      });
    });

    testWidgets('отмеченные дни доходят до отправки', (tester) async {
      List<String>? sent;
      await pump(tester, onSend: (p) => sent = p);
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-14')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-20')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('answer-send')));
      await tester.pump();
      expect(sent, ['2026-09-14', '2026-09-20']);
    });

    // НОЛЬ — ЗАКОННЫЙ ОТВЕТ, и кнопка не гаснет, а МЕНЯЕТ ПОДПИСЬ. Серая
    // кнопка сказала бы, что ответить «не могу ни на один» нельзя вовсе.
    testWidgets('при нуле кнопка работает и называет это словами', (
      tester,
    ) async {
      List<String>? sent;
      await pump(tester, onSend: (p) => sent = p);

      expect(find.text('Heç birinə gələ bilmirəm'), findsOneWidget);
      expect(find.text('Göndər'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('answer-send')));
      await tester.pump();
      expect(sent, isNotNull, reason: 'кнопка при нуле мертва');
      expect(sent, isEmpty);
    });

    testWidgets('выбрал день — подпись становится «Göndər»', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-14')));
      await tester.pump();
      expect(find.text('Göndər'), findsOneWidget);
      expect(find.text('Heç birinə gələ bilmirəm'), findsNothing);
    });

    testWidgets('прежний ответ подхватывается при открытии', (tester) async {
      await pump(
        tester,
        o: offer(answers: {player: const ['2026-09-15']}),
      );
      expect(find.text('1 gün · 15'), findsOneWidget);
    });
  });

  group('экран приёма инициатора', () {
    Future<void> pump(
      WidgetTester tester, {
      required JobOffer o,
      VoidCallback? onAccept,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JobOfferAcceptSheet(
              offer: o,
              recipientUid: player,
              recipientName: 'Teymur',
              now: DateTime(2026, 9, 1),
              onAccept: onAccept ?? () {},
            ),
          ),
        ),
      );
    }

    // Крупно — согласие, тише — отказ. Отказ не поступок, а сведения.
    testWidgets('согласие показано крупно, отказ отдельной тихой строкой', (
      tester,
    ) async {
      await pump(
        tester,
        o: offer(answers: {player: const ['2026-09-14', '2026-09-20']}),
      );

      expect(find.text('2 gün'), findsOneWidget);
      expect(find.text('14, 20 sentyabr'), findsOneWidget);
      expect(find.text('15 sentyabr — yox'), findsOneWidget);

      final big = tester.widget<Text>(find.byKey(const ValueKey('accept-count')));
      final quiet = tester.widget<Text>(
        find.byKey(const ValueKey('accept-declined')),
      );
      expect(
        big.style!.fontSize! > quiet.style!.fontSize! * 2,
        isTrue,
        reason: 'отказ показан наравне с согласием',
      );
    });

    // На экране приёма выбирать нечего: инициатору править отметки
    // музыканта запрещено правилом.
    testWidgets('ни одна клетка не нажимается', (tester) async {
      await pump(
        tester,
        o: offer(answers: {player: const ['2026-09-14']}),
      );
      expect(tappableDays(tester), isEmpty);
    });

    testWidgets('до ответа принимать нечего — кнопки нет', (tester) async {
      await pump(tester, o: offer());
      expect(find.byKey(const ValueKey('accept-confirm')), findsNothing);
            // Шапка проходит через azUpperCase, поэтому ищем верхним регистром.
      expect(find.textContaining('GÖZLƏN'), findsOneWidget);
    });

    testWidgets('после ответа кнопка есть и нажатие доходит', (tester) async {
      var accepted = false;
      await pump(
        tester,
        o: offer(answers: {player: const ['2026-09-14']}),
        onAccept: () => accepted = true,
      );
      await tester.tap(find.byKey(const ValueKey('accept-confirm')));
      await tester.pump();
      expect(accepted, isTrue);
    });

    // ОТВЕТ НУЛЁМ ДНЕЙ — ПРИНИМАТЬ НЕЧЕГО (решение автора 14.08).
    //
    // Прежняя редакция этого теста ждала кнопку и была неверна: «Qəbul
    // edirəm» над пустым ответом создала бы НОЛЬ вечеров — обещание
    // действия без последствий. Человек нажал бы и остался гадать,
    // сработало или нет.
    testWidgets('ответ нулём дней виден, но принимать нечего', (tester) async {
      await pump(tester, o: offer(answers: {player: const []}));
      expect(find.text('0 gün'), findsOneWidget);
      expect(find.byKey(const ValueKey('accept-confirm')), findsNothing);
    });

    // При нуле отзыв остаётся единственным ходом — и рядом обязано стоять,
    // ЧТО ПОСЛЕ НЕГО БУДЕТ, иначе человек нажмёт и не поймёт, куда всё
    // делось.
    testWidgets('отзыв объясняет своё последствие словами', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JobOfferAcceptSheet(
              offer: offer(answers: {player: const []}),
              recipientUid: player,
              recipientName: 'Teymur',
              now: DateTime(2026, 9, 1),
              onAccept: () {},
              onWithdraw: () {},
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('accept-withdraw')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('accept-withdraw-note')),
        findsOneWidget,
        reason: 'отзыв не сказал, что предложение закроется',
      );
      expect(find.textContaining('yeni təklif'), findsOneWidget);
    });
  });
}
