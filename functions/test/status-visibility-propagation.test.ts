import { getAdminApp, db, clearFirestore, waitFor } from "./helpers";

// Proves the friend-change propagation added to onFriendRequestUpdated/
// onFriendRequestDeleted actually runs against a real status's
// visibleToUids. Also exercises onStatusCreated's own creation-time
// computation (B ends up in visibleToUids from being A's friend, with no
// explicit seeding).
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

test("unfriending B removes B from A's active 'contacts'-mode status.visibleToUids", async () => {
  const A = "A";
  const B = "B";

  // A and B become friends via an accepted friend request.
  const requestRef = db().collection("friendRequests").doc();
  await requestRef.set({ fromUid: A, toUid: B, status: "pending" });
  await requestRef.update({ status: "accepted" });

  await waitFor(async () => {
    const snap = await db().collection("users").doc(A).collection("friends").doc(B).get();
    return snap.exists;
  });

  // A posts a 'contacts'-mode status with no visibleToUids field —
  // onStatusCreated must compute it from A's current friends (which
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

  // Unfriend B — deleting the accepted request is a genuine friendship
  // loss and must propagate into A's still-active status.
  await requestRef.delete();

  await waitFor(async () => !(await getVisibleToUids(statusRef)).includes(B));

  const afterRemoval = await getVisibleToUids(statusRef);
  expect(afterRemoval).not.toContain(B);
  expect(afterRemoval).toContain(A);
});

// Proves onFriendRequestUpdated's own propagation — accepting a friend
// request for the very first time must reach an already-active status
// immediately rather than waiting for some later event.
test("A's friend request to B being accepted adds B to A's already-active 'contacts'-mode status.visibleToUids", async () => {
  const A = "A";
  const B = "B";

  // A posts a 'contacts'-mode status before A and B are friends — A has
  // no friends at all yet, so onStatusCreated computes visibleToUids as
  // just [A].
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
  const beforeFriends = await getVisibleToUids(statusRef);
  expect(beforeFriends).toContain(A);
  expect(beforeFriends).not.toContain(B);

  // A and B's friend request gets accepted for the first time.
  const requestRef = db().collection("friendRequests").doc();
  await requestRef.set({ fromUid: A, toUid: B, status: "pending" });
  await requestRef.update({ status: "accepted" });

  await waitFor(async () => (await getVisibleToUids(statusRef)).includes(B));

  const afterAccept = await getVisibleToUids(statusRef);
  expect(afterAccept).toContain(A);
  expect(afterAccept).toContain(B);
});
