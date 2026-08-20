import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';
import 'package:mugam_flutter/firebase/firestore_service.dart';
import 'package:mugam_flutter/features/job_offer/screens/job_offer_sheet.dart';

// ЖИВОЕ ОБНОВЛЕНИЕ ЛИСТА — N143.
//
// Карточка в ленте перерисовывалась сама, и ни строки под это в ней нет:
// сверху стоял `StreamBuilder`, а `didUpdateWidget` подхватывал правку с
// другого телефона. **Всё это давало МЕСТО, где она стояла.** Лист —
// отдельный маршрут, и даром он этого не получает.
//
// --- ЧТО ЭТОТ НАБОР ПРОВЕРЯЕТ И ЧЕГО НЕ ПРОВЕРЯЕТ (I50) ---
//
// Проверяет: лист перерисовывается НА КАЖДУЮ ВЫДАЧУ потока — то есть
// правка, пришедшая с другой трубки, доезжает до экрана без закрытия и
// повторного открытия.
//
// **НЕ проверяет дорогу `JobOfferRepository` → `snapshots()` → лист.**
// Поток подменён (`debugOffers`), потому что поднять Firestore в тесте
// нечем. Настоящая подписка остаётся непокрытой, и держится она чтением:
// собирается в `initState`, отписку делает `StreamBuilder`.
//
// **Чем это проверяется вместо теста:** глазами на двух трубках — открыть
// лист у отправителя, ответить с другой и не закрывать лист. Шаг записан в
// `docs/check-job-offer-card.md`.

const boss = 'boss-uid';
const player = 'player-uid';

JobOffer offer({Map<String, List<String>> answers = const {}}) => JobOffer(
  id: 'offer-1',
  createdBy: boss,
  dates: const ['2026-08-09', '2026-08-10', '2026-08-11'],
  eventType: 'Toy',
  answers: answers,
);

