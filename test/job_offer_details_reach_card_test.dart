import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/day_details.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';
import 'package:mugam_flutter/features/job_offer/widgets/job_offer_card.dart';

// ЧИТАТЕЛЬ ПРОТИВ СВОЕГО ПИСАТЕЛЯ — N139.
//
// Все прочие тесты предложения строят `JobOffer` КОНСТРУКТОРОМ, где любое
// поле передаётся прямо. Прод так не ходит ни разу: он идёт
// `watchOffers` → `JobOffer.fromMap` → карточка. Ровно поэтому три поля,
// которых писатель не пишет с 14.08, простояли читаемыми и никого не
// уронили — порча конструктора роняет тесты и не доказывает ничего (I55).
//
// Здесь настоящий путь целиком: карта той формы, что пишет `createOffer`,
// → `fromMap` → нарисованная карточка.
//
// ДЕТАЛИ РАЗНЫЕ У РАЗНЫХ ДНЕЙ, И ЭТО НЕ УКРАШЕНИЕ ТЕСТА. Плоская тройка
// `eventTime`/`eventLocation`/`eventNotes` держала ОДНО время на всё
// предложение — такой тест ею не пройти даже случайно: он требует, чтобы у
// 9-го было 20:00, а у 10-го 19:00 одновременно.

const boss = 'boss-uid';
const player = 'player-uid';

const dayA = '2026-08-09';
const dayB = '2026-08-10';
const dayC = '2026-08-11';

/// Карта РОВНО той формы, что пишет `createOffer`
/// (`job_offer_repository.dart:70-83`) — семь ключей, больше правило и не
/// пропустит (`firestore.rules:736-739`).
///
/// **`details` собирается через `DayDetails.toMap()` — тот же самый
/// сериализатор, которым пишет прод**, а не переписан здесь руками. Иначе
/// тест проверял бы моё представление о форме записи, а не форму записи.
Map<String, dynamic> writtenByCreateOffer() => {
  'createdBy': boss,
  'createdAt': '2026-08-08T10:00:00.000',
  'anchorMessageId': 'msg-1',
  'dates': const [dayA, dayB, dayC],
  'eventType': 'Toy',
  'details': {
    dayA: const DayDetails(
      time: '20:00',
      location: 'Gənclər sarayı',
      dress: 'Qara kostyum',
    ).toMap(),
    dayB: const DayDetails(time: '19:00', location: 'Şəhər klubu').toMap(),
    // dayC деталей не имеет вовсе — дни без единой подробности в карту не
    // попадают (`createOffer`), и читатель обязан это пережить.
  },
  'answers': const <String, dynamic>{},
};

