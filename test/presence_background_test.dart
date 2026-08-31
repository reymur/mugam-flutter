import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/presence/presence_service.dart';

// СТОРОЖ НА ПРОВОДКУ, А НЕ НА ПРАВИЛО (N171).
//
// Правило здесь однострочное: «в фоне отметка „смотрю сюда“ публикуется
// как null». Покрыть его чистой функцией было бы дёшево и бесполезно —
// правило оказалось бы покрыто, а вызов из ветви жизненного цикла мог бы
// быть не сделан вовсе, и прогон остался бы зелёным (I64: проверять не
// наличие правила, а каждого, кто под него подпадает).
//
// Поэтому проверка держит путь ЦЕЛИКОМ: сообщение о смене состояния
// уходит в настоящий список наблюдателей `WidgetsBinding`, туда службу
// записывает её собственный `start()`, и наблюдается значение, которое
// дошло до записи. Оборвись любое из трёх звеньев — подписка, ветвь,
// вычисление — здесь станет красно.
//
// Все вердикты ниже утверждают НАЛИЧИЕ («запись была, и в ней вот что»),
// а не отсутствие, поэтому канарейка им не нужна: ослепший разбор дал бы
// ноль записей и покраснел бы сам (I31).

class _Published {
  const _Published({
    required this.online,
    required this.chat,
    required this.event,
    required this.intervalMs,
  });

  final bool online;
  final String? chat;
  final String? event;
  final int? intervalMs;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final service = PresenceService.instance;
  final published = <_Published>[];

  // Настоящий путь доставки: через список наблюдателей биндинга, а не
  // прямым вызовом `service.didChangeAppLifecycleState(...)`. Прямой вызов
  // проверил бы ветвь и промолчал бы о подписке (I55: портить и проверять
  // надо тот путь, которым идёт прод).
  void deliver(AppLifecycleState state) =>
      binding.handleAppLifecycleStateChanged(state);

  // iOS шлёт сворачивание ступенями, а не одним состоянием.
  void background() {
    deliver(AppLifecycleState.inactive);
    deliver(AppLifecycleState.hidden);
    deliver(AppLifecycleState.paused);
  }

  void foreground() {
    deliver(AppLifecycleState.hidden);
    deliver(AppLifecycleState.inactive);
    deliver(AppLifecycleState.resumed);
  }

  setUp(() {
    published.clear();
    service.debugReset();
    service.debugSetWriter((
      uid, {
      required bool online,
      String? activeChatId,
      String? activeEventId,
      int? presenceIntervalMs,
    }) {
      published.add(
        _Published(
          online: online,
          chat: activeChatId,
          event: activeEventId,
          intervalMs: presenceIntervalMs,
        ),
      );
    });
    service.start('u1');
    deliver(AppLifecycleState.resumed);
  });

  tearDown(service.debugReset);

  group('отметка «смотрю сюда» и уход в фон (N171)', () {
    test('на переднем плане чат публикуется', () {
      service.setActiveChat('c1');

      expect(published, isNotEmpty);
      expect(published.last.chat, 'c1');
      expect(published.last.online, isTrue);
    });

    test('уход в фон снимает отметку чата немедленно, своей записью', () {
      service.setActiveChat('c1');
      final before = published.length;

      background();

      // Первый вердикт — про ПРОВОДКУ: ветвь фона обязана сделать запись.
      // Без неё отметка снималась бы только протуханием присутствия, то
      // есть через окно свежести, и всю минуту push от последнего
      // собеседника глушился бы.
      expect(
        published.length,
        greaterThan(before),
        reason: 'ветвь ухода в фон не сделала записи вовсе',
      );
      expect(published.last.chat, isNull);
    });

    test('уход в фон не гасит саму точку присутствия', () {
      service.setActiveChat('c1');

      background();

      // `online` отвечает на другой вопрос — «жив ли человек», — и мигать
      // от короткого сворачивания не должен. Снимается только отметка.
      expect(published.last.online, isTrue);
    });

    test('сворачивание тремя ступенями стоит ОДНОЙ записи', () {
      service.setActiveChat('c1');
      final before = published.length;

      background();

      expect(published.length - before, 1);
    });

    test('без открытого чата и карточки уход в фон не пишет ничего', () {
      final before = published.length;

      background();

      expect(published.length, before);
    });

    test('возврат возвращает отметку — экран сам её не вернёт', () {
      service.setActiveChat('c1');
      background();
      expect(published.last.chat, isNull);

      foreground();

      // Экран чата всё это время оставался открытым и `setActiveChat`
      // повторно не зовёт: отметку обязан вернуть сам возврат из фона.
      expect(published.last.chat, 'c1');
    });

    test('карточка мероприятия — та же отметка и тот же уход', () {
      // Отметок «смотрю сюда» две из двух: чат и карточка. Сервер глушит
      // по обеим (`isWatchingChatDecision`, `isWatchingEventDecision`),
      // значит и снимать надо обе — иначе правило соблюдено у одного из
      // двух подпадающих (I64).
      service.setActiveEvent('e1');
      expect(published.last.event, 'e1');

      background();
      expect(published.last.event, isNull);

      foreground();
      expect(published.last.event, 'e1');
    });

    test('чат и карточка снимаются одной записью, а не двумя', () {
      service.setActiveChat('c1');
      service.setActiveEvent('e1');
      final before = published.length;

      background();

      expect(published.length - before, 1);
      expect(published.last.chat, isNull);
      expect(published.last.event, isNull);
    });

    test('интервал сердцебиения едет и с фоновой записью', () {
      // По нему сервер считает срок годности отметки. Уехал бы он из
      // фоновой записи — окно свежести молча вернулось бы к 120 с.
      service.setActiveChat('c1');

      background();

      expect(published.last.intervalMs, 30000);
    });
  });
}
