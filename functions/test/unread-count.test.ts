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

  await waitFor(async () => {
    const snap = await chatRef.get();
    return (snap.data()?.unreadCount ?? {}).C === 1;
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
