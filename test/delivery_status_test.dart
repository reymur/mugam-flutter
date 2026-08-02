import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/features/chat/screens/video_message_widgets.dart';
import 'package:mugam_flutter/firebase/models.dart';

// Галочки под своим сообщением (B29). До правки сюда приходил один
// «собеседник» — `members.firstWhere((m) => m != currentUid)`, — и в
// группе это был первый попавшийся участник, чьё состояние выдавалось за
// состояние всей группы. Тесты закрепляют обе половины: диалог должен
// вести себя ровно как раньше, группа — отвечать про всех.
//
// Порядок allMsgIds: индекс 0 — самое новое сообщение, дальше вглубь
// истории. Поэтому «прочитано» это index >= индекса последнего
// прочитанного, а не наоборот.

Message _msg({String id = 'm2', String? localSendStatus}) {
  return Message(
    id: id,
    chatId: 'c1',
    senderId: 'me',
    text: 'hello',
    type: 'text',
    localSendStatus: localSendStatus,
  );
}

void main() {
  const allIds = ['m3', 'm2', 'm1']; // m3 — новейшее
  const index = 1; // проверяем m2

  MessageDeliveryStatus statusFor({
    required List<String> otherUids,
    Map<String, dynamic> deliveredTo = const {},
    Map<String, dynamic> lastReadMsgId = const {},
    bool isMe = true,
    String? localSendStatus,
  }) {
    return deliveryStatusFor(
      msg: _msg(localSendStatus: localSendStatus),
      isMe: isMe,
      otherUids: otherUids,
      deliveredTo: deliveredTo,
      lastReadMsgId: lastReadMsgId,
      allMsgIds: allIds,
      index: index,
    );
  }

  group('диалог — поведение не изменилось', () {
    test('никаких отметок — одна галочка', () {
      expect(
        statusFor(otherUids: ['a']),
        MessageDeliveryStatus.sentUnconfirmed,
      );
    });

    test('есть отметка доставки — две серые', () {
      expect(
        statusFor(otherUids: ['a'], deliveredTo: {'a': 'ts'}),
        MessageDeliveryStatus.delivered,
      );
    });

    test('прочитано до этого сообщения включительно — две синие', () {
      expect(
        statusFor(otherUids: ['a'], lastReadMsgId: {'a': 'm2'}),
        MessageDeliveryStatus.read,
      );
    });

    test('прочитано только более новое — это сообщение тоже прочитано', () {
      expect(
        statusFor(otherUids: ['a'], lastReadMsgId: {'a': 'm3'}),
        MessageDeliveryStatus.read,
      );
    });

    test('прочитано лишь более старое — ещё не прочитано', () {
      expect(
        statusFor(
          otherUids: ['a'],
          deliveredTo: {'a': 'ts'},
          lastReadMsgId: {'a': 'm1'},
        ),
        MessageDeliveryStatus.delivered,
      );
    });

    test('отметка на сообщение вне загруженного окна не считается', () {
      expect(
        statusFor(otherUids: ['a'], lastReadMsgId: {'a': 'm_давно_вытеснено'}),
        MessageDeliveryStatus.sentUnconfirmed,
      );
    });
  });

  group('группа — отвечает про всех, а не про первого попавшегося', () {
    test('прочитал один из трёх — синими НЕ становится', () {
      expect(
        statusFor(
          otherUids: ['a', 'b', 'c'],
          deliveredTo: {'a': 'ts', 'b': 'ts', 'c': 'ts'},
          lastReadMsgId: {'a': 'm2'},
        ),
        MessageDeliveryStatus.delivered,
      );
    });

    test('прочитали все — две синие', () {
      expect(
        statusFor(
          otherUids: ['a', 'b', 'c'],
          lastReadMsgId: {'a': 'm2', 'b': 'm3', 'c': 'm2'},
        ),
        MessageDeliveryStatus.read,
      );
    });

    test('доставлено не всем — одна галочка', () {
      expect(
        statusFor(
          otherUids: ['a', 'b', 'c'],
          deliveredTo: {'a': 'ts', 'b': 'ts'},
        ),
        MessageDeliveryStatus.sentUnconfirmed,
      );
    });

    test('прочитавший без отметки доставки считается получившим', () {
      // Иначе группа откатывалась бы с двух галочек на одну из-за старых
      // документов, где deliveredTo не заполнен.
      expect(
        statusFor(
          otherUids: ['a', 'b'],
          deliveredTo: {'b': 'ts'},
          lastReadMsgId: {'a': 'm2'},
        ),
        MessageDeliveryStatus.delivered,
      );
    });

    test('порядок участников больше ни на что не влияет', () {
      final direct = statusFor(
        otherUids: ['a', 'b'],
        deliveredTo: {'a': 'ts'},
        lastReadMsgId: {'a': 'm2'},
      );
      final reversed = statusFor(
        otherUids: ['b', 'a'],
        deliveredTo: {'a': 'ts'},
        lastReadMsgId: {'a': 'm2'},
      );
      expect(direct, reversed);
      expect(direct, MessageDeliveryStatus.sentUnconfirmed);
    });
  });

  group('локальное состояние очереди важнее любых отметок', () {
    test('в очереди', () {
      expect(
        statusFor(otherUids: ['a'], localSendStatus: 'queued'),
        MessageDeliveryStatus.queued,
      );
    });

    test('загружается', () {
      expect(
        statusFor(
          otherUids: ['a'],
          localSendStatus: 'uploading',
          lastReadMsgId: {'a': 'm2'},
        ),
        MessageDeliveryStatus.uploading,
      );
    });

    test('не отправилось', () {
      expect(
        statusFor(otherUids: ['a'], localSendStatus: 'failed'),
        MessageDeliveryStatus.failed,
      );
    });
  });

  group('гашение расчёта', () {
    test('чужое сообщение — галочек нет', () {
      expect(
        statusFor(
          otherUids: ['a'],
          isMe: false,
          lastReadMsgId: {'a': 'm2'},
        ),
        MessageDeliveryStatus.sentUnconfirmed,
      );
    });

    test('в чате больше никого — считать нечего', () {
      expect(
        statusFor(otherUids: const []),
        MessageDeliveryStatus.sentUnconfirmed,
      );
    });
  });
}
