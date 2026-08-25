import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';
import 'package:mugam_flutter/core/theme/colors.dart';
import 'package:mugam_flutter/features/job_offer/busy_days.dart';
import 'package:mugam_flutter/core/job_offer/day_details.dart';
import 'package:mugam_flutter/features/job_offer/screens/job_offer_answer_sheet.dart';
import 'package:mugam_flutter/features/job_offer/widgets/offer_answer_view.dart';
import 'package:mugam_flutter/firebase/models.dart';

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
  Map<String, DayDetails> details = const {},
}) => JobOffer(
  id: 'offer-1',
  createdBy: boss,
  dates: dates ?? const ['2026-09-14', '2026-09-15', '2026-09-20'],
  eventType: 'Toy',
  answers: answers,
  details: details,
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
      bool busyKnown = true,
      Map<String, List<PersonalEvent>> busyEvents = const {},
      void Function(String eventId)? onOpenBusyEvent,
      void Function(List<String>)? onSend,
      DateTime? now,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JobOfferAnswerSheet(
              offer: o ?? offer(),
              myUid: player,
              initiatorName: 'Rafael',
              // Занятость подаётся как ОДИН ответ: дни, вечера и признак
              // «знаем ли». Здесь вечеров нет — эти проверки про клетку и
              // про строку под сеткой, а не про то, чем занят день.
              busy: busyKnown
                  ? BusyDays({
                      for (final iso in busy) iso: busyEvents[iso] ?? const [],
                    })
                  : const BusyDays.unknown(),
              onOpenBusyEvent: onOpenBusyEvent,
              now: now ?? DateTime(2026, 9, 1),
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
      expect(find.text('1 gün · 15 sentyabr'), findsOneWidget);
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
      // ОБА ДНЯ — ВНУТРИ ОДНОГО МЕСЯЦА, и это не мелочь: клетки соседних
      // месяцев в сетке видны, но не нажимаются вовсе (`inMonth`), и проверка
      // «выбрал занятый день» на такой клетке прошла бы по неверной причине —
      // день не выбрался бы ни при какой заливке. Поймано первым же прогоном.
      //
      // «Сегодня» здесь 10 сентября: 5-е прошедшее, 15-е будущее, оба в
      // сентябре, на котором лист и открывается (месяц берётся по первой дате
      // предложения).
      final today = DateTime(2026, 9, 10);
      JobOffer acrossToday() =>
          offer(dates: const ['2026-09-05', '2026-09-15']);

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
        await pump(tester, o: acrossToday(), busy: {'2026-09-05'}, now: today);
        expect(cellColor(tester, '2026-09-05'), Colors.transparent);
      });

      // КАНАРЕЙКА. Без неё проверка выше зелена и на сетке, разучившейся
      // заливать вообще.
      testWidgets('занятый БУДУЩИЙ день предложения залит', (tester) async {
        await pump(tester, o: acrossToday(), busy: {'2026-09-15'}, now: today);
        expect(cellColor(tester, '2026-09-15'), kWarnBg);
      });

      // ВЫБРАННЫЙ ЗАНЯТЫЙ ДЕНЬ СОХРАНЯЕТ ПРЕДУПРЕЖДАЮЩУЮ РАМКУ.
      //
      // Это тот самый случай, что случился 22.08: золотая заливка выбора
      // закрывает предупреждение целиком — то есть ровно в тот миг, когда
      // человек согласился на занятый день, предупреждение и пропадает.
      testWidgets('выбрал занятый день — рамка предупреждения осталась', (
        tester,
      ) async {
        await pump(tester, o: acrossToday(), busy: {'2026-09-15'}, now: today);
        await tester.ensureVisible(
          find.byKey(const ValueKey('offer-cell-2026-09-15')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-15')));
        await tester.pump();

        final container = tester.widget<Container>(
          find
              .descendant(
                of: find.byKey(const ValueKey('offer-cell-2026-09-15')),
                matching: find.byType(Container),
              )
              .first,
        );
        final decoration = container.decoration as BoxDecoration;
        expect(decoration.color, kGold, reason: 'день должен быть выбран');
        expect(
          (decoration.border as Border?)?.top.color,
          kWarnBorder,
          reason: 'выбор закрасил предупреждение — человек согласился и '
              'перестал видеть, что день занят',
        );
      });

      // Строка под сеткой обязана молчать вместе с заливкой: сказать «занятые
      // дни тоже можно выбрать» там, где не покрашено ни одной клетки, значит
      // объяснять то, чего человек не видит.
      testWidgets('занятость только в прошлом — строки про выбор нет', (
        tester,
      ) async {
        await pump(tester, o: acrossToday(), busy: {'2026-09-05'}, now: today);
        expect(find.text(kBusyPickableLine), findsNothing);
      });

      testWidgets('занятость впереди — строка про выбор есть', (tester) async {
        await pump(tester, o: acrossToday(), busy: {'2026-09-15'}, now: today);
        expect(find.text(kBusyPickableLine), findsOneWidget);
      });
    });

    // ЧЕМ ЗАНЯТ ДЕНЬ — надпись под сеткой и дверь в вечер (владелец, 25.08).
    //
    // Цвет говорит «осторожно» и молчит о том, ЧЕМ занято. Человек, ткнув в
    // закрашенный день, вправе спросить — и получить ответ, не выходя из
    // листа.
    group('чем занят нажатый день', () {
      PersonalEvent evening(String id, {String time = '15:00'}) =>
          PersonalEvent.fromFirestore(id, {
            'ownerUid': player,
            'date': '2026-09-15T$time:00.000',
            'type': 'Toy',
            'musicians': const <String>[],
            'answersWrittenByOwner': true,
            'status': 'agreed',
          });

      Future<void> pumpBusy(
        WidgetTester tester, {
        List<PersonalEvent> events = const [],
        void Function(String eventId)? onOpen,
      }) => pump(
        tester,
        busy: {'2026-09-15'},
        busyEvents: {'2026-09-15': events},
        onOpenBusyEvent: onOpen,
      );

      testWidgets('до нажатия надписи нет — ни про какой день', (tester) async {
        await pumpBusy(tester, events: [evening('e1')]);
        expect(find.byKey(const ValueKey('busy-day-notice')), findsNothing);
      });

      testWidgets('нажал занятый день — сказано, чем он занят', (tester) async {
        await pumpBusy(tester, events: [evening('e1')]);
        await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-15')));
        await tester.pump();

        expect(find.byKey(const ValueKey('busy-day-notice')), findsOneWidget);
        expect(find.text('Bu gün məşğulsan'), findsOneWidget);
        expect(
          find.text('Toy · 15:00'),
          findsOneWidget,
          reason: 'сказано «занят», но не сказано чем — это половина ответа',
        );
      });

      testWidgets('нажал свободный день — надписи нет', (tester) async {
        await pumpBusy(tester, events: [evening('e1')]);
        await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-14')));
        await tester.pump();
        expect(find.byKey(const ValueKey('busy-day-notice')), findsNothing);
      });

      // ВСЕ ВЕЧЕРА, А НЕ ПЕРВЫЙ (N51/I11): два вечера в один день — обычная
      // жизнь, и спрятать второй значит соврать про день.
      testWidgets('два вечера в один день — названы оба', (tester) async {
        await pumpBusy(
          tester,
          events: [evening('e1'), evening('e2', time: '21:00')],
        );
        await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-15')));
        await tester.pump();

        expect(find.text('Toy · 15:00'), findsOneWidget);
        expect(find.text('Toy · 21:00'), findsOneWidget);
      });

      testWidgets('нажатие на надпись открывает ТОТ вечер', (tester) async {
        String? opened;
        await pumpBusy(
          tester,
          events: [evening('e1'), evening('e2', time: '21:00')],
          onOpen: (id) => opened = id,
        );
        await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-15')));
        await tester.pump();

        await tester.ensureVisible(
          find.byKey(const ValueKey('busy-day-open-e2')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('busy-day-open-e2')));
        await tester.pump();
        expect(opened, 'e2', reason: 'открылся не тот вечер, на который нажали');
      });

      // ОДИН ВЕЧЕР — НАЖИМАЕТСЯ ВЕСЬ БЛОК (владелец, 25.08, по виду на
      // трубке). Проверка бьёт по ЗАГОЛОВКУ: он лежит вне строки вечера, и
      // сработай только строка — нажатие сюда не дало бы ничего.
      testWidgets('один вечер — нажимается весь блок, а не только строка', (
        tester,
      ) async {
        String? opened;
        await pumpBusy(
          tester,
          events: [evening('e1')],
          onOpen: (id) => opened = id,
        );
        await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-15')));
        await tester.pump();

        await tester.ensureVisible(find.text('Bu gün məşğulsan'));
        await tester.pump();
        await tester.tap(find.text('Bu gün məşğulsan'));
        await tester.pump();
        expect(opened, 'e1');
      });

      // НЕСКОЛЬКО ВЕЧЕРОВ — БЛОК ЦЕЛИКОМ НЕ НАЖИМАЕТСЯ, и это не недоделка:
      // целей столько же, сколько вечеров, и общая мишень открывала бы
      // первый (`.first`, N51/I11) либо спрашивала бы «который?».
      testWidgets('два вечера — общей мишени у блока нет', (tester) async {
        String? opened;
        await pumpBusy(
          tester,
          events: [evening('e1'), evening('e2', time: '21:00')],
          onOpen: (id) => opened = id,
        );
        await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-15')));
        await tester.pump();

        await tester.ensureVisible(find.text('Bu gün məşğulsan'));
        await tester.pump();
        await tester.tap(
          find.text('Bu gün məşğulsan'),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(
          opened,
          isNull,
          reason: 'нажатие на заголовок открыло вечер — значит блок выбрал '
              'один из двух за человека',
        );
      });

      // ПРАВИЛО «КНОПКА БЕЗ АДРЕСАТА НЕ РИСУЕТСЯ» (N146, I64). Не передали
      // дверь — надпись остаётся надписью, без обманчивого вида нажимаемой.
      testWidgets('двери нет — надпись есть, но не нажимаема', (tester) async {
        await pumpBusy(tester, events: [evening('e1')]);
        await tester.tap(find.byKey(const ValueKey('offer-cell-2026-09-15')));
        await tester.pump();

        expect(find.byKey(const ValueKey('busy-day-notice')), findsOneWidget);
        expect(find.byKey(const ValueKey('busy-day-open-e1')), findsNothing);
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
      expect(find.text('1 gün · 15 sentyabr'), findsOneWidget);
    });
  });


  // ВИД ОТВЕТА — то, что видят обе стороны после ответа музыканта.
  //
  // Пришёл 25.08 на смену `JobOfferAcceptSheet` по макету владельца. Прежняя
  // группа тестов держала старую разметку целиком — «2 gün» крупно сверху,
  // «14, 20 sentyabr» словами, «15 sentyabr — yox» тихой строкой — и снята
  // вместе с ней, а не «поправлена»: проверять там больше нечего.
  //
  // ЧТО ЭТИ ТЕСТЫ ДЕРЖАТ, а что нет:
  //   держат  — кто назван и как; что числа остались числами; что отказ
  //             помечен значком; какие кнопки кому предложены;
  //   НЕ держат — размеры и цвета. Проверять «21 больше 12» значило бы
  //             закрепить макет, а не правило: следующая правка вида
  //             покраснела бы, не сломав ничего.
  group('вид ответа', () {
    Future<void> pump(
      WidgetTester tester, {
      required JobOffer o,
      String viewer = boss,
      VoidCallback? onAccept,
      VoidCallback? onWithdraw,
      VoidCallback? onChangeAnswer,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfferAnswerView(
              offer: o,
              viewerUid: viewer,
              recipientUid: player,
              recipientName: 'Teymur',
              onAccept: onAccept,
              onWithdraw: onWithdraw,
              onChangeAnswer: onChangeAnswer,
            ),
          ),
        ),
      );
    }

    final answered = offer(answers: {
      player: const ['2026-09-14', '2026-09-20'],
    });

    // N141/I64 В НОВОМ МЕСТЕ: своей стороне — «Sən», чужой — имя.
    //
    // Утверждается И НАЛИЧИЕ нужного, И ОТСУТСТВИЕ лишнего. Одного первого
    // мало: имя могло бы остаться рядом с «Sən», и неправда осталась бы.
    testWidgets('инициатор читает имя ответившего', (tester) async {
      await pump(tester, o: answered, viewer: boss);
      expect(find.text('Teymur'), findsOneWidget);
      expect(find.text('cavab verdi'), findsOneWidget);
      expect(find.text('Sən'), findsNothing);
    });

    testWidgets('ответивший читает о себе во втором лице', (tester) async {
      await pump(tester, o: answered, viewer: player);
      expect(find.text('Sən'), findsOneWidget);
      expect(find.text('cavab verdin'), findsOneWidget);
      expect(find.text('Teymur'), findsNothing);
    });

    testWidgets('месяц назван один раз, дни — только числами', (tester) async {
      await pump(tester, o: answered);

      expect(find.text('SENTYABR'), findsOneWidget);
      for (final n in ['14', '15', '20']) {
        expect(find.text(n), findsOneWidget, reason: 'нет числа $n');
      }
      // Слов при числах не осталось: ни дня недели, ни месяца у каждого.
      expect(find.textContaining('sentyabr'), findsNothing);
      expect(find.textContaining('şənbə'), findsNothing);
    });

    // ГРУПП МОЖЕТ БЫТЬ БОЛЬШЕ ОДНОЙ, и без этого теста ошибка была бы тихой:
    // «31, 1» под одним заголовком «Avqust» назвало бы сентябрьский день
    // августовским, и вид остался бы правдоподобным.
    testWidgets('дни двух месяцев названы каждый своим', (tester) async {
      await pump(
        tester,
        o: offer(
          dates: const ['2026-08-31', '2026-09-01'],
          answers: {player: const ['2026-08-31']},
        ),
      );
      expect(find.text('AVQUST'), findsOneWidget);
      expect(find.text('SENTYABR'), findsOneWidget);
    });

    testWidgets('день отказа помечен значком, согласованный — нет', (
      tester,
    ) async {
      await pump(tester, o: answered);
      expect(
        find.byKey(const ValueKey('answer-day-no-2026-09-15')),
        findsOneWidget,
        reason: 'на дне отказа нет значка',
      );
      expect(
        find.byKey(const ValueKey('answer-day-no-2026-09-14')),
        findsNothing,
        reason: 'значок отказа встал на согласованный день',
      );
    });

    testWidgets('числа согласия и подпись — одной строкой', (tester) async {
      await pump(tester, o: answered);
      expect(find.text('14, 20'), findsOneWidget);
      expect(find.text('Gələ bilirəm'), findsOneWidget);
    });

    // Итог внизу и тихий. Проверяется НАЛИЧИЕ строки, а не её размер.
    testWidgets('итог называет и число дней, и тип работы', (tester) async {
      await pump(tester, o: answered);
      expect(find.text('2 gün · Toy'), findsOneWidget);
    });

    // ОТВЕТ НУЛЁМ ДНЕЙ — законный ответ, и принимать после него нечего:
    // «Qəbul edirəm» создала бы НОЛЬ вечеров.
    testWidgets('ответ нулём: строки согласия нет и принимать нечего', (
      tester,
    ) async {
      await pump(
        tester,
        o: offer(answers: {player: const []}),
        onAccept: () {},
      );
      expect(find.text('Gələ bilirəm'), findsNothing);
      expect(find.byKey(const ValueKey('accept-confirm')), findsNothing);
      expect(find.text('0 gün · Toy'), findsOneWidget);
    });

    testWidgets('кнопка приёма есть и нажатие доходит', (tester) async {
      var accepted = false;
      await pump(tester, o: answered, onAccept: () => accepted = true);
      await tester.tap(find.byKey(const ValueKey('accept-confirm')));
      await tester.pump();
      expect(accepted, isTrue);
    });

    // I9: без нажатия проверка смотрела бы на текст и не могла провалиться
    // от снятого обработчика — ровно N146.
    testWidgets('«Cavabı dəyiş» нарисована отвечавшему и нажимается', (
      tester,
    ) async {
      var changed = false;
      await pump(
        tester,
        o: answered,
        viewer: player,
        onChangeAnswer: () => changed = true,
      );
      expect(find.text('Cavabı dəyiş'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('answer-change')));
      await tester.pump();
      expect(changed, isTrue);
    });

    // ОБРАТНАЯ СТОРОНА: кнопка без адресата не рисуется (N146).
    testWidgets('без обработчиков ни одной кнопки нет', (tester) async {
      await pump(tester, o: answered);
      expect(find.byKey(const ValueKey('accept-confirm')), findsNothing);
      expect(find.byKey(const ValueKey('answer-change')), findsNothing);
      expect(find.byKey(const ValueKey('accept-withdraw')), findsNothing);
    });

    testWidgets('отзыв объясняет своё последствие словами', (tester) async {
      await pump(tester, o: answered, onWithdraw: () {});
      expect(find.byKey(const ValueKey('accept-withdraw')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('accept-withdraw-note')),
        findsOneWidget,
        reason: 'отзыв не сказал, что предложение закроется',
      );
      expect(find.textContaining('yeni təklif'), findsOneWidget);
    });

    // ПОДРОБНОСТИ ПО ДНЮ — то, ради чего дверь и позволили сменить: прежний
    // лист приёма «Ətraflı» не показывал вовсе.
    group('подробности дня', () {
      final withDetails = offer(
        answers: {player: const ['2026-09-14', '2026-09-20']},
        details: const {
          '2026-09-14': DayDetails(time: '20:00', location: 'Şəki'),
        },
      );

      testWidgets('нажатие на день открывает его подробности', (tester) async {
        await pump(tester, o: withDetails);
        await tester.tap(find.byKey(const ValueKey('answer-day-2026-09-14')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('answer-details-day')), findsOneWidget);
        expect(find.text('20:00'), findsOneWidget);
        expect(find.text('Şəki'), findsOneWidget);
        // Пустых полей нет: «Geyim» не вписан, значит строки быть не должно.
        expect(find.text('Geyim'), findsNothing);
      });

      testWidgets('день без подробностей не нажимается', (tester) async {
        await pump(tester, o: withDetails);
        expect(
          find.byKey(const ValueKey('answer-day-2026-09-20')),
          findsNothing,
          reason: 'день без подробностей обещает нажатие и не делает ничего',
        );
      });

      // Подсказка — только когда нажимать есть на что. Иначе она зовёт в
      // пустоту, а это то же обещание без адресата.
      testWidgets('подсказка есть при подробностях и молчит без них', (
        tester,
      ) async {
        await pump(tester, o: withDetails);
        expect(find.byKey(const ValueKey('answer-tap-hint')), findsOneWidget);

        await pump(tester, o: answered);
        expect(find.byKey(const ValueKey('answer-tap-hint')), findsNothing);
      });
    });
  });
}
