import { getStorage } from "firebase-admin/storage";
import { getAdminApp, db, clearFirestore, waitFor, BUCKET } from "./helpers";

beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
});

// 6. onStatusDeleted — viewers cascade with chunking exercised.
// 5 viewer docs is enough to prove the chunking loop's slice() logic
// works at all (a single un-chunked batch would also pass at this size,
// but a broken slice/index bug would fail immediately). The literal
// 500-op batch boundary is verified by code review of the chunking loop
// itself (functions/src/index.ts), not by creating 500+ live documents
// in this suite.
test("onStatusDeleted deletes every doc in the viewers subcollection", async () => {
  const ownerUid = "A";
  const statusRef = db().collection("users").doc(ownerUid).collection("statuses").doc();
  await statusRef.set({
    ownerUid,
    type: "text",
    text: "hello",
    createdAt: new Date(),
    expiresAt: new Date(Date.now() + 86400000),
    privacyMode: "contacts",
    privacyList: [],
  });

  const viewerUids = ["v1", "v2", "v3", "v4", "v5"];
  await Promise.all(
    viewerUids.map((uid) => statusRef.collection("viewers").doc(uid).set({ viewedAt: new Date() })),
  );

  // Prove the docs really were there before deletion, so the later
  // "empty" assertion demonstrates the cascade ran rather than the
  // subcollection having been empty all along.
  const beforeSnap = await statusRef.collection("viewers").get();
  expect(beforeSnap.size).toBe(5);

  await statusRef.delete();

  await waitFor(async () => (await statusRef.collection("viewers").get()).empty);

  const afterSnap = await statusRef.collection("viewers").get();
  expect(afterSnap.empty).toBe(true);
});

// 7a. onStatusDeleted — media file cleanup for an image status
test("onStatusDeleted deletes the Storage object for an image status", async () => {
  const ownerUid = "A";
  const fileName = "test-image.jpg";
  const storagePath = `statuses/${ownerUid}/${fileName}`;
  const file = getStorage(getAdminApp()).bucket(BUCKET).file(storagePath);
  await file.save(Buffer.from("fake image bytes"), { contentType: "image/jpeg" });

  const [existsBefore] = await file.exists();
  expect(existsBefore).toBe(true);

  const mediaUrl =
    `https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o/` +
    `${encodeURIComponent(storagePath)}?alt=media`;

  const statusRef = db().collection("users").doc(ownerUid).collection("statuses").doc();
  await statusRef.set({
    ownerUid,
    type: "image",
    mediaUrl,
    createdAt: new Date(),
    expiresAt: new Date(Date.now() + 86400000),
    privacyMode: "contacts",
    privacyList: [],
  });

  await statusRef.delete();

  await waitFor(async () => {
    const [exists] = await file.exists();
    return !exists;
  });

  const [existsAfter] = await file.exists();
  expect(existsAfter).toBe(false);
});

// 7b. onStatusDeleted — text status, no media to touch
test("onStatusDeleted completes cleanly for a text status (mediaUrl null, no Storage attempt)", async () => {
  const ownerUid = "A";
  const statusRef = db().collection("users").doc(ownerUid).collection("statuses").doc();
  await statusRef.set({
    ownerUid,
    type: "text",
    text: "no media here",
    mediaUrl: null,
    createdAt: new Date(),
    expiresAt: new Date(Date.now() + 86400000),
    privacyMode: "contacts",
    privacyList: [],
  });
  await statusRef.collection("viewers").doc("v1").set({ viewedAt: new Date() });

  await statusRef.delete();

  // "No attempt to touch Storage" is enforced structurally in the source
  // by the `status.type === "image" || status.type === "video"` guard
  // (see onStatusDeleted) — there is no Storage-side signal a text status
  // could leave behind to assert against directly, since it's a straight
  // no-op branch. What this test CAN observe end-to-end is that the
  // handler still runs its other step (viewers cleanup) to completion for
  // a text status, i.e. it doesn't throw/hang before finishing.
  await waitFor(async () => (await statusRef.collection("viewers").get()).empty);

  const viewersSnap = await statusRef.collection("viewers").get();
  expect(viewersSnap.empty).toBe(true);
});