Future<void> pumpSheet(
  WidgetTester tester,
  Stream<List<JobOffer>> stream, {
  String offerId = 'offer-1',
  // СМОТРЯЩИЙ ПО УМОЛЧАНИЮ — ИНИЦИАТОР, и это не произвол: так были
  // написаны все проверки N143 до 20.08, и менять их основание заодно с
  // шагом 2 значило бы смешать две правки. Шаг 2 передаёт `player` явно.
  String viewerUid = boss,
  Future<void> Function(List<String> picked)? onWrite,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      // ПОДМЕНЁН ОДИН ПРОВАЙДЕР — СОСТАВ ЧАТА, и только он нужен.
      //
      // Из состава лист берёт uid получателя, а без него `pickedBy` не
      // найдёт ответа и заголовок остался бы «3 gün» даже после ответа —
      // то есть главная проверка набора прошла бы по неверной причине.
      //
      // Имена НЕ подменяются намеренно: провайдер карточки пользователя
      // без Firestore отдаёт ошибку, `.value` даёт `null`, имя выходит
      // пустым — и это здесь безразлично, ни одна проверка на имя не
      // смотрит. Подменять то, что не проверяется, значит заводить
      // строительные леса, которые потом сами станут предметом заботы.
      overrides: [
        chatDataProvider('chat-1').overrideWith(
          (ref) async => <String, dynamic>{
            'members': [boss, player],
          },
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: JobOfferSheet(
            chatId: 'chat-1',
            offerId: offerId,
            debugOffers: stream,
            debugViewerUid: viewerUid,
            debugWriteAnswer: onWrite,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('лист живёт потоком, а не одним снимком (N143)', () {
    // ГЛАВНЫЙ ТЕСТ НАБОРА. Он и есть ответ на «чем поймать лист, НЕ
    // подхватывающий правку из базы».
    testWidgets('лист подхватывает правку, пришедшую с другой трубки', (
      tester,
    ) async {
      final controller = StreamController<List<JobOffer>>();
      addTearDown(controller.close);

      await pumpSheet(tester, controller.stream);

      // Первая выдача: ответа ещё нет.
      controller.add([offer()]);
      await tester.pump();
      expect(find.text('3 gün · Toy'), findsOneWidget);

      // ВТОРАЯ ВЫДАЧА — та самая правка с другой трубки. Лист НЕ
      // закрывался и не открывался заново.
      controller.add([
        offer(answers: {player: const ['2026-08-09', '2026-08-10']}),
      ]);
      await tester.pump();

      expect(
        find.text('2 gün'),
        findsOneWidget,
        reason: 'лист остался на первом снимке — правка с другой трубки не '
            'доехала, и человек видит устаревшее',
      );
    });

    // КАНАРЕЙКА, БЕЗУСЛОВНАЯ: без неё «правка доехала» неотличимо от
    // «лист рисует что попало». Первая выдача обязана быть показана —
    // иначе проверять вторую не на чем.
    testWidgets('первая выдача показана', (tester) async {
      final controller = StreamController<List<JobOffer>>();
      addTearDown(controller.close);

      await pumpSheet(tester, controller.stream);
      controller.add([offer()]);
      await tester.pump();

      expect(find.text('3 gün · Toy'), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-day-2026-08-09')), findsOneWidget);
    });

    // ТРИ СОСТОЯНИЯ, И ДВА ИЗ НИХ НЕЛЬЗЯ СВОДИТЬ К ОДНОМУ (N133 в новом
    // месте): «ещё не пришло» и «предложение удалено» на экране разные.

    testWidgets('до первой выдачи — полоска, а не пустота и не «удалено»', (
      tester,
    ) async {
      final controller = StreamController<List<JobOffer>>();
      addTearDown(controller.close);

      await pumpSheet(tester, controller.stream);
      await tester.pump();

      expect(find.byKey(const ValueKey('offer-sheet-waiting')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-sheet-deleted')), findsNothing);
    });

    testWidgets('выдача пришла, предложения нет — «Təklif silinib»', (
      tester,
    ) async {
      final controller = StreamController<List<JobOffer>>();
      addTearDown(controller.close);

      await pumpSheet(tester, controller.stream);
      controller.add(const []);
      await tester.pump();

      expect(find.text('Təklif silinib'), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-sheet-waiting')), findsNothing);
    });

    // ЛИСТ НЕ ЗАКРЫВАЕТСЯ САМ — решение автора 19.08. Схлопнувшийся сам
    // лист неотличим от промаха пальцем и от падения приложения.
    testWidgets('удалённое предложение не закрывает лист само', (tester) async {
      final controller = StreamController<List<JobOffer>>();
      addTearDown(controller.close);

      await pumpSheet(tester, controller.stream);
      controller.add([offer()]);
      await tester.pump();

      controller.add(const []);
      // `pump`, А НЕ `pumpAndSettle`, И ЭТО НЕ ПРИДИРКА.
      //
      // Состояние ожидания рисует бесконечную полоску прогресса —
      // «успокоиться» ей не на чем, и `pumpAndSettle` виснет НАВСЕГДА.
      // Обнаружилось порчей: тест не покраснел, а ПОВИС, и прогон пришлось
      // снимать по времени. Повисший тест хуже упавшего — он не говорит
      // ничего и съедает весь прогон.
      await tester.pump();

      // Лист на месте: фраза и кнопка закрытия нарисованы, а не «ничего».
      expect(find.text('Təklif silinib'), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-sheet-close')), findsOneWidget);
    });

    // Чужое предложение в той же выдаче не подменяет наше: поток отдаёт ВСЕ
    // предложения чата, лист берёт своё по id.
    testWidgets('соседнее предложение не подменяет наше', (tester) async {
      final controller = StreamController<List<JobOffer>>();
      addTearDown(controller.close);

      await pumpSheet(tester, controller.stream, offerId: 'offer-1');
      controller.add([
        JobOffer(
          id: 'offer-2',
          createdBy: boss,
          dates: const ['2026-08-20'],
          eventType: 'Konsert',
        ),
        offer(),
      ]);
      await tester.pump();

      expect(find.text('3 gün · Toy'), findsOneWidget);
      expect(find.textContaining('Konsert'), findsNothing);
    });
  });

  // ШАГ 2 — ПРОВОДКА ОТВЕТА. СТОРОЖ СТОИТ ЗДЕСЬ, А НЕ В НАБОРЕ КАРТОЧКИ,
  // И ЭТО ГЛАВНОЕ В ЭТОЙ ГРУППЕ (N151).
  //
  // До 20.08 растяжка на шаг 2 стояла в `offer_card_in_feed_test.dart` и
  // была привязана не к той нити: она строила `JobOfferCard` напрямую и
  // проверяла договор виджета, верный и до, и после подключения. Натянуть
  // её подключением было нельзя. Здесь поднимается `JobOfferSheet` — то
  // самое место, где проводка живёт, — и потому эти тесты падают ровно
  // тогда, когда падать должны.
  //
  // **Признак, ради которого всё это записано: растяжка ставится на нить,
  // которую натянет ИМЕННО ТО событие. Проверяется одним вопросом — какая
  // правка её уронит, и та ли это правка, ради которой она поставлена.**
  group('шаг 2: ответ музыканта доходит до записи', () {
    // ДНИ БЕРУТСЯ ОТ СЕГОДНЯШНЕГО ЧИСЛА, А НЕ ВПИСЫВАЮТСЯ РУКАМИ, И ЭТО НЕ
    // ПЕДАНТИЗМ — БЕЗ ЭТОГО ТЕСТ ПРОТУХАЕТ ПО КАЛЕНДАРЮ.
    //
    // Клетка сетки нажимаема, только если день не прошёл
    // (`isPastDay`, `offer_month_grid.dart:118`). Набор выше пользуется
    // датами 2026-08-09…11, и 20.08 они УЖЕ В ПРОШЛОМ: первая редакция
    // этих тестов на них и споткнулась — нажатия проходили мимо, до записи
    // доезжал пустой список, а выглядело это как «ответ не доходит».
    //
    // Соседний набор (`job_offer_answer_sheet_test.dart`) обходит это
    // подменой `now`. Здесь подменить нечем: путь идёт через
    // `JobOfferSheet`, а он про `now` не знает и знать не должен —
    // заводить ради теста ещё один шов значило бы лечить симптом.
    //
    // Вписанные руками «через месяц» тоже не годятся: они верны до
    // следующего месяца. Дни считаются от `DateTime.now()`.
    // БЕРЁТСЯ 10–12-Е СЛЕДУЮЩЕГО МЕСЯЦА, А НЕ «СЕГОДНЯ ПЛЮС N».
    //
    // Лист открывается на месяце ПЕРВОГО дня предложения, и день из
    // соседнего месяца оказался бы вне сетки — ненажимаемым. «Сегодня плюс
    // 30/31/32» этого не гарантирует: у края месяца тройка разъезжается, и
    // тест падал бы один раз в месяц по календарю, а не по коду.
    //
    // Десятое число следующего месяца существует всегда, тройка 10-11-12
    // всегда в одном месяце, и она всегда в будущем.
    String iso(int day) {
      final now = DateTime.now();
      final d = DateTime(now.year, now.month + 1, day);
      final mm = d.month.toString().padLeft(2, '0');
      final dd = d.day.toString().padLeft(2, '0');
      return '${d.year}-$mm-$dd';
    }

    JobOffer futureOffer() => JobOffer(
      id: 'offer-1',
      createdBy: boss,
      dates: [iso(10), iso(11), iso(12)],
      eventType: 'Toy',
    );

    // КАНАРЕЙКА БЕЗУСЛОВНАЯ И ПЕРВАЯ. Все проверки ниже нажимают кнопку;
    // если её нет, они упадут по причине «не нашли кнопку», а не по своей.
    testWidgets('получателю кнопка ответа нарисована — экран подключён', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        Stream.value([futureOffer()]),
        viewerUid: player,
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('offer-open-answer')), findsOneWidget);
      expect(find.text('Cavab ver'), findsOneWidget);
    });

    // ХОД НЕ РАЗДАН ВСЕМ ПОДРЯД. Без этой проверки «кнопка есть у
    // получателя» не отличалось бы от «кнопка есть у каждого», а инициатору
    // отвечать на своё же предложение нельзя — правило откажет
    // (`!isInitiator()` в `firestore.rules:802`), и человеку это видно как
    // «нажал и ничего».
    testWidgets('инициатору кнопки ответа не рисуют', (tester) async {
      await pumpSheet(
        tester,
        Stream.value([futureOffer()]),
        viewerUid: boss,
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('offer-open-answer')), findsNothing);
    });

    testWidgets('нажатие на «Cavab ver» открывает лист ответа', (tester) async {
      await pumpSheet(
        tester,
        Stream.value([futureOffer()]),
        viewerUid: player,
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('offer-open-answer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const ValueKey('answer-send')), findsOneWidget);
      // Лист открыт про НАШЕ предложение: клетки его дней нажимаемы.
      expect(
        find.byKey(ValueKey('offer-cell-${iso(10)}')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('answer-summary')), findsOneWidget);
    });

    // ЗАНЯТОСТЬ НЕ ПОДКЛЮЧЕНА, И ЛИСТ ГОВОРИТ ЭТО СЛОВАМИ.
    //
    // Проверка стоит здесь, а не в наборе листа ответа, потому что
    // утверждение здесь про ПРОВОДКУ: `busyUnknown: true` ставит
    // `job_offer_sheet.dart`, а не сам лист. Снимут занятость с полки —
    // этот тест обязан покраснеть, и это уже правильная нить.
    testWidgets('занятость не показана — сказано словами', (tester) async {
      await pumpSheet(
        tester,
        Stream.value([futureOffer()]),
        viewerUid: player,
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('offer-open-answer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const ValueKey('answer-busy-unknown')),
        findsOneWidget,
        reason: 'пустая сетка утверждает «всё свободно» — а мы не знаем',
      );
    });

    // --- ЧЕГО ДВЕ ПРОВЕРКИ НИЖЕ НЕ ДОКАЗЫВАЮТ (I50) ---
    //
    // ОНИ НЕ ДОКАЗЫВАЮТ, ЧТО В БАЗУ ЗАПИСАЛОСЬ. Проверка доходит до вызова
    // записи с точными доводами и **ни на шаг дальше**: последний стык,
    // `setMyAnswer` → Firestore, тестом не достаётся. Подделки Firestore в
    // проекте нет (`fake_cloud_firestore`, `mocktail`, `mockito` — ни одной
    // в `pubspec.yaml`, замер 20.08), эмулятор есть только у `functions`.
    //
    // **Порча тела `setMyAnswer` не уронит здесь ничего.** Зелёный прогон
    // означает «ответ дошёл до писателя целым», а не «ответ в базе».
    // Записано затем, чтобы через неделю эти два теста не прочли как
    // доказательство записи.
    //
    // Правило на сам ход (`firestore.rules:801-806`) не сторожится тоже —
    // парного теста у него нет ни одного (N152).
    testWidgets('ответ доходит до записи целиком и отсортированным', (
      tester,
    ) async {
      List<String>? written;
      await pumpSheet(
        tester,
        Stream.value([futureOffer()]),
        viewerUid: player,
        onWrite: (picked) async => written = picked,
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('offer-open-answer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // КЛЕТКИ СЕТКИ — `offer-cell-<iso>`, А НЕ `offer-day-<iso>`. Второе —
      // строки карточки, которая лежит ПОД модалкой и в ней остаётся
      // найдена. Ключи разные не случайно: карточка дни только показывает,
      // отмечает их сетка.
      //
      // Отмечаем В ОБРАТНОМ ПОРЯДКЕ — иначе «отсортированным» проверялось
      // бы совпадением с порядком нажатий, то есть ничем.
      await tester.tap(find.byKey(ValueKey('offer-cell-${iso(12)}')));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('offer-cell-${iso(10)}')));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('answer-send')));
      await tester.pump();

      expect(written, [iso(10), iso(12)]);
    });

    // НОЛЬ ДНЕЙ — ЗАКОННЫЙ ОТВЕТ, А НЕ ОТКАЗ ОТ ОТВЕТА, и проводка обязана
    // донести его как есть. Перехватить пустой список по дороге значило бы
    // отнять у человека единственный способ сказать «не могу ни на один».
    testWidgets('ноль дней доходит до записи как ноль, а не как отказ', (
      tester,
    ) async {
      List<String>? written;
      var called = 0;
      await pumpSheet(
        tester,
        Stream.value([futureOffer()]),
        viewerUid: player,
        onWrite: (picked) async {
          called++;
          written = picked;
        },
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('offer-open-answer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(const ValueKey('answer-send')));
      await tester.pump();

      // ДВА УТВЕРЖДЕНИЯ, И ВТОРОЕ НЕ ЛИШНЕЕ: без `called` пустой список
      // не отличался бы от «записи не было вовсе» — оба оставили бы
      // `written` таким, каким видит его этот тест (I47).
      expect(called, 1, reason: 'ответ нулём дней не дошёл до записи вовсе');
      expect(written, isEmpty);
    });
  });
}
