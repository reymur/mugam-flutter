import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/shared/widgets/topbar.dart';

// ТО ЖЕ ПРАВИЛО, ЧТО В `job_offer_card.dart`: КНОПКА БЕЗ АДРЕСАТА НЕ
// РИСУЕТСЯ. Здесь оно применено к шапке главного экрана, и завелось оно
// после обхода 20.08 (N147), а не из общих соображений.
//
// **Замер, ради которого этот файл существует.** `Topbar` рисуется в
// приложении РОВНО ОДИН РАЗ — `home_screen.dart:34`, строкой
// `const Topbar(onLanguageTap: null)`. То есть `onLanguageTap` передан
// `null` явно, а `onNotificationTap` не передан вовсе. До 20.08 оба
// `GestureDetector` рисовались безусловно, и на главном экране висели ДВЕ
// кнопки, которые не делают ничего: колокольчик и фишка «AZ».
//
// Это прямое продолжение N64: тогда сняли вшитый бейдж «3», который висел
// вне всякой связи с числом уведомлений, — а саму кнопку под ним оставили.
// Ушло число, осталось нажатие в пустоту.
//
// ПОЧЕМУ НЕ «СДЕЛАТЬ КНОПКИ СЕРЫМИ»: приглушение говорит «сейчас нельзя, но
// вообще можно», а здесь адресата нет вовсе — ни сейчас, ни потом, пока не
// напишут экран уведомлений и выбор языка. Отсутствие объясняется
// однозначно; серая кнопка обещает то, чего нет.

Future<void> pump(
  WidgetTester tester, {
  VoidCallback? onNotificationTap,
  VoidCallback? onLanguageTap,
  int notificationCount = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Topbar(
          notificationCount: notificationCount,
          onNotificationTap: onNotificationTap,
          onLanguageTap: onLanguageTap,
        ),
      ),
    ),
  );
}

void main() {
  // КАНАРЕЙКИ К ДВУМ СТОРОЖАМ НИЖЕ (I31), И БЕЗ НИХ ТЕ НИЧЕГО НЕ
  // ДОКАЗЫВАЮТ. Оба сторожа утверждают ОТСУТСТВИЕ, а отсутствие выглядит
  // одинаково и когда правило соблюдено, и когда ключ переименовали, шапку
  // переписали или виджет вовсе перестал строиться. Здесь теми же ключами
  // ищется заведомо существующее, и на нуле тест краснеет.
  testWidgets('колокольчик нарисован, когда есть куда вести', (tester) async {
    var tapped = 0;
    await pump(tester, onNotificationTap: () => tapped++);

    expect(find.byKey(const ValueKey('topbar-notifications')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('topbar-notifications')));
    await tester.pump();

    expect(tapped, 1, reason: 'нажатие не дошло — колокольчик мёртв');
  });

  testWidgets('фишка языка нарисована, когда есть куда вести', (tester) async {
    var tapped = 0;
    await pump(tester, onLanguageTap: () => tapped++);

    expect(find.byKey(const ValueKey('topbar-language')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('topbar-language')));
    await tester.pump();

    expect(tapped, 1, reason: 'нажатие не дошло — фишка мертва');
  });

  // СОСТОЯНИЕ ГЛАВНОГО ЭКРАНА НА 20.08, И ОНО ЗАПИСАНО ТЕСТОМ, А НЕ ТОЛЬКО
  // СЛОВАМИ: `home_screen.dart:34` не передаёт ни одного из двух.
  testWidgets('колокольчику некуда вести — его нет', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('topbar-notifications')), findsNothing);
  });

  testWidgets('фишке языка некуда вести — её нет', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('topbar-language')), findsNothing);
  });

  // БЕЙДЖ УХОДИТ ВМЕСТЕ С КОЛОКОЛЬЧИКОМ, А НЕ ОСТАЁТСЯ ВИСЕТЬ.
  //
  // Проверяется отдельно, потому что бейдж рисуется СВОИМ условием
  // (`notificationCount > 0`) и от обработчика не зависит. Оставить число
  // без кнопки — это ровно N64 наизнанку: тогда сняли число и оставили
  // кнопку, здесь легко снять кнопку и оставить число.
  //
  // Число намеренно не ноль: на нуле тест прошёл бы и при снятом условии,
  // то есть не отличал бы соблюдённое правило от отсутствующего (I14).
  testWidgets('бейдж уходит вместе с колокольчиком', (tester) async {
    await pump(tester, notificationCount: 3);

    expect(find.byKey(const ValueKey('topbar-notifications')), findsNothing);
    expect(find.text('3'), findsNothing);
  });
}
