import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/features/agreements/screens/agreements_screen.dart';
import 'package:mugam_flutter/firebase/firestore_service.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ДВЕРЬ К ВЕЧЕРУ — ТРИ СОСТОЯНИЯ, И ДВА ИЗ НИХ НЕЛЬЗЯ СВОДИТЬ (N92, I47).
//
// Проверяется здесь ровно то, ради чего дверь и писалась: пока карточку
// открывали изнутри экрана, данные всегда были на руках, и «пусто» значило
// «удалено». Дверь снаружи — из уведомления — открывает её там, где потоки
// могут ещё грузиться, и то же «пусто» значит «ещё не пришло».
//
// Стало достижимо снаружи 26.08 вместе с путём `/event/:eventId` (N59):
// до него уведомление вело в общий экран, и эти два состояния человек не
// видел вовсе.
//
// ЧЕГО НАБОР НЕ ПРОВЕРЯЕТ (I50): саму карточку — что она рисует состав,
// время и место. Это её собственные тесты; здесь только дверь.

const uid = 'me-uid';

PersonalEvent event(String id) => PersonalEvent.fromFirestore(id, {
  'ownerUid': uid,
  'date': '2026-09-14T20:00:00.000',
  'musicians': const <String>[],
  'answersWrittenByOwner': true,
  'status': 'agreed',
});

Future<void> pumpDoor(
  WidgetTester tester, {
  required List<PersonalEvent>? own,
  required List<PersonalEvent>? asParticipant,
  String eventId = 'e-1',
}) async {
  // `null` — поток НЕ ОТВЕТИЛ. Пустой список — ответ «ничего нет», и это
  // другое: именно на различии двух этих случаев дверь и стоит.
  Stream<List<PersonalEvent>> s(List<PersonalEvent>? v) =>
      v == null ? StreamController<List<PersonalEvent>>().stream : Stream.value(v);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        personalEventsProvider.overrideWith((ref, _) => s(own)),
        eventsAsParticipantProvider.overrideWith((ref, _) => s(asParticipant)),
      ],
      child: MaterialApp(
        home: eventDetailBody(eventId: eventId, currentUid: uid),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('потоки молчат — ждём, и НЕ говорим «удалено»', (tester) async {
    await pumpDoor(tester, own: null, asParticipant: null);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.text('Bu qeyd artıq mövcud deyil'),
      findsNothing,
      reason: 'загрузка выдана за удаление — человек, пришедший по '
          'уведомлению, прочтёт «этого больше нет» про живой вечер',
    );
  });

  // ОДИН МОЛЧИТ — ТОЖЕ ЖДЁМ. Без этой проверки условие `own.asData == null
  // || asParticipant.asData == null` можно было бы сузить до одного потока,
  // и половина случаев «ещё не пришло» стала бы «удалено».
  testWidgets('ответил только один поток — всё ещё ждём', (tester) async {
    await pumpDoor(tester, own: const [], asParticipant: null);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Bu qeyd artıq mövcud deyil'), findsNothing);
  });

  testWidgets('оба ответили, вечера нет — «удалено», и НЕ ждём', (
    tester,
  ) async {
    await pumpDoor(tester, own: const [], asParticipant: const []);

    expect(find.text('Bu qeyd artıq mövcud deyil'), findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'удаление выдано за загрузку — человек будет ждать вечно',
    );
  });

  // ТРЕТЬЕ СОСТОЯНИЕ — «НАШЛИ» — ЗДЕСЬ НЕ ПРОВЕРЯЕТСЯ, И ЭТО ГРАНИЦА,
  // А НЕ ПРОПУСК (I50).
  //
  // Проверка была написана и УПАЛА `FirebaseException`: найдя вечер, дверь
  // отдаёт саму карточку, а та тянет Firebase напрямую (имена участников,
  // договорённости). Поднять её здесь нечем — подделки Firestore в проекте
  // нет.
  //
  // **Что от этого теряется, названо прямо:** набор не отличит рабочую дверь
  // от двери, которая НИКОГДА не показывает вечер. Обе проверки выше
  // остались бы зелёными.
  //
  // **Чем это закрыто вместо теста.** Обе проверки выше утверждают НАЛИЧИЕ —
  // кружок ожидания есть, надпись «этого больше нет» есть, — то есть сами
  // себе канарейки (I31): ослепни разбор, они покраснеют, а не позеленеют.
  // Само же «вечер показался» проверяется глазами на трубке: нажать
  // уведомление о вечере и увидеть карточку. Шаг записан в
  // `docs/check-job-offer-card.md`.
}
