import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';
import 'package:mugam_flutter/features/job_offer/widgets/job_offer_card.dart';

// ВТОРАЯ ПОЛОВИНА ЗАЩИТЫ — на стороне ПОКАЗА.
//
// `job_offer_card_test.dart` держит таблицу «состояние × роль → что
// предложено» и молчит о том, НАРИСОВАНО ли предложенное. Ровно этот зазор
// и стоил N125: кнопки ответа были живы в коде, а на экране их не было —
// тринадцать часов в проде при 569 зелёных тестах.
//
// Здесь проверяется то, что таблица проверить не может: что предложенное
// действительно на экране и что нажатие доходит.

const boss = 'boss-uid';
const player = 'player-uid';

JobOffer offer({
  Map<String, List<String>> answers = const {},
  String? acceptedBy,
  String? withdrawnBy,
  List<String>? dates,
}) => JobOffer(
  id: 'offer-1',
  createdBy: boss,
  dates: dates ?? const ['2026-08-09', '2026-08-10', '2026-08-11'],
  eventType: 'Toy',
  answers: answers,
  acceptedBy: acceptedBy,
  withdrawnBy: withdrawnBy,
);

Future<void> pump(
  WidgetTester tester, {
  required JobOffer o,
  required String viewer,
  void Function(List<String>)? onSend,
  VoidCallback? onAccept,
  Set<String> busy = const {},
}) async {
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
            busyDates: busy,
            onSendAnswer: onSend,
            onAccept: onAccept,
          ),
        ),
      ),
    ),
  );
}

/// Все дни, НАРИСОВАННЫЕ карточкой, — множеством, а не поштучно. Ключи вида
/// `offer-day-<iso>` ставятся на каждую отмечаемую строку.
Set<String> renderedDays(WidgetTester tester) {
  const prefix = 'offer-day-';
  return tester
      .widgetList(
        find.byWidgetPredicate((w) {
          final k = w.key;
          return k is ValueKey<String> && k.value.startsWith(prefix);
        }),
      )
      .map((w) => (w.key as ValueKey<String>).value.substring(prefix.length))
      .toSet();
}

