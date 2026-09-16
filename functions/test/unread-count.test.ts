import { FieldValue } from "firebase-admin/firestore";
import { getAdminApp, db, clearFirestore, waitFor } from "./helpers";

// Covers the unreadCount fix: onNewMessage's per-uid increment (server-side,
// functions/src/index.ts) and the Firestore update shape markChatAsReadBy
// (lib/firebase/firestore_service.dart) relies on to zero it back. See that
// commit's own reasoning for why onMessageDeleted deliberately does NOT
// touch unreadCount — nothing to cover here since it's an intentional no-op.
//
// Chat.fromFirestore's read-side fix (picking data['unreadCount'][uid]
// instead of summing every entry in the map) is pure Dart parsing logic
// with no Firestore trigger involved, so it's outside what this Jest/
// emulator suite can exercise — this suite only proves what actually ends
// up written in Firestore, not how the Flutter client reads it back out.
// This project also has no real Dart unit tests yet (test/widget_test.dart
// is a single literal placeholder, `expect(1 + 1, 2)`), so covering it
// would mean introducing this codebase's first real Dart test rather than
// extending an existing practice — left for a separate, explicit decision
// rather than folded into this Jest-scoped task.
beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
});

test("onNewMessage increments unreadCount.$uid for every member except the sender", async () => {
  const A = "A";
  const B = "B";
  const C = "C";

  const chatRef = db().collection("chats").doc();
  await chatRef.set({
    isGroup: true,
    members: [A, B, C],
    // B already has an unread backlog from an earlier message; C has no
    // key yet at all — proves the increment both adds onto an existing
    // count and creates a fresh one from nothing in the same write.
    unreadCount: { B: 2 },
  });

  await chatRef.collection("messages").add({
    senderId: A,
    text: "hello",
    type: "text",
    timestamp: new Date(),
  });

  // ЖДЁМ ВСЕ ТРИ УСЛОВИЯ, А НЕ ОДНО (16.09). Здесь стояло `C === 1`, а
  // утверждались ниже ещё B и отсутствие A: ожидание не пинило того, что
  // проверяется. Все три поля пишутся одной правкой, но повторная доставка
  // события сделала бы B=4 и C=2 — и второе чтение увидело бы это уже
  // после того, как первое застало нужное мгновение.
  //
  // ПРАВКА ОБОСНОВАНА ЧТЕНИЕМ КОДА, А НЕ ВОСПРОИЗВЕДЁННЫМ ОТКАЗОМ: этот
  // вердикт 16.09 не падал ни разу. **N77 ею не закрывается.**
  await waitFor(async () => {
    const u = (await chatRef.get()).data()?.unreadCount ?? {};
    return u.C === 1 && u.B === 3 && u.A === undefined;
  });

  const after = (await chatRef.get()).data()?.unreadCount ?? {};
  expect(after.B).toBe(3);
  expect(after.C).toBe(1);
  expect(after.A).toBeUndefined();
});

test("onNewMessage leaves unreadCount untouched for a chat with no other members", async () => {
  const A = "A";

  const chatRef = db().collection("chats").doc();
  await chatRef.set({
    isGroup: false,
    members: [A],
    unreadCount: {},
  });

  await chatRef.collection("messages").add({
    senderId: A,
    text: "hello",
    type: "text",
    timestamp: new Date(),
  });

  // No other member to increment for, and no waitFor-able side effect to
  // poll on this path — messageCount's own increment (unconditional,
  // unrelated to member count) is the signal that onNewMessage actually
  // ran to completion for this message before asserting unreadCount.
  await waitFor(async () => {
    const snap = await chatRef.get();
    return (snap.data()?.messageCount ?? 0) === 1;
  });

  // ЧЕГО ЭТОТ ВЕРДИКТ НЕ ДОКАЗЫВАЕТ — ДОЛГ N239 (16.09).
  //
  // `messageCount === 1` доказывает, что `onNewMessage` отработал на этом
  // сообщении, и это сильнее таймера. Но `toEqual({})` — утверждение об
  // ОТСУТСТВИИ, растянутое во времени: повторная доставка того же события
  // после нашего чтения завела бы ключ, и вердикт этого не увидел бы.
  // Сузить ожидание, как сделано в вердикте выше, здесь нельзя: пустой
  // `unreadCount` истинен и ДО того, как триггер отработал.
  //
  // ЧТО НУЖНО, ЧТОБЫ ДОКАЗЫВАЛ: отметка «обработчик отработал и решил не
  // трогать `unreadCount`», которую сервер кладёт всегда. Это правка в
  // `functions/src`, а не здесь.
  //
  // Вердикт 16.09 не падал ни разу; записано по чтению кода, а не по
  // воспроизведённому отказу. **N77 этим не закрывается.**
  const after = (await chatRef.get()).data()?.unreadCount ?? {};
  expect(after).toEqual({});
});

// Exercises the exact Firestore update shape markChatAsReadBy performs
// client-side when a user opens a chat (this suite can't invoke Dart
// directly — see the file-level comment above) — proves the dot-notation
// targeted map-key update it relies on only clobbers that one key, leaving
// every other member's own unread count and the rest of the doc untouched.
test("resetting unreadCount.$uid to 0 via markChatAsReadBy's update shape zeroes only the caller's own count", async () => {
  const A = "A";
  const B = "B";

  const chatRef = db().collection("chats").doc();
  await chatRef.set({
    isGroup: false,
    members: [A, B],
    unreadCount: { A: 4, B: 7 },
  });

  await chatRef.update({
    readBy: FieldValue.arrayUnion(A),
    "lastReadAt.A": new Date().toISOString(),
    "lastReadMsgId.A": "msg123",
    "unreadCount.A": 0,
  });

  const after = (await chatRef.get()).data();
  expect(after?.unreadCount.A).toBe(0);
  expect(after?.unreadCount.B).toBe(7);
  expect(after?.readBy).toEqual([A]);
  expect(after?.lastReadMsgId.A).toBe("msg123");
});
