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
    Future<void> pump(WidgetTester tester, {Set<String> busy = const {}}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JobOfferDaysSheet(
              initialMonth: DateTime(2026, 8),
              // «Сегодня» прибито намеренно: без этого набор тыкает в
              // конкретные числа и через неделю бьёт в прошлое, которое
              // лист законно не принимает. Тест покраснел бы не потому,
              // что код сломался, — поймано в первый же прогон.
              now: DateTime(2026, 8, 1),
              busyDays: busy,
              onSend:
                  ({
                    required dates,
                    required eventType,
                    required eventTime,
                    required eventLocation,
                    required eventNotes,
                  }) {},
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

      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-09')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-11')));
      await tester.pump();

      expect(find.text('2 gün · 9, 11'), findsOneWidget);
    });

    // ТРЕБОВАНИЕ 1 — все поля в одном листе.
    testWidgets('дни, тип, время, место и заметка — в одном листе', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('offer-type')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-time')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-location')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-notes')), findsOneWidget);
      expect(find.byKey(const ValueKey('offer-cell-2026-08-09')), findsOneWidget);
    });

    // ТРЕБОВАНИЕ 2 — свои занятые дни видны, но выбрать их можно.
    testWidgets('занятый день выбирается — решает человек, а не приложение', (
      tester,
    ) async {
      await pump(tester, busy: {'2026-08-10'});
      await tester.tap(find.byKey(const ValueKey('offer-cell-2026-08-10')));
      await tester.pump();
      expect(find.text('1 gün · 10'), findsOneWidget);
    });
  });
}
