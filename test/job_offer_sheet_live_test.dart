import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';
import 'package:mugam_flutter/core/theme/colors.dart';
import 'package:mugam_flutter/features/job_offer/busy_days.dart';
import 'package:mugam_flutter/firebase/firestore_service.dart';
import 'package:mugam_flutter/firebase/models.dart';
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

/// Вечер календаря — тот путь внутрь модели, которым он приходит в проде
/// (карта ответов у `PersonalEvent` закрыта, конструктором её не передать).
PersonalEvent calendarEvent(String id, {required String owner, required String date}) =>
    PersonalEvent.fromFirestore(id, {
      'ownerUid': owner,
      'date': date,
      'musicians': const <String>[],
      'answersWrittenByOwner': true,
      'status': 'agreed',
    });

Future<void> pumpSheet(
  WidgetTester tester,
  Stream<List<JobOffer>> stream, {
  String offerId = 'offer-1',
  // СМОТРЯЩИЙ ПО УМОЛЧАНИЮ — ИНИЦИАТОР, и это не произвол: так были
  // написаны все проверки N143 до 20.08, и менять их основание заодно с
  // шагом 2 значило бы смешать две правки. Шаг 2 передаёт `player` явно.
  String viewerUid = boss,
  Future<void> Function(List<String> picked)? onWrite,
  /// Подмена записи ПРИЁМА. Появилась 25.08 вместе с тем, что приём
  /// предлагается прямо в двери: без неё нажатие «Qəbul edirəm» ушло бы в
  /// настоящий `JobOfferRepository`, то есть в неподнятый Firestore.
  Future<void> Function(JobOffer offer)? writeAccept,
  // КАЛЕНДАРЬ, ключом — ЧЕЙ. Ключ здесь несёт проверку: лист обязан спросить
  // календарь СМОТРЯЩЕГО, и «спросил не того» видно по тому, что у остальных
  // ключей поток пуст.
  //
  // `null` — поток НЕ ОТВЕТИЛ (не пустой список: пустой список это ответ
  // «ничего нет»). Умолчание `null` у обоих оставлено нарочно: проверки, для
  // которых занятость безразлична, не должны молча получать «знаем, что
  // свободно» — утверждение, которого они не делают.
  Map<String, List<PersonalEvent>>? own,
  Map<String, List<PersonalEvent>>? asParticipant,
}) async {
  Stream<List<PersonalEvent>> calendar(
    Map<String, List<PersonalEvent>>? map,
    String uid,
  ) {
    if (map == null) return StreamController<List<PersonalEvent>>().stream;
    return Stream.value(map[uid] ?? const <PersonalEvent>[]);
  }

  await tester.pumpWidget(
    ProviderScope(
      // ПОДМЕНЕНЫ ТРИ ПРОВАЙДЕРА — СОСТАВ ЧАТА И ДВА ПОТОКА КАЛЕНДАРЯ.
      //
      // Из состава лист берёт uid получателя, а без него `pickedBy` не
      // найдёт ответа и заголовок остался бы «3 gün» даже после ответа —
      // то есть главная проверка набора прошла бы по неверной причине.
      //
      // ПОТОКИ КАЛЕНДАРЯ ПОДМЕНЕНЫ С 25.08, И БЕЗ ЭТОГО СТОРОЖ ЗАНЯТОСТИ БЫЛ
      // БЫ СЛЕПЫМ. Не подмени их — `FirestoreService()` трогает
      // `FirebaseFirestore.instance` прямо в поле, Firebase в тесте не поднят,
      // создатель провайдера бросает, riverpod превращает это в `AsyncError`,
      // и лист показывает «занятости не знаем». То есть тот же экран, что при
      // работающей проводке в состоянии загрузки: проверка зелена и при
      // целой проводке, и при вырванной (N160).
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
        personalEventsProvider.overrideWith(
          (ref, uid) => calendar(own, uid),
        ),
        eventsAsParticipantProvider.overrideWith(
          (ref, uid) => calendar(asParticipant, uid),
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
            debugWriteAccept: writeAccept,
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

      // ПРИЗНАК СМЕНИЛСЯ ВМЕСТЕ С ДВЕРЬЮ (25.08), А ПРОВЕРКА — НЕТ.
      //
      // Прежде здесь искали текст «2 gün» на карточке. Теперь ответ рисует
      // не карточка, а вид ответа, и «2 gün» в нём стоит вместе с типом
      // работы. Проверка стала СИЛЬНЕЕ, а не мягче: спрашиваются оба —
      // и итог, и сами числа, — потому что итог мог бы совпасть случайно,
      // а «9, 10» приходит только из этой выдачи.
      expect(
        find.text('2 gün · Toy'),
        findsOneWidget,
        reason: 'лист остался на первом снимке — правка с другой трубки не '
            'доехала, и человек видит устаревшее',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('answer-picked-numbers')))
            .data,
        '9, 10',
        reason: 'вид ответа показал не те дни, что пришли выдачей',
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

    // ЗАНЯТОСТЬ — ПРОВОДКА ОТ ПОТОКОВ КАЛЕНДАРЯ ДО КЛЕТКИ СЕТКИ.
    //
    // Проверки стоят здесь, а не в наборе листа ответа, потому что
    // утверждение здесь про ПРОВОДКУ: `busyDays`/`busyUnknown` ставит
    // `job_offer_sheet.dart`, а не сам лист. Лист свою половину знает —
    // `job_offer_answer_sheet_test.dart` подаёт занятость руками.
    //
    // ПЕРЕПИСАНЫ 25.08 ВМЕСТЕ С ПОДКЛЮЧЕНИЕМ. Прежде здесь стояла одна
    // проверка — «строка про незнание нарисована», — и она пережила бы
    // подключение НЕ ЗАМЕТИВ ЕГО: потоки в тесте не подменялись, Firebase не
    // поднят, провайдер отдавал ошибку, лист говорил «не знаем», и строка
    // оставалась на месте. Зелено и при целой проводке, и при вырванной
    // (N160). Поэтому первой теперь стоит канарейка.
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

    // КАНАРЕЙКА: занятость ДОЕЗЖАЕТ до клетки. Без неё «строки нет» ничего не
    // доказывает — строка исчезает и от вырванной проводки тоже.
    testWidgets('занятый день из календаря покрашен в сетке ответа', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        Stream.value([futureOffer()]),
        viewerUid: player,
        // Свой вечер музыканта ровно на один из предложенных дней.
        own: {
          player: [
            calendarEvent('busy-1', owner: player, date: '${iso(11)}T15:00:00.000'),
          ],
        },
        asParticipant: const {},
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('offer-open-answer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        cellColor(tester, iso(11)),
        kWarnBg,
        reason: 'занятый день не покрашен — занятость до сетки не доехала',
      );
      expect(
        cellColor(tester, iso(10)),
        Colors.transparent,
        reason: 'покрашены все дни подряд — красится не занятость',
      );
      expect(
        find.byKey(const ValueKey('answer-busy-unknown')),
        findsNothing,
        reason: 'занятость известна — молчать про незнание',
      );
      expect(
        find.text(kBusyPickableLine),
        findsOneWidget,
        reason: 'занятый день выбрать можно, и это сказано',
      );
    });

    // ДВЕРЬ В КАРТОЧКУ ВЕЧЕРА ПЕРЕДАНА — ПРОВОДКА, А НЕ ВИДЖЕТ.
    //
    // Сам виджет надписи знает своё («передали дверь — рисую нажимаемой»), и
    // это проверено у него. Здесь утверждение другое и на него нет второго
    // теста: **что дверь кто-то передаёт**. Не передай её `job_offer_sheet` —
    // человек увидел бы надпись, которая ничего не делает; это ровно N146,
    // микрофон без адресата.
    //
    // Проверяется НАЛИЧИЕМ нажимаемой строки, а не переходом: `eventDetailRoute`
    // ведёт в экран, которому нужен живой Firestore, и открывать его здесь
    // нечем. Граница названа, чтобы на этот тест не полагались шире (I50).
    testWidgets('нажатие на занятый день даёт нажимаемую надпись о вечере', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        Stream.value([futureOffer()]),
        viewerUid: player,
        own: {
          player: [
            calendarEvent('busy-1', owner: player, date: '${iso(11)}T15:00:00.000'),
          ],
        },
        asParticipant: const {},
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('offer-open-answer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(ValueKey('offer-cell-${iso(11)}')));
      await tester.pump();

      expect(find.byKey(const ValueKey('busy-day-notice')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('busy-day-open-busy-1')),
        findsOneWidget,
        reason: 'надпись есть, а двери нет — человек нажмёт и не получит '
            'ничего (N146)',
      );
    });

    // ЗАНЯТЫХ НЕТ — ЭТО ОТВЕТ, И ЛИСТ МОЛЧИТ. Молчание значит «посмотрели,
    // предупреждать не о чем»; строка про незнание здесь была бы неправдой.
    testWidgets('календарь пуст — ни слова про незнание', (tester) async {
      await pumpSheet(
        tester,
        Stream.value([futureOffer()]),
        viewerUid: player,
        own: const {},
        asParticipant: const {},
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('offer-open-answer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const ValueKey('answer-busy-unknown')), findsNothing);
      expect(find.text(kBusyPickableLine), findsNothing);
      expect(cellColor(tester, iso(11)), Colors.transparent);
    });

    // ПОТОКИ МОЛЧАТ — ЛИСТ ГОВОРИТ СЛОВАМИ. Пустая сетка утверждала бы «всё
    // свободно», а этого мы не знаем.
    testWidgets('календарь ещё не ответил — сказано словами', (tester) async {
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

    // N143 В ТРЕТИЙ РАЗ, И ЭТО ГЛАВНАЯ ПРОВЕРКА ЗДЕСЬ.
    //
    // Лист открывается модалкой — отдельным поддеревом, которое от
    // перестройки экрана позади не зависит. Возьми занятость снаружи, из
    // `build` листа предложения, — человек, открывший лист на секунду раньше,
    // чем ответили потоки, остался бы с «не знаем» НАВСЕГДА, до закрытия и
    // повторного открытия. Тест с уже готовыми данными этого не поймал бы:
    // там первый же кадр приходит с ответом.
    testWidgets('данные пришли при открытом листе — пометки появились сами', (
      tester,
    ) async {
      final calendar = StreamController<List<PersonalEvent>>();
      addTearDown(calendar.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatDataProvider('chat-1').overrideWith(
              (ref) async => <String, dynamic>{
                'members': [boss, player],
              },
            ),
            personalEventsProvider.overrideWith((ref, uid) => calendar.stream),
            eventsAsParticipantProvider.overrideWith(
              (ref, uid) => Stream.value(const <PersonalEvent>[]),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: JobOfferSheet(
                chatId: 'chat-1',
                offerId: 'offer-1',
                debugOffers: Stream.value([futureOffer()]),
                debugViewerUid: player,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('offer-open-answer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Лист открыт РАНЬШЕ данных — и честно молчит о занятости.
      expect(find.byKey(const ValueKey('answer-busy-unknown')), findsOneWidget);
      expect(cellColor(tester, iso(11)), Colors.transparent);

      // Календарь ответил. Лист НЕ закрывался и не открывался заново.
      calendar.add([
        calendarEvent('busy-1', owner: player, date: '${iso(11)}T15:00:00.000'),
      ]);
      await tester.pump();

      expect(
        cellColor(tester, iso(11)),
        kWarnBg,
        reason: 'занятость пришла, а модалка её не увидела — Consumer внутри '
            'листа потерян, и человек остался с устаревшим',
      );
      expect(find.byKey(const ValueKey('answer-busy-unknown')), findsNothing);
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

  // ШАГ 3 — ПРОВОДКА ПРИЁМА, И ЭТО ИМЕННО ТЕСТ ПРОВОДКИ, А НЕ КАРТОЧКИ.
  //
  // Заведён по N156: сторож шага 3 в `job_offer_card_widget_test.dart:269`
  // сам передаёт `onAccept: () {}` и потому утверждает «карточка при
  // поданном обработчике рисует кнопку», а не «обработчик кто-то подаёт».
  // N154 родилась ровно в этом зазоре. Здесь поднимается НАСТОЯЩИЙ
  // поставщик — `JobOfferSheet`, — и обработчик не подаётся руками теста.
  //
  // МЕТКА НА КАРТОЧКЕ — «Cavaba bax», А НЕ «Qəbul edirəm», и это не
  // придирка к слову. Кнопка ОТКРЫВАЕТ ЭКРАН, а принимают на нём; две
  // одинаковые метки на два разных дела — та же ловушка, из-за которой на
  // шаге 1 «Göndər» стала «Cavab ver». «Qəbul edirəm» остаётся ровно там,
  // где действительно принимают, — в листе приёма.
  group('шаг 3: приём подключён (проводка, а не карточка)', () {
    String iso(int day) => '2026-09-${day.toString().padLeft(2, '0')}';

    JobOffer answeredOffer() => JobOffer(
      id: 'offer-1',
      createdBy: boss,
      dates: [iso(10), iso(11), iso(12)],
      eventType: 'Toy',
      answers: {
        player: [iso(10), iso(11)],
      },
    );

    JobOffer awaitingOffer() => JobOffer(
      id: 'offer-1',
      createdBy: boss,
      dates: [iso(10), iso(11), iso(12)],
      eventType: 'Toy',
    );

    // КАНАРЕЙКА БЕЗУСЛОВНАЯ И ПЕРВАЯ, как у шага 2 выше: остальные
    // проверки нажимают эту кнопку, и без неё они упали бы по причине «не
    // нашли кнопку», а не по своей.
    // ПЕРЕПИСАН 25.08 ВМЕСТЕ СО СНЯТИЕМ ПРОМЕЖУТОЧНОЙ КАРТОЧКИ.
    //
    // Прежде здесь ждали `offer-accept` и «Cavaba bax» — кнопку НА КАРТОЧКЕ,
    // которая открывала лист приёма поверх. Теперь дверь в состоянии
    // `answered` рисует сам ответ, и «Qəbul edirəm» стоит прямо в нём.
    //
    // Проверка утверждает И НАЛИЧИЕ нового, И ОТСУТСТВИЕ старого: без
    // второй половины она прошла бы и в том случае, если бы карточка
    // осталась висеть под новым видом.
    testWidgets('инициатору после ответа приём предложен сразу', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        Stream.value([answeredOffer()]),
        viewerUid: boss,
      );
      // ДВУХ КАДРОВ ЗДЕСЬ МАЛО, И ЭТО НЕ ПРИДИРКА ТЕСТА К СЕБЕ.
      //
      // «Qəbul edirəm» решает `canAcceptAnswer`, а ей нужен НАСТОЯЩИЙ uid
      // получателя — он приходит из состава чата, то есть асинхронно.
      // Прежняя кнопка на карточке спрашивала только состояние предложения
      // и обходилась одним кадром.
      //
      // Поведение это правильное: пока состав не пришёл, неизвестно, КТО
      // ответил, и предлагать принять нечего. Молчание тут честнее кнопки.
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('accept-confirm')), findsOneWidget);
      expect(find.text('Qəbul edirəm'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('offer-accept')),
        findsNothing,
        reason: 'промежуточная карточка с «Cavaba bax» снова между лентой и '
            'ответом',
      );
    });

    // ДО ОТВЕТА ПРИНИМАТЬ НЕЧЕГО, и кнопки быть не должно.
    //
    // Без этой проверки «кнопка есть после ответа» не отличалось бы от
    // «кнопка есть всегда»; а кнопка до ответа вела бы на экран, где
    // крупно стоит «0 gün» и принимать нечего (`canAcceptAnswer`).
    testWidgets('инициатору до ответа кнопки приёма нет', (tester) async {
      await pumpSheet(
        tester,
        Stream.value([awaitingOffer()]),
        viewerUid: boss,
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('offer-accept')), findsNothing);
    });

    // ХОД ИНИЦИАТОРА, А НЕ ЛЮБОГО. Принимает тот, кто звал: создание
    // вечеров — его ход, и держит это правило (`isInitiator()` в
    // `firestore.rules:810`), а не только экран.
    testWidgets('получателю кнопки приёма не рисуют', (tester) async {
      await pumpSheet(
        tester,
        Stream.value([answeredOffer()]),
        viewerUid: player,
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('offer-accept')), findsNothing);
    });

    // ПРИЁМ БЕЗ ПРОМЕЖУТОЧНОГО ЛИСТА — ЗАМЕНА ПРЕЖНЕМУ «нажатие на
    // «Cavaba bax» открывает лист приёма».
    //
    // Тот тест доказывал, что лист приёма открывается ПОВЕРХ карточки и
    // говорит про наше предложение. Ни листа, ни карточки в этой клетке
    // больше нет, поэтому проверяется то же по существу, но на один шаг
    // короче: дверь показывает НАШ ответ, и нажатие доходит до писателя.
    // НОВЫЙ ВХОД В ЛИСТ ОТВЕТА, И БЕЗ ЭТОГО ТЕСТА ОН ОСТАЛСЯ БЫ НЕПОКРЫТЫМ.
    //
    // До 25.08 переответ начинался кнопкой «Cavab ver» на карточке, и все
    // проверки занятости идут именно оттуда — на предложении БЕЗ ответа.
    // Теперь у ответившего карточки нет, и дверь в лист ответа — «Cavabı
    // dəyiş». Дорога за дверью та же самая (`_openAnswerSheet`, тот же
    // `busyDaysProvider`), но САМ ВХОД новый, и проверять его нечем, кроме
    // этого: зелёный прогон без него означал бы «старый вход цел», а не
    // «новый работает».
    testWidgets('«Cavabı dəyiş» открывает лист ответа с занятостью', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        Stream.value([answeredOffer()]),
        viewerUid: player,
        own: const {},
        asParticipant: const {},
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('answer-change')));
      await tester.pumpAndSettle();

      // Лист ответа открыт: клетки месяца нажимаются — это его, а не вида
      // ответа (там нажатие открывает подробности, а не выбирает день).
      expect(
        find.byKey(ValueKey('offer-cell-${iso(12)}')),
        findsOneWidget,
        reason: 'лист ответа не открылся — переответ стал недостижим',
      );
      // Занятость ДОЕХАЛА: строки незнания быть не должно. Она и есть
      // признак того, что поставщик спрошен, а не забыт при смене двери.
      expect(find.text(kBusyUnknownLine), findsNothing);
    });

    testWidgets('приём открыт сразу и принимает НАШЕ предложение', (
      tester,
    ) async {
      JobOffer? written;
      await pumpSheet(
        tester,
        Stream.value([answeredOffer()]),
        viewerUid: boss,
        writeAccept: (o) async => written = o,
      );
      // Состав чата приходит асинхронно — см. довод у соседнего теста.
      await tester.pumpAndSettle();

      // Показано наше предложение: два отмеченных дня, и именно те.
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('answer-picked-numbers')))
            .data,
        '10, 11',
      );

      // I9: без нажатия проверка смотрела бы на текст и не могла бы
      // провалиться от снятого обработчика — ровно N146.
      await tester.tap(find.byKey(const ValueKey('accept-confirm')));
      await tester.pump();

      expect(
        written?.id,
        answeredOffer().id,
        reason: 'нажатие «Qəbul edirəm» не довело предложение до писателя',
      );
    });
  });
}
