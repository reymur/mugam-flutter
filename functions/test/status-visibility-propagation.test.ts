import { getAdminApp, db, clearFirestore, waitFor } from "./helpers";

// Proves the contact-change propagation added to onChatUpdated actually
// runs against a real status's visibleToUids — not just the
// contacts-collection side-effect already covered by
// contacts-triggers.test.ts. Also exercises onStatusCreated's own
// creation-time computation (B ends up in visibleToUids from sharing a
// chat with A, with no explicit seeding).
beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
});

async function getVisibleToUids(statusRef: FirebaseFirestore.DocumentReference): Promise<string[]> {
  const snap = await statusRef.get();
  return (snap.data()?.visibleToUids ?? []) as string[];
}

test("removing B from A's only shared chat removes B from A's active 'contacts'-mode status.visibleToUids", async () => {
  const A = "A";
  const B = "B";

  // A and B share a chat — this is the only chat connecting them.
  const chatRef = db().collection("chats").doc();
  await chatRef.set({ isGroup: false, members: [A, B] });

  await waitFor(async () => {
    const snap = await db().collection("users").doc(A).collection("contacts").doc(B).get();
    return snap.exists;
  });

  // A posts a 'contacts'-mode status with no visibleToUids field —
  // onStatusCreated must compute it from A's current contacts (which
  // includes B at this point).
  const statusRef = db().collection("users").doc(A).collection("statuses").doc();
  await statusRef.set({
    ownerUid: A,
    type: "text",
    text: "hello",
    createdAt: new Date(),
    expiresAt: new Date(Date.now() + 86400000),
    privacyMode: "contacts",
    privacyList: [],
  });

  await waitFor(async () => (await getVisibleToUids(statusRef)).includes(B));
  const afterCreate = await getVisibleToUids(statusRef);
  expect(afterCreate).toContain(A);
  expect(afterCreate).toContain(B);

  // Remove B from the chat — no other chat connects A and B, so this is a
  // genuine contact loss and must propagate into A's still-active status.
  await chatRef.update({ members: [A] });

  await waitFor(async () => !(await getVisibleToUids(statusRef)).includes(B));

  const afterRemoval = await getVisibleToUids(statusRef);
  expect(afterRemoval).not.toContain(B);
  expect(afterRemoval).toContain(A);
});

// Proves onChatCreated's own propagation (not just onChatUpdated's) — a
// brand-new chat can make two users contacts for the very first time, and
// that must reach an already-active status immediately rather than waiting
// for some later membership-change event.
test("A's first-ever chat with B adds B to A's already-active 'contacts'-mode status.visibleToUids", async () => {
  const A = "A";
  const B = "B";

  // A posts a 'contacts'-mode status before A and B have ever shared a
  // chat — A has no contacts at all yet, so onStatusCreated computes
  // visibleToUids as just [A].
  const statusRef = db().collection("users").doc(A).collection("statuses").doc();
  await statusRef.set({
    ownerUid: A,
    type: "text",
    text: "hello",
    createdAt: new Date(),
    expiresAt: new Date(Date.now() + 86400000),
    privacyMode: "contacts",
    privacyList: [],
  });

  await waitFor(async () => (await getVisibleToUids(statusRef)).length > 0);
  const beforeChat = await getVisibleToUids(statusRef);
  expect(beforeChat).toContain(A);
  expect(beforeChat).not.toContain(B);

  // A and B's first-ever shared chat.
  const chatRef = db().collection("chats").doc();
  await chatRef.set({ isGroup: false, members: [A, B] });

  await waitFor(async () => (await getVisibleToUids(statusRef)).includes(B));

  const afterChat = await getVisibleToUids(statusRef);
  expect(afterChat).toContain(A);
  expect(afterChat).toContain(B);
});