void main() {
  // ТРЕБОВАНИЕ 3 — ДЕНЬ НЕ ИЗ `dates` ОТМЕТИТЬ НЕЛЬЗЯ, И НА ЭКРАНЕ ТАКОЙ
  // ВОЗМОЖНОСТИ БЫТЬ НЕ ДОЛЖНО. Правило это запрещает (`answerFitsOffer`),
  // но кнопка, которой правило откажет, человеку видна как «нажал и
  // ничего». Список строк обязан приходить из `offer.dates` и ниоткуда
  // больше — здесь это и проверяется составом, а не количеством (I13).
  //
  // СВЕРЯЕТСЯ СОСТАВ, А НЕ НАЛИЧИЕ НАЗВАННЫХ (I13), и это не педантизм:
  // первая редакция этого теста перечисляла два ожидаемых дня и один
  // заведомо отсутствующий — и **проверкой возвратом выяснилось, что она не
  // ловит ничего**. Порча, подсунувшая в список посторонний день
  // (`2026-08-31`), оставила все одиннадцать тестов зелёными: названного
  // отсутствующего дня среди подсунутых не было. Тест сторожил ровно то,
  // что в нём перечислено, а требование — про ВСЕ дни, которых в `dates`
  // нет. Сравнение множеств врёт заметно: лишний день назовёт себя сам.
  testWidgets('строки дней строятся РОВНО из dates', (tester) async {
    await pump(
      tester,
      o: offer(dates: const ['2026-08-09', '2026-08-11']),
      viewer: player,
    );

    expect(renderedDays(tester), {'2026-08-09', '2026-08-11'});
    expect(find.textContaining('9 avqust'), findsOneWidget);
    expect(find.textContaining('11 avqust'), findsOneWidget);
  });

  // ТРЕБОВАНИЕ 2 — ОТМЕТКА НУЛЯ ДНЕЙ ЗАКОННА, КНОПКА ОБЯЗАНА РАБОТАТЬ.
  // Серая кнопка здесь означала бы, что ответить «не могу ни на один день»
  // нельзя вовсе: отдельного отказа в этой работе нет, неотмеченные дни и
  // значат «нет».
  testWidgets('«Göndər» работает при ПУСТОМ наборе отметок', (tester) async {
    List<String>? sent;
    await pump(tester, o: offer(), viewer: player, onSend: (p) => sent = p);

    await tester.tap(find.byKey(const ValueKey('offer-send')));
    await tester.pump();

    expect(sent, isNotNull, reason: 'нажатие не дошло — кнопка мертва');
    expect(sent, isEmpty);
  });

  testWidgets('отмеченные дни доходят до отправки', (tester) async {
    List<String>? sent;
    await pump(tester, o: offer(), viewer: player, onSend: (p) => sent = p);

    await tester.tap(find.byKey(const ValueKey('offer-day-2026-08-09')));
    await tester.tap(find.byKey(const ValueKey('offer-day-2026-08-11')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('offer-send')));
    await tester.pump();

    expect(sent, ['2026-08-09', '2026-08-11']);
  });

  testWidgets('повторное нажатие снимает отметку', (tester) async {
    List<String>? sent;
    await pump(tester, o: offer(), viewer: player, onSend: (p) => sent = p);

    await tester.tap(find.byKey(const ValueKey('offer-day-2026-08-09')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('offer-day-2026-08-09')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('offer-send')));
    await tester.pump();

    expect(sent, isEmpty);
  });

  // ЭТОТ ТЕСТ — ПРЯМОЙ НАСЛЕДНИК N125.
  testWidgets('получателю кнопка ответа НАРИСОВАНА, а не только разрешена', (
    tester,
  ) async {
    await pump(tester, o: offer(), viewer: player);
    expect(find.byKey(const ValueKey('offer-send')), findsOneWidget);
    expect(find.text('Göndər'), findsOneWidget);
  });

  testWidgets('инициатору ответа не предлагают, показывают ожидание', (
    tester,
  ) async {
    await pump(tester, o: offer(), viewer: boss);
    expect(find.byKey(const ValueKey('offer-send')), findsNothing);
    expect(find.byKey(const ValueKey('offer-accept')), findsNothing);
    expect(find.textContaining('cavabı gözlənilir'), findsOneWidget);
  });

  testWidgets('после ответа инициатору нарисовано «Qəbul edirəm»', (
    tester,
  ) async {
    var accepted = false;
    await pump(
      tester,
      o: offer(answers: {player: const ['2026-08-09']}),
      viewer: boss,
      onAccept: () => accepted = true,
    );

    expect(find.text('Qəbul edirəm'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('offer-accept')));
    await tester.pump();
    expect(accepted, isTrue);
  });

  testWidgets('неотмеченные дни показаны мелкой строкой «— yox»', (
    tester,
  ) async {
    await pump(
      tester,
      o: offer(answers: {player: const ['2026-08-09']}),
      viewer: boss,
    );
    expect(find.textContaining('yox'), findsOneWidget);
  });

  // `məşğulsan` БЕЗ ИМЕНИ ЗАНЯВШЕГО — приватность, а не краткость.
  testWidgets('занятый день помечен, и имя занявшего не показано', (
    tester,
  ) async {
    await pump(
      tester,
      o: offer(),
      viewer: player,
      busy: const {'2026-08-10'},
    );
    expect(find.text('məşğulsan'), findsOneWidget);
    expect(find.textContaining('Rafael'), findsNothing);
  });

  testWidgets('закрытый раунд не рисует ни одного действия', (tester) async {
    await pump(tester, o: offer(acceptedBy: boss), viewer: player);
    expect(find.byKey(const ValueKey('offer-send')), findsNothing);
    expect(find.byKey(const ValueKey('offer-accept')), findsNothing);
    expect(find.byKey(const ValueKey('offer-voice')), findsNothing);
    expect(find.byKey(const ValueKey('offer-withdraw')), findsNothing);
  });

  testWidgets('отозванное предложение остаётся в ленте с пометкой', (
    tester,
  ) async {
    await pump(tester, o: offer(withdrawnBy: boss), viewer: player);
    expect(find.textContaining('geri götürüldü'), findsWidgets);
  });

  // ДЛИННЫЙ НАБОР ДНЕЙ. Предела на число дней нет нигде (решение автора
  // 14.08), значит месяц целиком законен, и карточка обязана его пережить.
  group('месяц целиком', () {
    final month = List.generate(
      30,
      (i) => '2026-09-${(i + 1).toString().padLeft(2, '0')}',
    );

    // У ТОГО, КТО ОТМЕЧАЕТ, СПИСОК ПОЛНЫЙ И НЕ СВОРАЧИВАЕТСЯ. Свёрнутый
    // прячет ровно то, что он обязан протыкать.
    testWidgets('отмечающий видит все тридцать дней сразу', (tester) async {
      await pump(tester, o: offer(dates: month), viewer: player);
      expect(renderedDays(tester).length, 30);
      expect(find.byKey(const ValueKey('offer-days-expand')), findsNothing);
    });

    testWidgets('нередактируемый список свёрнут, и остаток назван числом', (
      tester,
    ) async {
      await pump(
        tester,
        o: offer(dates: month, answers: {player: month}),
        viewer: boss,
      );
      // Пять показаны, двадцать пять спрятаны и названы числом.
      expect(find.text('yenə 25 gün'), findsOneWidget);
    });

    testWidgets('свёрнутый список разворачивается нажатием', (tester) async {
      await pump(
        tester,
        o: offer(dates: month, answers: {player: month}),
        viewer: boss,
      );
      await tester.tap(find.byKey(const ValueKey('offer-days-expand')));
      await tester.pump();
      expect(find.byKey(const ValueKey('offer-days-expand')), findsNothing);
    });

    // ЭКОНОМИЯ ДОЛЖНА БЫТЬ НАСТОЯЩЕЙ: восемь дней не сворачиваются, хотя
    // показываем мы пять. Свернуть их значило бы спрятать три ради одного
    // нажатия — и «yenə 3 gün» под списком из пяти.
    testWidgets('восемь дней не сворачиваются', (tester) async {
      final eight = List.generate(
        8,
        (i) => '2026-09-0${i + 1}',
      );
      await pump(
        tester,
        o: offer(dates: eight, answers: {player: eight}),
        viewer: boss,
      );
      expect(find.byKey(const ValueKey('offer-days-expand')), findsNothing);
    });

    // А девять — сворачиваются, и прячут четыре: меньшее «yenə» из
    // возможных. Пара к предыдущему: без неё «не сворачивается» было бы
    // верно и для порога в тысячу.
    testWidgets('девять дней сворачиваются и прячут четыре', (tester) async {
      final nine = List.generate(
        9,
        (i) => '2026-09-0${i + 1}',
      );
      await pump(
        tester,
        o: offer(dates: nine, answers: {player: nine}),
        viewer: boss,
      );
      expect(find.text('yenə 4 gün'), findsOneWidget);
    });

    testWidgets('короткий список не сворачивается вовсе', (tester) async {
      await pump(
        tester,
        o: offer(answers: {player: const ['2026-08-09', '2026-08-10']}),
        viewer: boss,
      );
      expect(find.byKey(const ValueKey('offer-days-expand')), findsNothing);
    });

    // ОТМЕЧАЮЩИЙ ВИДИТ ВСЁ ДАЖЕ ПОСЛЕ ТОГО, КАК УЖЕ ОТВЕЧАЛ. Раунд открыт,
    // значит он может переотметить — а переотметить можно только то, что
    // видно. Отдельной строкой, потому что случай «уже отвечал» ходит по
    // другой ветке показа, чем «ещё не отвечал».
    testWidgets('отмечающий видит всё и после своего ответа', (tester) async {
      await pump(
        tester,
        o: offer(dates: month, answers: {player: month.take(3).toList()}),
        viewer: player,
      );
      expect(renderedDays(tester).length, 30);
      expect(find.byKey(const ValueKey('offer-days-expand')), findsNothing);
    });
  });
}
