import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/firebase/models.dart';

// Правило свежести присутствия живёт в двух местах — здесь и в
// functions/src/presence.ts (freshnessWindowMs). Разойтись им нельзя: если
// экран скажет «в чате», а сервер в ту же секунду решит слать push,
// разойдутся не цифры, а обещания, данные человеку. Значения ниже те же,
// что в functions/test/watching-chat.test.ts.
User _user({
  Duration? seenAgo,
  String? activeChatId,
  int? intervalMs,
  bool online = true,
}) => User(
  id: 'u1',
  name: 'Test',
  emoji: '🎵',
  instrument: '',
  city: '',
  rating: 0,
  reviews: 0,
  available: true,
  goldRing: false,
  online: online,
  lastSeen: seenAgo == null
      ? null
      : Timestamp.fromDate(DateTime.now().subtract(seenAgo)),
  activeChatId: activeChatId,
  presenceIntervalMs: intervalMs,
  bio: '',
);

void main() {
  group('окно свежести объявляется сборкой', () {
    test('поля нет — прежние 120 с', () {
      expect(_user().presenceFreshness, const Duration(minutes: 2));
    });

    test('интервал 30 с — окно 60 с', () {
      expect(
        _user(intervalMs: 30000).presenceFreshness,
        const Duration(seconds: 60),
      );
    });

    test('интервал 60 с — окно 120 с', () {
      expect(
        _user(intervalMs: 60000).presenceFreshness,
        const Duration(minutes: 2),
      );
    });

    test('слишком частый интервал не делает окно короче 30 с', () {
      expect(
        _user(intervalMs: 1000).presenceFreshness,
        const Duration(seconds: 30),
      );
    });

    test('редкий интервал не растягивает окно', () {
      expect(
        _user(intervalMs: 10 * 60000).presenceFreshness,
        const Duration(minutes: 2),
      );
    });
  });

  group('свежесть присутствия', () {
    test('удар только что — свежо', () {
      expect(
        _user(seenAgo: const Duration(seconds: 5), intervalMs: 30000)
            .isPresenceFresh,
        isTrue,
      );
    });

    test('молчит дольше своего окна — не свежо', () {
      expect(
        _user(seenAgo: const Duration(seconds: 70), intervalMs: 30000)
            .isPresenceFresh,
        isFalse,
      );
    });

    test('одно пропущенное сердцебиение не выталкивает наружу', () {
      expect(
        _user(seenAgo: const Duration(seconds: 31), intervalMs: 30000)
            .isPresenceFresh,
        isTrue,
      );
    });

    test('lastSeen нет вовсе — не свежо', () {
      expect(_user(intervalMs: 30000).isPresenceFresh, isFalse);
    });

    test('убитое приложение с online:true не считается свежим', () {
      // Ровно дефект, из-за которого голому `online` доверять нельзя:
      // приложение убили, поле осталось true навсегда.
      expect(
        _user(seenAgo: const Duration(hours: 5), online: true).isPresenceFresh,
        isFalse,
      );
    });
  });

  // isActuallyOnline обслуживает зелёную точку на 13 экранах и «● Onlayn»
  // в шапке чата. Он обязан судить по тому же окну, что и строка в
  // плашке переговоров под ним: при разных окнах два индикатора на одном
  // экране начинают противоречить друг другу.
  group('зелёная точка судит по тому же окну', () {
    test('сборка с 30-секундным ударом: 70 с молчания — уже не онлайн', () {
      expect(
        _user(seenAgo: const Duration(seconds: 70), intervalMs: 30000)
            .isActuallyOnline,
        isFalse,
      );
    });

    test('та же сборка, 40 с молчания — ещё онлайн', () {
      expect(
        _user(seenAgo: const Duration(seconds: 40), intervalMs: 30000)
            .isActuallyOnline,
        isTrue,
      );
    });

    test('сборка без объявленного интервала — прежние 120 с', () {
      expect(
        _user(seenAgo: const Duration(seconds: 70)).isActuallyOnline,
        isTrue,
      );
      expect(
        _user(seenAgo: const Duration(seconds: 130)).isActuallyOnline,
        isFalse,
      );
    });

    test('явный выход из аккаунта гасит точку независимо от свежести', () {
      // stop() пишет online:false — единственный случай, который ловится
      // самим флагом, а не сроком годности.
      expect(
        _user(
          seenAgo: const Duration(seconds: 5),
          intervalMs: 30000,
          online: false,
        ).isActuallyOnline,
        isFalse,
      );
    });

    test('наследие mugam-v2: online:true без lastSeen — не онлайн', () {
      // В проде два таких документа, флаг застрял на месяц.
      expect(_user(online: true).isActuallyOnline, isFalse);
    });
  });

  group('смотрит ли в ЭТОТ чат', () {
    const chat = 'chat-1';

    test('тот чат и свежая отметка — да', () {
      expect(
        _user(
          seenAgo: const Duration(seconds: 10),
          activeChatId: chat,
          intervalMs: 30000,
        ).isViewingChat(chat),
        isTrue,
      );
    });

    test('другой чат — нет, даже при свежей отметке', () {
      expect(
        _user(
          seenAgo: const Duration(seconds: 10),
          activeChatId: 'другой',
          intervalMs: 30000,
        ).isViewingChat(chat),
        isFalse,
      );
    });

    test('вышел из чата (null) — нет', () {
      expect(
        _user(seenAgo: const Duration(seconds: 10), intervalMs: 30000)
            .isViewingChat(chat),
        isFalse,
      );
    });

    test('застрявшая отметка без свежести не считается — это и был N19', () {
      // Отметка «я в этом чате» осталась от давнего визита: приложение
      // свернули, убили или потеряло сеть. Без срока годности она глушила
      // уведомления месяцами.
      expect(
        _user(
          seenAgo: const Duration(hours: 54),
          activeChatId: chat,
          intervalMs: 30000,
        ).isViewingChat(chat),
        isFalse,
      );
    });
  });
}
