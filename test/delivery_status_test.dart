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

Message _msg({String id = 'm2', String? localSendStatus, int? seq = 42}) {
  return Message(
    id: id,
    chatId: 'c1',
    senderId: 'me',
    text: 'hello',
    type: 'text',
    seq: seq,
    localSendStatus: localSendStatus,
  );
}

void main() {
  const allIds = ['m3', 'm2', 'm1']; // m3 — новейшее
  const index = 1; // проверяем m2

  MessageDeliveryStatus statusFor({
    required List<String> otherUids,
    Map<String, dynamic> deliveredTo = const {},
    Map<String, dynamic> deliveredSeq = const {},
    Map<String, dynamic> lastReadMsgId = const {},
    bool isMe = true,
    String? localSendStatus,
    int? msgSeq = 42,
  }) {
    return deliveryStatusFor(
      msg: _msg(localSendStatus: localSendStatus, seq: msgSeq),
      isMe: isMe,
      otherUids: otherUids,
      deliveredTo: deliveredTo,
      deliveredSeq: deliveredSeq,
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

  group('отметка доставки по номеру, а не по времени (B18)', () {
    test('номер дошёл до этого сообщения — две серые', () {
      expect(
        statusFor(otherUids: ['a'], deliveredSeq: {'a': 42}),
        MessageDeliveryStatus.delivered,
      );
    });

    test('номер дошёл дальше — тоже доставлено', () {
      expect(
        statusFor(otherUids: ['a'], deliveredSeq: {'a': 99}),
        MessageDeliveryStatus.delivered,
      );
    });

    test('номер отстал — НЕ доставлено, даже если старая отметка стоит', () {
      // Ровно случай из боевых данных: deliveredTo на 8,3 часа старше
      // сообщения, а галочка горела. Номер эту ложь перебивает.
      expect(
        statusFor(
          otherUids: ['a'],
          deliveredTo: {'a': '2026-08-02T05:52:03.000Z'},
          deliveredSeq: {'a': 41},
        ),
        MessageDeliveryStatus.sentUnconfirmed,
      );
    });

    test('номера нет вовсе — переходное окно, работает старая отметка', () {
      expect(
        statusFor(otherUids: ['a'], deliveredTo: {'a': 'ts'}),
        MessageDeliveryStatus.delivered,
      );
    });

    test('у сообщения нет номера — тоже запасной вариант', () {
      expect(
        statusFor(
          otherUids: ['a'],
          deliveredTo: {'a': 'ts'},
          deliveredSeq: {'a': 1},
          msgSeq: null,
        ),
        MessageDeliveryStatus.delivered,
      );
    });

    test('группа: один по номеру, второй по старой отметке', () {
      expect(
        statusFor(
          otherUids: ['a', 'b'],
          deliveredTo: {'b': 'ts'},
          deliveredSeq: {'a': 42},
        ),
        MessageDeliveryStatus.delivered,
      );
    });

    test('группа: один отстал по номеру — одна галочка', () {
      expect(
        statusFor(
          otherUids: ['a', 'b'],
          deliveredTo: {'a': 'ts', 'b': 'ts'},
          deliveredSeq: {'a': 42, 'b': 41},
        ),
        MessageDeliveryStatus.sentUnconfirmed,
      );
    });

    test('прочтение важнее любой отметки доставки', () {
      expect(
        statusFor(
          otherUids: ['a'],
          deliveredSeq: {'a': 1},
          lastReadMsgId: {'a': 'm2'},
        ),
        MessageDeliveryStatus.read,
      );
    });
  });
}
