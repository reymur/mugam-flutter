import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/features/chat/screens/video_message_widgets.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ТО ЖЕ ПРАВИЛО, ЧТО В `topbar.dart` И `job_offer_card.dart`: КНОПКА БЕЗ
// АДРЕСАТА НЕ РИСУЕТСЯ. Здесь оно применено к квадрату «стоп» поверх
// загрузки — N149, третья живая дырка из обхода N147, решение владельца
// 22.08: квадрат снять, отмену не подключать.
//
// **Замер, ради которого этот файл существует** (`grep -rn
// "UploadProgressOverlay" lib --include='*.dart'` → пять вызывающих):
// четверо передают `onCancelUpload` — `file_message_widgets.dart:318`,
// `location_message_widgets.dart:235`, `video_message_widgets.dart:502` и
// `:746`; пятый, `create_status_screen.dart:1898`, не передаёт ничего. До
// правки белый квадрат рисовался безусловно, и у загрузки статуса он был
// нажимаем и не делал ничего.
//
// ПОЧЕМУ НЕ «ПОДКЛЮЧИТЬ ОТМЕНУ» — это своя работа, а не эта. За отменой
// стоит вопрос, на который здесь ответа нет: что делать с уже выгруженной
// в Storage частью и с очередью. Снятие квадрата этого вопроса не решает и
// не притворяется, что решает.
//
// ПОЧЕМУ НЕ «СДЕЛАТЬ КВАДРАТ СЕРЫМ»: приглушение говорит «сейчас нельзя, но
// вообще можно», а у загрузки статуса отмены нет вовсе — ни сейчас, ни
// потом, пока её не напишут.

Future<void> pump(WidgetTester tester, {VoidCallback? onCancel}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: UploadProgressOverlay(progress: 0.4, onCancel: onCancel),
      ),
    ),
  );
}

