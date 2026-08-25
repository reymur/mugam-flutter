import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/offer_draft.dart';
import 'package:mugam_flutter/features/job_offer/screens/job_offer_days_sheet.dart';

// ЛИСТ ВЫБОРА ДНЕЙ — три требования владельца, каждое отдельной проверкой.
//
// ЧЕГО ЭТОТ НАБОР НЕ ЛОВИТ: как лист выглядит на телефоне (размер клеток,
// попадание пальцем, клавиатура поверх кнопки) и что предложение доехало до
// базы. Первое проверяется руками, второе — после выкладки правил.

void main() {
  group('сетка месяца', () {
    test('六 недель по семь дней — 42 клетки', () {
      expect(monthGridDays(DateTime(2026, 8)).length, 42);
    });

    test('начинается с понедельника', () {
      for (final m in [DateTime(2026, 8), DateTime(2026, 2), DateTime(2027, 1)]) {
        expect(monthGridDays(m).first.weekday, DateTime.monday);
      }
    });

    // 31 день, начавшийся в воскресенье, занимает 37 клеток — пяти недель
    // не хватило бы, и последние дни ушли бы за край молча.
    test('месяц помещается целиком даже в худшем случае', () {
      final march = DateTime(2026, 3); // 1 марта 2026 — воскресенье
      final days = monthGridDays(march);
      final inMonth = days.where((d) => d.month == 3).length;
      expect(inMonth, 31);
    });
  });

  group('строка «что отправляем»', () {
    test('называет число и сами дни', () {
      expect(
        offerSummaryLine([
          '2026-08-09',
          '2026-08-10',
          '2026-08-11',
          '2026-08-12',
          '2026-08-15',
        ]),
        '5 gün · 9, 10, 11, 12, 15',
      );
    });

    // Дни идут по возрастанию независимо от порядка нажатий: «9, 15, 10»
    // читалось бы как ошибка ввода.
    test('дни упорядочены, как бы их ни тыкали', () {
      expect(
        offerSummaryLine(['2026-08-15', '2026-08-09', '2026-08-10']),
        '3 gün · 9, 10, 15',
      );
    });

    test('пустой выбор — пустая строка, а не «0 gün»', () {
      expect(offerSummaryLine([]), '');
    });
  });

  group('когда можно отправлять', () {
    // ГЛАВНОЕ ТРЕБОВАНИЕ: время и место НЕ обязательны. Потребуй их — и
    // предложение на пять дней отправить станет нельзя, то есть запретим
    // ровно тот случай, ради которого работа делалась.
    test('дней и типа ДОСТАТОЧНО — без времени, места и заметки', () {
      expect(
        canSendOffer(dates: const ['2026-08-09'], eventType: 'Toy'),
        isTrue,
      );
    });

    test('без дней нельзя', () {
      expect(canSendOffer(dates: const [], eventType: 'Toy'), isFalse);
    });

    test('без типа нельзя', () {
      expect(
        canSendOffer(dates: const ['2026-08-09'], eventType: '   '),
        isFalse,
      );
    });
  });

  group('лист целиком', () {
    Future<void> pump(
      WidgetTester tester, {
      Set<String> busy = const {},
      bool busyUnknown = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JobOfferDaysSheet(
              initialMonth: DateTime(2026, 8),
              busyUnknown: busyUnknown,
              // «Сегодня» прибито намеренно: без этого набор тыкает в
              // конкретные числа и через неделю бьёт в прошлое, которое
              // лист законно не принимает. Тест покраснел бы не потому,
              // что код сломался, — поймано в первый же прогон.
              now: DateTime(2026, 8, 1),
              busyDays: busy,
              onSend:
                  ({required dates, required eventType, required details}) {},
            ),
          ),
        ),
      );
    }

    // СТОРОЖ НА ТУ САМУЮ ПОЛОМКУ, ЧТО УВИДЕЛ ВЛАДЕЛЕЦ НА УСТРОЙСТВЕ 14.08:
    // лист был ПРОЗРАЧНЫМ, и сквозь него просвечивала переписка — два
    // экрана кашей.
    //
    // Причина не в листе, а в СТЫКЕ: точка вызова открывает его с
    // `backgroundColor: Colors.transparent`, потому что прежний лист рисовал
    // фон сам. Новый этого не делал, и никто об этом не сказал — ни
    // анализатор, ни 13 тестов, ни прогон: у виджета в тесте фон белый по
    // умолчанию от `MaterialApp`.
    //
    // Утверждается НАЛИЧИЕ непрозрачной заливки, значит сторож сам себе
    // канарейка (I31): исчезни контейнер — не найдётся ничего, и тест
    // покраснеет.
    testWidgets('лист рисует СВОЙ непрозрачный фон', (tester) async {
      await pump(tester);
      final painted = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) {
            final d = c.decoration;
            return d is BoxDecoration &&
                d.color != null &&
                d.color!.a == 1.0;
          })
          .toList();
      expect(
        painted,
        isNotEmpty,
        reason: 'У листа нет своей заливки — сквозь него будет видна '
            'переписка, потому что точка вызова открывает его прозрачным.',
      );
    });

    testWidgets('дни выбираются сеткой, а не списком', (tester) async {
      await pump(tester);
      // Клетки месяца существуют как сетка: 42 штуки на шесть недель.
      final cells = tester.widgetList(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('offer-cell-'),
        ),
      );
      expect(cells.length, 42);
    });

    // ТРЕБОВАНИЕ 3 — человек видит, что отправляет, до нажатия.
    testWidgets('выбранные дни собираются в строку под сеткой', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('offer-summary')), findsNothing);

      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-09')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-09')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-11')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-11')));
      await tester.pump();

      expect(find.text('2 gün · 9, 11'), findsOneWidget);
    });

    // ТИП РАБОТЫ — ВЫБОРОМ, А НЕ ПУСТЫМ ПОЛЕМ (макет `mugam-14-secim`).
    // Замер прода 14.08: различных типов в `personalEvents` ДВА — Toy 89,
    // Konsert 2. Трёх кнопок хватает, «Digər» нужен ради того, чтобы
    // человек с нестандартным поводом мог вообще отправить.
    testWidgets('тип выбирается кнопками, четвёртая открывает своё поле', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('offer-type-Toy')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-type-Konsert')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-type-Məclis')), findsOneWidget);
      // Своего поля нет, пока не выбрали «Digər».
      expect(find.byKey(const ValueKey('offer-type-custom')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('offer-type-other')));
      await tester.pump();
      expect(find.byKey(const ValueKey('offer-type-custom')), findsOneWidget);
    });

    // ТРИ ПУСТЫХ ПОЛЯ БОЛЬШЕ НЕ ВИСЯТ ВНИЗУ ВСЕГДА — они принадлежат дню и
    // живут под «Ətraflı».
    testWidgets('полей нет, пока не выбран день', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('offer-time')), findsNothing);
      expect(find.byKey(const ValueKey('offer-location')), findsNothing);
      expect(find.byKey(const ValueKey('offer-dress')), findsNothing);
    });

    // Пустой день приходит СВЁРНУТЫМ: полей нет, пока не раскрыли.
    testWidgets('у пустого дня «Ətraflı» свёрнут', (tester) async {
      await pump(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-14')));
      await tester.pump();
      expect(find.byKey(const ValueKey('offer-time')), findsNothing);

      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-details-toggle-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('offer-details-toggle-2026-08-14')),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('offer-time')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-dress')), findsOneWidget);
    });

    // САМОЕ ОПАСНОЕ МЕСТО ЛИСТА, и потому проверено отдельно.
    //
    // Детали живут В КАРТЕ ПО ДНЯМ, а контроллеры полей только показывают
    // текущий день. Держи правду в контроллерах — вписанное 14-му
    // перетекло бы на 20-й, и человек этого НЕ ЗАМЕТИЛ БЫ: поле выглядит
    // одинаково, что со своим значением, что с чужим.
    testWidgets('детали у каждого дня свои и не перетекают', (tester) async {
      await pump(tester);

      // Вписываем 14-му.
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-14')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-details-toggle-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('offer-details-toggle-2026-08-14')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('offer-time')),
        '20:00',
      );
      await tester.pump();

      // Переходим на 20-й — поля обязаны быть ПУСТЫМИ.
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-20')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-20')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-details-toggle-2026-08-20')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('offer-details-toggle-2026-08-20')),
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('offer-time')))
            .controller!
            .text,
        '',
        reason: 'время 14-го перетекло на 20-й',
      );

      // Возвращаемся на 14-й — вписанное на месте, и «Ətraflı» раскрыт САМ.
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-14')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('offer-time')),
        findsOneWidget,
        reason: 'день с деталями обязан открыться раскрытым',
      );
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('offer-time')))
            .controller!
            .text,
        '20:00',
      );
    });

    // Карандаш в углу клетки — единственный признак, по которому детали
    // видно, не открывая день.
    testWidgets('у дня с деталями в клетке карандаш', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('offer-pen-2026-08-14')), findsNothing);

      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-14')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-details-toggle-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('offer-details-toggle-2026-08-14')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('offer-time')),
        '20:00',
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('offer-pen-2026-08-14')), findsOneWidget);
    });

    // НАЙДЕНО НА ТРУБКЕ 14.08, а не тестом: снятый день оставался в строке
    // под сеткой. Сетка говорила «не выбран», строка — «мы про этот день»,
    // и микрофон в ней записал бы голос дню, которого в предложении нет.
    testWidgets('снятый день уходит из строки', (tester) async {
      await pump(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-14')));
      await tester.pump();
      expect(find.byKey(const ValueKey('offer-mic-2026-08-14')), findsOneWidget);

      // Повторный тап по ОТКРЫТОМУ дню снимает его.
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-14')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('offer-mic-2026-08-14')),
        findsNothing,
        reason: 'строка снятого дня осталась внизу',
      );
      expect(find.byKey(const ValueKey('offer-summary')), findsNothing);
    });

    // Пара к предыдущему: если выбранные дни ещё есть, строка не исчезает,
    // а переходит на оставшийся. Без этой пары «строка ушла» было бы верно
    // и для случая, когда она не должна была уходить.
    testWidgets('снятие одного из двух переводит строку на оставшийся', (
      tester,
    ) async {
      await pump(tester);
      for (final d in ['2026-08-14', '2026-08-20']) {
        await tester.ensureVisible(find.byKey(ValueKey('offer-cell-$d')));
        await tester.pump();
        await tester.tap(find.byKey(ValueKey('offer-cell-$d')));
        await tester.pump();
      }
      // Снимаем 20-е — строка обязана показать 14-е.
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-20')));
      await tester.pump();
      expect(find.byKey(const ValueKey('offer-mic-2026-08-20')), findsNothing);
      expect(find.byKey(const ValueKey('offer-mic-2026-08-14')), findsOneWidget);
    });

    // ТРЕТИЙ ИСХОД ТАПА, заведённый после того, как тест упёрся в дыру
    // замысла: к деталям уже выбранного дня надо как-то возвращаться, а
    // прежде тап по нему день СНИМАЛ — вместе с невидимо уходящими часом и
    // местом.
    testWidgets('тап по выбранному, но не открытому дню открывает его', (
      tester,
    ) async {
      await pump(tester);
      for (final d in ['2026-08-14', '2026-08-20']) {
        await tester.ensureVisible(find.byKey(ValueKey('offer-cell-$d')));
        await tester.pump();
        await tester.tap(find.byKey(ValueKey('offer-cell-$d')));
        await tester.pump();
      }
      // Открыт 20-й. Тапаем 14-й — он ВЫБРАН, значит должен просто
      // открыться, а не сняться.
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-14')));
      await tester.pump();

      expect(find.byKey(const ValueKey('offer-mic-2026-08-14')), findsOneWidget);
      expect(
        find.text('2 gün · 14, 20'),
        findsOneWidget,
        reason: 'день сняли вместо того, чтобы открыть',
      );
    });

    // ВОПРОС ПОЯВЛЯЕТСЯ, ТОЛЬКО КОГДА ЕСТЬ ЧТО ЗАТИРАТЬ (решение автора
    // 14.08). Молчаливая замена пустого — не потеря.
    Future<void> fill(WidgetTester t, String day, String time) async {
      await t.ensureVisible(find.byKey(ValueKey('offer-cell-$day')));
      await t.pump();
      await t.tap(find.byKey(ValueKey('offer-cell-$day')));
      await t.pump();
      final toggle = find.byKey(ValueKey('offer-details-toggle-$day'));
      if (find.byKey(const ValueKey('offer-time')).evaluate().isEmpty) {
        await t.ensureVisible(toggle);
        await t.pump();
        await t.tap(toggle);
        await t.pump();
      }
      await t.enterText(find.byKey(const ValueKey('offer-time')), time);
      await t.pump();
    }

    testWidgets('копирование в ПУСТЫЕ дни идёт без вопроса', (tester) async {
      await pump(tester);
      await fill(tester, '2026-08-14', '20:00');
      // Второй день выбран, но пуст — затирать нечего.
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-20')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-20')));
      await tester.pump();
      // Возвращаемся на источник и копируем.
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-14')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('offer-copy-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-copy-all')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('köçürüləcək'),
        findsNothing,
        reason: 'вопрос задан там, где терять нечего',
      );
      // И копирование всё-таки произошло.
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-20')));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('offer-time')))
            .controller!
            .text,
        '20:00',
      );
    });

    testWidgets('копирование поверх вписанного СПРАШИВАЕТ и называет число', (
      tester,
    ) async {
      await pump(tester);
      await fill(tester, '2026-08-14', '20:00');
      await fill(tester, '2026-08-20', '22:00');
      // Назад на источник.
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-14')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('offer-copy-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-copy-all')));
      await tester.pumpAndSettle();

      expect(find.text('Bu detallar 1 günə köçürüləcək. Davam?'), findsOneWidget);
    });

    // МИКРОФОН СНАРУЖИ «Ətraflı»: голос — быстрый путь, до него одно
    // касание из любого состояния. Спрячь внутрь — быстрый путь станет
    // длиннее медленного.
    testWidgets('микрофон в строке дня, а не внутри «Ətraflı»', (tester) async {
      await pump(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-14')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-14')));
      await tester.pump();
      // Детали свёрнуты, а микрофон уже здесь.
      expect(find.byKey(const ValueKey('offer-time')), findsNothing);
      expect(find.byKey(const ValueKey('offer-mic-2026-08-14')), findsOneWidget);
    });

    // ТРЕБОВАНИЕ 2 — свои занятые дни видны, но выбрать их можно.
    testWidgets('занятый день выбирается — решает человек, а не приложение', (
      tester,
    ) async {
      await pump(tester, busy: {'2026-08-10'});
      await tester.ensureVisible(
        find.byKey(const ValueKey('offer-cell-2026-08-10')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-10')));
      await tester.pump();
      expect(find.text('1 gün · 10'), findsOneWidget);
    });

    // ЗАНЯТОСТЬ РАБОТОДАТЕЛЯ, ПОДКЛЮЧЕНА 25.08.
    //
    // До этого дня работодатель набирал дни так же вслепую, как музыкант их
    // отмечал: параметр `busyDays` у листа был, поставщика не было ни одного.
    // Проверки ниже — про ПОКАЗ; что занятость доезжает сюда из потоков
    // календаря, сторожится по исходникам в `source_invariants_test.dart`
    // (точка вызова `proposeJobOffer` тестом не достаётся: она ходит в Auth и
    // Firestore до показа листа).
    group('занятость: три состояния, и молчание — только одно из них', () {
      testWidgets('занятости не знаем — сказано словами', (tester) async {
        await pump(tester, busyUnknown: true);
        expect(
          find.byKey(const ValueKey('offer-busy-unknown')),
          findsOneWidget,
          reason: 'пустая сетка утверждает «всё свободно» — а мы не знаем',
        );
        expect(find.byKey(const ValueKey('offer-busy-pickable')), findsNothing);
      });

      testWidgets('занятых нет — ни слова, и это ответ, а не молчание', (
        tester,
      ) async {
        await pump(tester);
        expect(find.byKey(const ValueKey('offer-busy-unknown')), findsNothing);
        expect(find.byKey(const ValueKey('offer-busy-pickable')), findsNothing);
      });

      testWidgets('занятый день на этом месяце — сказано, что выбрать можно', (
        tester,
      ) async {
        await pump(tester, busy: {'2026-08-10'});
        expect(
          find.byKey(const ValueKey('offer-busy-pickable')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('offer-busy-unknown')), findsNothing);
      });

      // ВЗАИМНО ИСКЛЮЧАЮЩИЕ: «занятые выбирать можно» и «занятых не знаем» —
      // про одно и то же два разных. Проверка держит именно это, а не то, что
      // какая-то из строк вообще есть.
      testWidgets('две строки разом не показываются', (tester) async {
        await pump(tester, busy: {'2026-08-10'}, busyUnknown: true);
        expect(
          find.byKey(const ValueKey('offer-busy-pickable')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('offer-busy-unknown')), findsNothing);
      });

      // Занятость приходит на ВЕСЬ календарь, а сетка показывает один месяц.
      // Пояснение про месяц, где не покрашено ни одной клетки, объясняло бы
      // то, чего человек не видит.
      testWidgets('занятый день в другом месяце — про этот молчим', (
        tester,
      ) async {
        await pump(tester, busy: {'2026-12-10'});
        expect(find.byKey(const ValueKey('offer-busy-pickable')), findsNothing);
        expect(find.byKey(const ValueKey('offer-busy-unknown')), findsNothing);
      });
    });
  });
}
