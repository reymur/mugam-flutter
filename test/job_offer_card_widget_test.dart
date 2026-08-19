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
  VoidCallback? onOpenAnswer,
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
            onOpenAnswer: onOpenAnswer,
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

  // ТРИ ТЕСТА СНЯТЫ ЗДЕСЬ 19.08, И ПРИЧИНА ВАЖНЕЕ САМОГО СНЯТИЯ.
  //
  // Они проверяли отметку дней ВНУТРИ карточки: «Göndər» при пустом наборе,
  // отмеченные дни доходят до отправки, повторное нажатие снимает отметку.
  // Развилка хода 2 решена в пользу экрана (`docs/plan.md`), и путь, по
  // которому они ходили, стал недостижим: `canPickDays` ложен во всех
  // восьми клетках таблицы.
  //
  // **Оставить их живыми было нельзя ни одним честным способом.** Дойти до
  // квадратиков теперь можно только подсунув карточке `OfferCardActions`
  // мимо `offerCardActions` — то есть проверяя не то, что делает
  // приложение, а то, что мы сами же и собрали. Такой тест зелен всегда и
  // не может провалиться (I9).
  //
  // **Что стоит вместо них:** `job_offer_card_test.dart`, «отметка внутри
  // карточки мертва во всех клетках таблицы» — сторож на саму мёртвость.
  // Он падает, если отметка оживёт где угодно, а прежние три этого не
  // ловили: они падали, только если она сломается там, куда они смотрят.
  //
  // Код отметки остаётся в карточке до уборки после шага 2 (I51); эти три
  // теста уходят вместе с ним, и возвращать их поштучно не нужно.

  // ЭТОТ ТЕСТ — ПРЯМОЙ НАСЛЕДНИК N125: мало разрешить действие, оно обязано
  // быть НАРИСОВАНО.
  testWidgets('получателю кнопка ответа нарисована, когда есть куда вести', (
    tester,
  ) async {
    await pump(tester, o: offer(), viewer: player, onOpenAnswer: () {});
    expect(find.byKey(const ValueKey('offer-open-answer')), findsOneWidget);
    expect(find.text('Cavab ver'), findsOneWidget);
  });

  testWidgets('нажатие на кнопку ответа доходит', (tester) async {
    var opened = 0;
    await pump(tester, o: offer(), viewer: player, onOpenAnswer: () => opened++);

    await tester.tap(find.byKey(const ValueKey('offer-open-answer')));
    await tester.pump();

    expect(opened, 1, reason: 'нажатие не дошло — кнопка мертва');
  });

  // СОСТОЯНИЕ ШАГА 1, И ОНО ЗАПИСАНО ТЕСТОМ, А НЕ ТОЛЬКО СЛОВАМИ.
  //
  // Экран ответа не подключён, вести кнопке некуда — и тогда её нет вовсе.
  // Нарисованная кнопка, которая никуда не ведёт, неотличима от поломки:
  // человек нажимает, ничего не происходит, и объяснить это можно чем
  // угодно. Отсутствие объясняется однозначно.
  //
  // **При этом ход остаётся ПРЕДЛОЖЕННЫМ** — `canAnswer` истинен, — и
  // проверяется это здесь же: иначе «кнопки нет» слилось бы с «ход не
  // предложен», а это два разных факта (I47).
  testWidgets('вести некуда — кнопки нет, но ход предложен', (tester) async {
    await pump(tester, o: offer(), viewer: player);

    expect(find.byKey(const ValueKey('offer-open-answer')), findsNothing);
    expect(offerCardActions(offer(), player).canAnswer, isTrue);
  });

  testWidgets('инициатору ответа не предлагают, показывают ожидание', (
    tester,
  ) async {
    await pump(tester, o: offer(), viewer: boss, onOpenAnswer: () {});
    expect(find.byKey(const ValueKey('offer-open-answer')), findsNothing);
    expect(find.byKey(const ValueKey('offer-accept')), findsNothing);
    // ФРАЗА ЦЕЛИКОМ, А НЕ ПОДСТРОКА. Прежде здесь стояло
    // `textContaining('cavabı gözlənilir')`, и оно прошло бы при любом
    // окончании у имени — а именно окончание и было неверным
    // («Teymurun» вместо «Teymurdan», исправлено владельцем 19.08).
    // Подстрока проверяла ту часть фразы, которая не менялась.
    expect(find.text('Teymurdan cavab gözlənilir'), findsOneWidget);
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

    // ПЕРЕВЁРНУТО 19.08 — И ЭТО ТА САМАЯ ПРИЧИНА, ПО КОТОРОЙ ОТВЕТ УЕХАЛ НА
    // ЭКРАН.
    //
    // Прежде здесь стояло «отмечающий видит все тридцать дней сразу»:
    // свёрнутый список прятал бы то, что он обязан протыкать. Это верно,
    // пока тыкают в ленте, — и ровно поэтому лента получала тридцать строк
    // с квадратиками. Развилка решена в пользу экрана, значит в ленте
    // тыкать не нужно, и список сворачивается У ВСЕХ.
    testWidgets('получателю длинный список тоже свёрнут', (tester) async {
      await pump(tester, o: offer(dates: month), viewer: player);
      expect(renderedDays(tester).length, 5);
      expect(find.text('yenə 25 gün'), findsOneWidget);
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

    // ПОСЛЕ ОТВЕТА КАРТОЧКА СТАЛА СВОДКОЙ И У ПОЛУЧАТЕЛЯ ТОЖЕ — следствие
    // того же решения, и найдено оно этим тестом, а не предугадано.
    //
    // Список строится как «ответил и тронуть нельзя → только отмеченные».
    // Пока отмечали в ленте, вторая половина условия была ложна у
    // получателя, и он после ответа видел все тридцать дней — иначе
    // переотметить было бы нечего. Ответ уехал на экран, тронуть нельзя
    // никому, и обе стороны видят одно: три дня, на которые согласились,
    // плюс мелкую строку «— yox» под ними.
    //
    // Это не потеря: переответить по-прежнему можно, и все тридцать дней
    // человек увидит там, где и отвечает, — на экране.
    testWidgets('после ответа получателю показаны ТОЛЬКО отмеченные дни', (
      tester,
    ) async {
      await pump(
        tester,
        o: offer(dates: month, answers: {player: month.take(3).toList()}),
        viewer: player,
      );

      expect(renderedDays(tester), month.take(3).toSet());
      // Три меньше порога сворачивания — прятать нечего.
      expect(find.byKey(const ValueKey('offer-days-expand')), findsNothing);
    });

    // КАНАРЕЙКА К ДВУМ ПРЕДЫДУЩИМ: разворот по-прежнему работает и у
    // получателя. Без неё «свёрнут» было бы верно и для списка, который не
    // разворачивается вовсе, — то есть для поломки.
    testWidgets('получатель разворачивает список нажатием', (tester) async {
      await pump(tester, o: offer(dates: month), viewer: player);
      await tester.tap(find.byKey(const ValueKey('offer-days-expand')));
      await tester.pump();
      expect(renderedDays(tester).length, 30);
    });
  });
}
