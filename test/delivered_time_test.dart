import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/features/chat/screens/message_info_screen.dart';

// Экран «Məlumat» показал на устройстве 02.08 «Çatdırıldı 20:38» под
// «Oxundu 20:37» — доставка позже прочтения. Причина: время доставки
// бралось из `deliveredTo`, отметки ВИЗИТА, которая переписывается при
// каждом открытии чата. Здесь закреплены оба следствия правки: время
// берётся из отметки события, и порядок двух строк не может нарушиться
// ни при какой гонке писателей.
void main() {
  const uid = 'u1';
  const delivered = '2026-08-02T16:37:36.000Z';
  const read = '2026-08-02T16:37:38.000Z';
  const laterVisit = '2026-08-02T16:38:50.000Z';

  String? resolve({
    Map<String, dynamic> deliveredAt = const {},
    Map<String, dynamic> deliveredTo = const {},
    Map<String, dynamic> lastReadAt = const {},
    bool isRead = false,
    DateTime? sentAt,
  }) => resolveDeliveredTime(
    uid: uid,
    isRead: isRead,
    deliveredAt: deliveredAt,
    deliveredTo: deliveredTo,
    lastReadAt: lastReadAt,
    sentAt: sentAt,
  );

  group('источник времени доставки', () {
    test('новая отметка события имеет приоритет над отметкой визита', () {
      expect(
        resolve(
          deliveredAt: {uid: delivered},
          deliveredTo: {uid: laterVisit},
        ),
        delivered,
      );
    });

    test('переходное окно: без новой отметки берётся старая', () {
      expect(resolve(deliveredTo: {uid: delivered}), delivered);
    });

    test('нет ни одной отметки — времени нет', () {
      expect(resolve(), isNull);
    });

    test('legacy-значение bool true отметкой времени не считается', () {
      expect(resolve(deliveredAt: {uid: true}, deliveredTo: {uid: true}), isNull);
    });
  });

  group('инвариант: доставка не позже прочтения', () {
    test('ровно наблюдавшийся на устройстве случай — визит после прочтения', () {
      expect(
        resolve(
          deliveredTo: {uid: laterVisit},
          lastReadAt: {uid: read},
          isRead: true,
        ),
        read,
      );
    });

    test('гонка писателей: событие доставки записалось после расписки', () {
      // Получатель открыл чат ДО прихода сообщения: экран чата пишет
      // расписку, список чатов — доставку, и порядок между ними не
      // гарантирован. Показать доставку позже прочтения нельзя.
      expect(
        resolve(
          deliveredAt: {uid: laterVisit},
          lastReadAt: {uid: read},
          isRead: true,
        ),
        read,
      );
    });

    test('нормальный порядок не трогается', () {
      expect(
        resolve(
          deliveredAt: {uid: delivered},
          lastReadAt: {uid: read},
          isRead: true,
        ),
        delivered,
      );
    });

    test('совпадение до миллисекунды не считается нарушением', () {
      expect(
        resolve(
          deliveredAt: {uid: read},
          lastReadAt: {uid: read},
          isRead: true,
        ),
        read,
      );
    });

    test('не прочитано — ограничение не применяется', () {
      expect(
        resolve(
          deliveredAt: {uid: laterVisit},
          lastReadAt: {uid: read},
          isRead: false,
        ),
        laterVisit,
      );
    });

    test('прочитано, но времени прочтения нет — отдаём что есть', () {
      expect(
        resolve(deliveredAt: {uid: laterVisit}, isRead: true),
        laterVisit,
      );
    });

    test('неразбираемое время не роняет экран', () {
      expect(
        resolve(
          deliveredAt: {uid: 'не дата'},
          lastReadAt: {uid: read},
          isRead: true,
        ),
        'не дата',
      );
    });
  });

  // Вторая граница, найденная на устройстве 02.08 сценарием «получатель
  // уже сидит в чате»: отметка доставки живёт НА ЧАТЕ, а не на сообщении,
  // и может быть старше самого сообщения. На экране это выглядело как
  // «Çatdırıldı 21:28» под «Göndərildi 21:32».
  group('инвариант: доставка не раньше отправки', () {
    final sent = DateTime.parse('2026-08-02T17:32:52.000Z');
    const sentIso = '2026-08-02T17:32:52.000Z';
    const readAfterSent = '2026-08-02T17:32:53.000Z';
    const staleDelivery = '2026-08-02T17:28:41.000Z';

    test('ровно наблюдавшийся случай — отметка от прошлой доставки', () {
      expect(
        resolve(
          deliveredAt: {uid: staleDelivery},
          lastReadAt: {uid: readAfterSent},
          isRead: true,
          sentAt: sent,
        ),
        readAfterSent,
      );
    });

    test('отметка старше сообщения и не прочитано — времени нет', () {
      expect(
        resolve(
          deliveredAt: {uid: staleDelivery},
          isRead: false,
          sentAt: sent,
        ),
        isNull,
      );
    });

    test('отметка ровно в момент отправки — годится', () {
      expect(
        resolve(deliveredAt: {uid: sentIso}, isRead: false, sentAt: sent),
        sentIso,
      );
    });

    test('обе границы разом: отметка старше отправки, но есть прочтение', () {
      // Нижняя граница отсекает отметку, верхняя даёт ответ.
      expect(
        resolve(
          deliveredTo: {uid: staleDelivery},
          lastReadAt: {uid: readAfterSent},
          isRead: true,
          sentAt: sent,
        ),
        readAfterSent,
      );
    });

    test('без времени сообщения нижняя граница не применяется', () {
      // Сообщение без timestamp — сравнивать не с чем, поведение прежнее.
      expect(
        resolve(deliveredAt: {uid: staleDelivery}, isRead: false),
        staleDelivery,
      );
    });

    test('прочитано, отметки доставки нет вовсе — берём время прочтения', () {
      expect(
        resolve(lastReadAt: {uid: readAfterSent}, isRead: true, sentAt: sent),
        readAfterSent,
      );
    });

    test('не прочитано и отметки нет — времени нет', () {
      expect(resolve(sentAt: sent), isNull);
    });
  });
}
