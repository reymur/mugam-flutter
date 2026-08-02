import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/store/local_message_store.dart';
import 'package:mugam_flutter/firebase/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Граница урезания памяти чата (B10) проверяется здесь, а НЕ на устройстве:
// урезание невидимо снаружи по построению — ушедший с экрана чат при
// возврате мгновенно добирает хвост из кэша Firestore, поэтому глазами
// нельзя отличить «урезали и добрали» от «не урезали». Тем более нельзя
// увидеть поведение ровно на пороге.
//
// Проверяется на БОЕВОЙ константе (LocalMessageStore.maxMessagesPerChat),
// без временного её понижения: набрать 201 сообщение в памяти теста
// ничего не стоит, а тест, прошедший на подменённом значении, о боевом не
// говорит ничего.

Message _confirmed(String chatId, int seq) {
  return Message(
    id: '$chatId-m$seq',
    chatId: chatId,
    senderId: 'u_other',
    text: 'msg $seq',
    type: 'text',
    seq: seq,
    timestamp: Timestamp.fromDate(DateTime.utc(2026, 1, 1).add(Duration(minutes: seq))),
  );
}

Message _pending(String chatId, String id) {
  return Message(
    id: id,
    chatId: chatId,
    senderId: 'me',
    text: 'не отправлено',
    type: 'text',
    // seq == null — сообщение ещё не подтверждено сервером.
    localSendStatus: 'queued',
  );
}

Future<LocalMessageStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = LocalMessageStore(prefs);
  await store.init();
  return store;
}

// Открытие экрана чата — это и есть сигнал «все прочие чаты сейчас не на
// экране», по которому применяется граница.
Future<List<Message>> _open(LocalMessageStore store, String chatId) {
  return store.watchChat(chatId).first;
}

Future<void> _fill(LocalMessageStore store, String chatId, int count) {
  return store.upsertManyFromFirestore(
    chatId: chatId,
    reals: List.generate(count, (i) => _confirmed(chatId, i + 1)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final limit = LocalMessageStore.maxMessagesPerChat;

  group('граница урезания', () {
    test('на один меньше порога — не урезается', () async {
      final store = await _store();
      await _fill(store, 'A', limit - 1);
      await _open(store, 'A');

      await _open(store, 'B'); // A ушёл с экрана

      expect((await _open(store, 'A')).length, limit - 1);
    });

    test('ровно на пороге — не урезается', () async {
      final store = await _store();
      await _fill(store, 'A', limit);
      await _open(store, 'A');

      await _open(store, 'B');

      expect(
        (await _open(store, 'A')).length,
        limit,
        reason: 'урезание сработало раньше времени, на точном совпадении',
      );
    });

    test('на один больше порога — урезается ровно до порога', () async {
      final store = await _store();
      await _fill(store, 'A', limit + 1);
      await _open(store, 'A');

      await _open(store, 'B');

      final kept = await _open(store, 'A');
      expect(kept.length, limit, reason: 'урезание пропущено или урезало не до порога');
      // Остаться должен ХВОСТ, то есть самые свежие: seq 2..201, а не 1..200.
      expect(kept.first.seq, 2);
      expect(kept.last.seq, limit + 1);
    });
  });

  group('что урезание не должно ломать', () {
    // Порядок здесь принципиален, и первая версия этого теста была
    // сформулирована неверно: она наполняла оба чата ДО открытия первого,
    // и тогда B законно урезался в момент открытия A — он в ту секунду не
    // был на экране. Чат вне экрана может быть урезан при открытии любого
    // другого; проверять надо не это, а что открытие чата не урезает
    // ЕГО САМОГО.
    test('открытие чата не урезает его самого, а ушедший урезает', () async {
      final store = await _store();
      await _fill(store, 'A', limit + 50);
      await _open(store, 'A'); // на экране A
      await _fill(store, 'B', limit + 50); // B наполнился, пока открыт A

      await _open(store, 'B'); // на экране B, A ушёл

      expect(
        (await _open(store, 'B')).length,
        limit + 50,
        reason: 'урезан чат, который сейчас на экране',
      );
      expect(
        (await store.watchChat('A').first).length,
        limit,
        reason: 'ушедший с экрана чат не урезан',
      );
    });

    // Ровно тот сценарий, из-за которого граница НЕ привязана к порядку
    // доступа: фоновая очередь отправки дотрагивается до чужого чата,
    // пока пользователь сидит в своём. По порядку доступа открытый чат
    // стал бы «предыдущим» и был бы урезан прямо под пользователем.
    test('запись в другой чат из фона не урезает открытый', () async {
      final store = await _store();
      await _fill(store, 'A', limit + 50);
      await _open(store, 'A'); // пользователь в A

      await _fill(store, 'B', 3); // фоновая очередь тронула B

      expect((await store.watchChat('A').first).length, limit + 50);
    });

    test('неотправленные сообщения переживают урезание, каким бы старым ни был хвост', () async {
      final store = await _store();
      await store.insertPending(_pending('A', 'A-pending-1'));
      await store.insertPending(_pending('A', 'A-pending-2'));
      await _fill(store, 'A', limit + 20);
      await _open(store, 'A');

      await _open(store, 'B');

      final kept = await _open(store, 'A');
      final pendingIds = kept
          .where((m) => m.localSendStatus != null)
          .map((m) => m.id)
          .toSet();
      expect(
        pendingIds,
        {'A-pending-1', 'A-pending-2'},
        reason: 'урезание съело неотправленное — очередь ретраев читает его отсюда',
      );
      // Очередь ретраев ходит не через watchChat, а напрямую — она тоже
      // обязана их видеть.
      expect(store.allPending().map((m) => m.id).toSet(), pendingIds);
    });

    test('вернувшийся чат отдаёт хвост в правильном порядке, без дублей', () async {
      final store = await _store();
      await _fill(store, 'A', limit + 10);
      await _open(store, 'A');
      await _open(store, 'B');

      final kept = await _open(store, 'A');
      final ids = kept.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'дубли после урезания');
      for (var i = 1; i < kept.length; i++) {
        expect(
          kept[i].seq! > kept[i - 1].seq!,
          isTrue,
          reason: 'порядок по seq нарушен после урезания',
        );
      }
    });

    // Догрузка истории после возврата: страница более старых сообщений
    // приходит из Firestore и должна нормально лечь поверх урезанного
    // хвоста, а не потеряться и не задвоиться.
    test('после урезания старая страница догружается обратно', () async {
      final store = await _store();
      await _fill(store, 'A', limit + 5);
      await _open(store, 'A');
      await _open(store, 'B');
      expect((await _open(store, 'A')).length, limit);

      await store.upsertManyFromFirestore(
        chatId: 'A',
        reals: List.generate(5, (i) => _confirmed('A', i + 1)),
      );

      final restored = await store.watchChat('A').first;
      expect(restored.length, limit + 5);
      expect(restored.first.seq, 1);
    });
  });
}
