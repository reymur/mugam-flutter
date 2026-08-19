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
            debugViewerUid: boss,
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
}