void main() {
  // КАНАРЕЙКА К СТОРОЖУ НИЖЕ (I31), И БЕЗ НЕЁ ТОТ НЕ ДОКАЗЫВАЕТ НИЧЕГО.
  // Сторож утверждает ОТСУТСТВИЕ, а отсутствие выглядит одинаково и когда
  // правило соблюдено, и когда ключ переименовали, наложение переписали или
  // виджет вовсе перестал строиться. Здесь тем же ключом ищется заведомо
  // существующее, и на нуле тест краснеет.
  testWidgets('квадрат нарисован, когда есть кому отменять', (tester) async {
    var cancelled = 0;
    await pump(tester, onCancel: () => cancelled++);

    expect(find.byKey(const ValueKey('upload-cancel')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('upload-cancel')));
    await tester.pump();

    expect(cancelled, 1, reason: 'нажатие не дошло — квадрат мёртв');
  });

  // СОСТОЯНИЕ ЗАГРУЗКИ СТАТУСА НА 22.08, ЗАПИСАННОЕ ТЕСТОМ, А НЕ СЛОВАМИ:
  // `create_status_screen.dart:1898` не передаёт `onCancel`.
  testWidgets('отменять некому — квадрата нет', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('upload-cancel')), findsNothing);
  });

  // КРУЖОК ПРОГРЕССА ОСТАЁТСЯ, А НЕ УХОДИТ ВМЕСТЕ С КВАДРАТОМ.
  //
  // Проверяется отдельно и намеренно: снять условием всё наложение целиком —
  // самая дешёвая «починка» этой находки, и она забрала бы у статусов
  // единственный признак того, что выгрузка идёт. Уходит нажимаемое, а не
  // показ хода.
  //
  // Значение прогресса намеренно не `null`: на `null` кружок вертится
  // неопределённо и тест прошёл бы, не отличая показанный ход от
  // отсутствующего (I14).
  testWidgets('без квадрата кружок прогресса остаётся', (tester) async {
    await pump(tester);

    final indicator = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.value, 0.4);
  });

  // ЗВЕНО, НА КОТОРОМ ДЕРЖИТСЯ «У ЧЕТВЕРЫХ НИЧЕГО НЕ ПРОПАЛО», И БЕЗ ЭТОЙ
  // ГРУППЫ ОНО БЫЛО БЫ МОИМ ЧТЕНИЕМ КОДА, А НЕ ПРОВЕРКОЙ.
  //
  // Четверо в чате передают `_cancelUploadCallback(msg)`
  // (`chat_screen.dart:549`), который отдаёт `null` ровно при
  // `msg.localSendStatus == null`. Наложение же рисуется только при
  // `queued`/`uploading`. Значит квадрат у них исчез бы тогда и только
  // тогда, когда эти два состояния достижимы у сообщения БЕЗ
  // `localSendStatus`. Здесь утверждается, что недостижимы.
  //
  // Утверждение это об ОТСУТСТВИИ, поэтому ниже стоит канарейка (I31): она
  // теми же вызовами показывает, что `queued` и `uploading` вообще
  // достижимы, — иначе «недостижимы ни при каких входах» проходило бы и у
  // функции, которая их не возвращает никогда.
  group('queued/uploading бывают только у сообщения с localSendStatus', () {
    MessageDeliveryStatus statusFor({
      String? localSendStatus,
      required bool isMe,
      required List<String> otherUids,
      required Map<String, dynamic> deliveredSeq,
      required Map<String, dynamic> lastReadMsgId,
      required int? seq,
    }) {
      return deliveryStatusFor(
        msg: Message(
          id: 'm2',
          chatId: 'c1',
          senderId: 'me',
          text: 'hello',
          type: 'image',
          seq: seq,
          localSendStatus: localSendStatus,
        ),
        isMe: isMe,
        otherUids: otherUids,
        deliveredTo: const {},
        deliveredSeq: deliveredSeq,
        lastReadMsgId: lastReadMsgId,
        allMsgIds: const ['m3', 'm2', 'm1'],
        index: 1,
      );
    }

    test('ни при одном сочетании прочих входов — 32 сочетания', () {
      var checked = 0;
      for (final isMe in [true, false]) {
        for (final otherUids in [<String>[], ['a']]) {
          for (final deliveredSeq in [
            <String, dynamic>{},
            <String, dynamic>{'a': 99},
          ]) {
            for (final lastReadMsgId in [
              <String, dynamic>{},
              <String, dynamic>{'a': 'm1'},
            ]) {
              for (final seq in [42, null]) {
                final status = statusFor(
                  localSendStatus: null,
                  isMe: isMe,
                  otherUids: otherUids,
                  deliveredSeq: deliveredSeq,
                  lastReadMsgId: lastReadMsgId,
                  seq: seq,
                );
                checked++;
                expect(
                  status == MessageDeliveryStatus.queued ||
                      status == MessageDeliveryStatus.uploading,
                  isFalse,
                  reason:
                      'при isMe=$isMe otherUids=$otherUids '
                      'deliveredSeq=$deliveredSeq lastRead=$lastReadMsgId '
                      'seq=$seq вышло $status — значит квадрат «стоп» '
                      'нарисуется там, где отменять нечем',
                );
              }
            }
          }
        }
      }

      // Число названо вслух, а не подразумевается: пустой обход дал бы
      // зелёный результат, ничего не проверив (I13, I14).
      expect(checked, 32);
    });

    // КАНАРЕЙКА: те же вызовы, заведомо достижимые состояния.
    test('канарейка — с localSendStatus оба состояния достижимы', () {
      expect(
        statusFor(
          localSendStatus: 'queued',
          isMe: true,
          otherUids: const ['a'],
          deliveredSeq: const {},
          lastReadMsgId: const {},
          seq: 42,
        ),
        MessageDeliveryStatus.queued,
      );
      expect(
        statusFor(
          localSendStatus: 'uploading',
          isMe: true,
          otherUids: const ['a'],
          deliveredSeq: const {},
          lastReadMsgId: const {},
          seq: 42,
        ),
        MessageDeliveryStatus.uploading,
      );
    });
  });
}
