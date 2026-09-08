import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/features/job_offer/screens/person_picker_core.dart';
import 'package:mugam_flutter/firebase/models.dart';

// МНОГОМЕСТНЫЙ ЛИСТ — работа 7, шаг 3 (`docs/plan.md`), 08.09.
//
// ЧТО ЗДЕСЬ ПРОВЕРЯЕТСЯ И ЧТО НЕТ, сказано сразу (I55). Сам лист
// (`pick_people_sheet.dart`) поднять в тесте нельзя без живого
// `FirebaseAuth` и `musiciansProvider` — это прод-зависимости. Поэтому
// проверяется ОБЩАЯ СЕРЕДИНА и то, что она вообще умеет нести многоместное
// поведение: отметка справа и низ листа. Что лист собирает состав и
// возвращает его — проверяется на трубке, а не здесь.
//
// Это не отговорка, а граница: вердикт, поднимающий полпрода ради галочки,
// проверяет обстановку, а не правило (N192 — цена такой обстановки уже
// заплачена).

User _u(String id, String name) => User(
      id: id,
      name: name,
      emoji: '',
      instrument: '',
      city: '',
      rating: 0,
      reviews: 0,
      available: true,
      goldRing: false,
      online: false,
      bio: '',
    );

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  group('строка человека несёт расхождение двух листов', () {
    testWidgets('без отметки справа ничего не рисуется — это одноместный лист',
        (tester) async {
      await tester.pumpWidget(_wrap(
        PersonRow(user: _u('a', 'Rafael'), onTap: () {}),
      ));
      expect(find.text('Rafael'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('с отметкой справа она видна — это многоместный',
        (tester) async {
      await tester.pumpWidget(_wrap(
        PersonRow(
          user: _u('a', 'Rafael'),
          onTap: () {},
          trailing: const Icon(Icons.check_circle),
        ),
      ));
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('нажатие зовёт то, что дал лист, а не решает само',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(
        PersonRow(user: _u('a', 'Rafael'), onTap: () => taps++),
      ));
      await tester.tap(find.text('Rafael'));
      expect(taps, 1);
    });
  });

  group('отметка различается ФОРМОЙ, а не только цветом', () {
    // Решение 10.08 о форме статуса, применённое здесь: цветом одним
    // различать нельзя. Пустой кружок и галочка — разные значки, и человек,
    // не различающий оттенки, всё равно видит, отмечен ли кто-то.
    testWidgets('отмеченный и неотмеченный — РАЗНЫЕ значки', (tester) async {
      await tester.pumpWidget(_wrap(
        Column(children: [
          PersonRow(
            user: _u('a', 'Rafael'),
            onTap: () {},
            trailing: const Icon(Icons.check_circle),
          ),
          PersonRow(
            user: _u('b', 'Teymur'),
            onTap: () {},
            trailing: const Icon(Icons.radio_button_unchecked),
          ),
        ]),
      ));
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
      // Канарейка: значки вообще нашлись. Без неё «они разные» было бы
      // истинно и когда не нарисовано ни одного (I31).
      expect(find.byType(Icon), findsNWidgets(2));
    });
  });

  group('порядок отметок — это порядок приглашений', () {
    // Правило живёт в самом листе (список, а не множество), и вердикт
    // записывает ЗАЧЕМ: множество вернуло бы состав в порядке хеша, и
    // «позвал сперва барабанщика» стало бы «позвал кого попало».
    test('снятие и повторная отметка ставят человека в конец', () {
      final picked = <String>[];
      void toggle(String uid) {
        if (!picked.remove(uid)) picked.add(uid);
      }

      toggle('a');
      toggle('b');
      toggle('c');
      expect(picked, ['a', 'b', 'c']);

      toggle('a'); // сняли
      expect(picked, ['b', 'c']);

      toggle('a'); // отметили заново
      expect(picked, ['b', 'c', 'a'],
          reason: 'вернувшийся встаёт в конец, а не на прежнее место: '
              'порядок отражает, как человек собирал состав СЕЙЧАС');
    });
  });
}