Future<void> pumpCard(WidgetTester tester, JobOffer o) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: JobOfferCard(
            offer: o,
            viewerUid: player,
            recipientUid: player,
            initiatorName: 'Rafael',
            recipientName: 'Teymur',
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('детали доезжают от писателя до карточки (N139)', () {
    // КАНАРЕЙКА, И ОНА ОБЯЗАТЕЛЬНА (I31, I14).
    //
    // Без неё красный на деталях не отличить от «`fromMap` не разобрал
    // вообще ничего»: оба дают пустой экран. Эта проверка утверждает
    // НАЛИЧИЕ и потому сама себе сторож.
    testWidgets('канарейка: fromMap разбирает соседние поля', (tester) async {
      final offer = JobOffer.fromMap('offer-1', writtenByCreateOffer());

      expect(offer.createdBy, boss, reason: 'разбор не видит createdBy');
      expect(offer.dates, const [dayA, dayB, dayC]);
      expect(offer.eventType, 'Toy');
      expect(offer.roleOf(boss), OfferRole.initiator);
    });

    testWidgets('«Ətraflı» есть на карточке', (tester) async {
      final offer = JobOffer.fromMap('offer-1', writtenByCreateOffer());
      await pumpCard(tester, offer);

      expect(
        find.text('Ətraflı'),
        findsOneWidget,
        reason: 'детали записаны, а раскрыть их на карточке нечем',
      );
    });

    testWidgets('у каждого дня СВОИ время и место', (tester) async {
      final offer = JobOffer.fromMap('offer-1', writtenByCreateOffer());
      await pumpCard(tester, offer);

      await tester.tap(find.text('Ətraflı'));
      await tester.pumpAndSettle();

      // Оба дня сразу — именно это и невыразимо плоской тройкой.
      expect(find.text('20:00'), findsOneWidget);
      expect(find.text('19:00'), findsOneWidget);
      expect(find.text('Gənclər sarayı'), findsOneWidget);
      expect(find.text('Şəhər klubu'), findsOneWidget);
      expect(find.text('Qara kostyum'), findsOneWidget);
    });

    testWidgets('день без деталей не рисует пустых строк', (tester) async {
      final offer = JobOffer.fromMap('offer-1', writtenByCreateOffer());
      await pumpCard(tester, offer);

      await tester.tap(find.text('Ətraflı'));
      await tester.pumpAndSettle();

      // Подписи ровно по числу заполненных полей: время у двух дней, место
      // у двух, одежда у одного. Счёт назван вслух (I13) — «есть хоть
      // что-то» здесь не годится.
      expect(find.text('Saat'), findsNWidgets(2));
      expect(find.text('Yer'), findsNWidgets(2));
      expect(find.text('Geyim'), findsOneWidget);
    });

    testWidgets('предложение вовсе без деталей не показывает «Ətraflı»', (
      tester,
    ) async {
      final data = writtenByCreateOffer()..['details'] = <String, dynamic>{};
      final offer = JobOffer.fromMap('offer-1', data);
      await pumpCard(tester, offer);

      expect(find.text('Ətraflı'), findsNothing);
    });
  });

  // ГОЛОС ПРОВЕРЯЕТСЯ ОТДЕЛЬНО, ПОТОМУ ЧТО КАРТОЧКА ЕГО НЕ РИСУЕТ. Тесты
  // выше идут до экрана и потому молчат о полях, которых на экране нет:
  // зелёные они и с голосом, и без него. Показ записи в карточке — работа
  // шага 2, а чтение обязано быть верным уже сейчас, иначе к тому шагу
  // придём с полем, которое никогда не доезжало.
  group('голос переживает запись и чтение (N139)', () {
    test('voiceUrl и волна доезжают', () {
      const written = DayDetails(
        time: '20:00',
        voicePath: '/tmp/запись.m4a',
        voiceWaveform: [3, 7, 11],
        voiceUrl: 'https://хранилище/запись.m4a',
      );

      final read = DayDetails.fromMap(written.toMap());

      expect(read.voiceUrl, 'https://хранилище/запись.m4a');
      expect(read.voiceWaveform, const [3, 7, 11]);
      expect(read.time, '20:00');
    });

    test('voicePath НЕ восстанавливается — его в базе нет', () {
      const written = DayDetails(
        voicePath: '/tmp/запись.m4a',
        voiceUrl: 'https://хранилище/запись.m4a',
      );

      // Путь во временной папке чужого телефона: восстанавливать его
      // здесь означало бы выдать несуществующий файл за существующий.
      expect(DayDetails.fromMap(written.toMap()).voicePath, isNull);
    });

    test('день с ОДНИМ голосовым не считается пустым', () {
      // Ровно тот случай, ради которого `isEmpty` перестал спрашивать один
      // `voicePath`: из базы приходит `voiceUrl`, а пути нет и быть не
      // может. Прежним условием такой день читался бы пустым и не
      // показывался вовсе.
      const fromDb = DayDetails(voiceUrl: 'https://хранилище/запись.m4a');

      expect(fromDb.isEmpty, isFalse);
      expect(fromDb.isNotEmpty, isTrue);
    });

    test('пустой день пуст по-прежнему', () {
      // Канарейка к предыдущему: если бы `isEmpty` начал возвращать `false`
      // всегда, тест выше прошёл бы, ничего не проверив (I31).
      expect(const DayDetails().isEmpty, isTrue);
    });

    test('волна из базы приходит списком чисел, а не List<dynamic>', () {
      // Firestore отдаёт `List<dynamic>`, и жёсткое приведение к
      // `List<int>` здесь роняло бы карточку целиком из-за одного поля
      // (I49). Вход написан так, как его отдаёт база.
      final read = DayDetails.fromMap(<String, dynamic>{
        'time': '',
        'location': '',
        'dress': '',
        'voiceUrl': 'https://хранилище/запись.m4a',
        'voiceWaveform': <dynamic>[3, 7, 11],
      });

      expect(read.voiceWaveform, const [3, 7, 11]);
    });
  });
}
