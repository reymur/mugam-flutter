import { getStorage } from "firebase-admin/storage";
import type { CallableRequest } from "firebase-functions/v2/https";
import { copyStatusMediaToChat } from "../src/index";
import { getAdminApp, db, clearFirestore, waitFor, BUCKET } from "./helpers";

// First test in this suite to import and directly invoke an onCall
// function (every other Cloud Function here is a trigger, exercised
// indirectly by writing to Firestore/Storage and waiting for the side
// effect) — firebase-functions v2's own CallableFunction.run(request) is
// the documented direct-invocation entry point for exactly this, so no
// new test dependency (e.g. firebase-functions-test) is needed. `as any`
// on the constructed request objects below sidesteps CallableRequest's
// full shape (rawRequest and friends, meaningless outside a real HTTPS
// call) — only `data`/`auth` are ever read by copyStatusMediaToChat's own
// body.
beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
});

function req(uid: string | undefined, data: Record<string, unknown>): CallableRequest {
  return { data, auth: uid ? { uid, token: {} } : undefined } as unknown as CallableRequest;
}

async function makeChat(chatId: string, members: string[]): Promise<void> {
  await db().collection("chats").doc(chatId).set({ isGroup: false, members });
}

async function makeImageStatus(opts: {
  ownerUid: string;
  statusId: string;
  visibleToUids?: string[];
  isPublic?: boolean;
  privacyList?: string[];
  fileBytes?: string;
}): Promise<{ statusId: string; storagePath: string }> {
  // Unique suffix regardless of the caller's own statusId — Storage
  // (unlike Firestore) is never cleared between tests here, so two tests
  // both passing statusId: "s1" would otherwise silently share/overwrite
  // the same object.
  const fileName = `${opts.statusId}_${Date.now()}_${Math.random().toString(36).slice(2)}.jpg`;
  const storagePath = `statuses/${opts.ownerUid}/${fileName}`;
  const file = getStorage(getAdminApp()).bucket(BUCKET).file(storagePath);
  await file.save(Buffer.from(opts.fileBytes ?? "fake image bytes"), {
    contentType: "image/jpeg",
  });
  // Verify visibility using the EXACT same bucket-resolution style the
  // production function itself uses (bare getStorage(), explicit bucket
  // name, no app argument) — if this ever disagrees with the app-scoped
  // getStorage(getAdminApp()) call just used to write it, that mismatch
  // needs to surface right here, not as a confusing downstream failure
  // inside the function being tested.
  const [existsViaProdStyleBucket] = await getStorage()
    .bucket("mugam-club.firebasestorage.app")
    .file(storagePath)
    .exists();
  if (!existsViaProdStyleBucket) {
    throw new Error(
      `makeImageStatus: saved object not visible via getStorage().bucket("mugam-club.firebasestorage.app") immediately after save — storagePath=${storagePath}`,
    );
  }
  const mediaUrl =
    `https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o/` +
    `${encodeURIComponent(storagePath)}?alt=media`;

  await db()
    .collection("users")
    .doc(opts.ownerUid)
    .collection("statuses")
    .doc(opts.statusId)
    .set({
      ownerUid: opts.ownerUid,
      type: "image",
      mediaUrl,
      createdAt: new Date(),
      expiresAt: new Date(Date.now() + 86400000),
      privacyMode: "contacts",
      privacyList: opts.privacyList ?? [],
      visibleToUids: opts.visibleToUids ?? [opts.ownerUid],
      isPublic: opts.isPublic ?? false,
    });

  return { statusId: opts.statusId, storagePath };
}

test("rejects when unauthenticated", async () => {
  await expect(
    copyStatusMediaToChat.run(req(undefined, { statusOwnerUid: "A", statusId: "s1", targetChatId: "c1" })),
  ).rejects.toThrow();
});

test("rejects when caller is not a member of the target chat", async () => {
  await makeChat("c1", ["A", "B"]);
  await makeImageStatus({ ownerUid: "A", statusId: "s1", visibleToUids: ["A", "C"] });

  // C has visibility on the status but isn't in chat c1 — must still be
  // rejected, since the target-chat-membership check is independent of
  // status visibility.
  await expect(
    copyStatusMediaToChat.run(req("C", { statusOwnerUid: "A", statusId: "s1", targetChatId: "c1" })),
  ).rejects.toThrow();
});

test("rejects when the status doesn't exist", async () => {
  await makeChat("c1", ["A", "B"]);
  await expect(
    copyStatusMediaToChat.run(req("B", { statusOwnerUid: "A", statusId: "nope", targetChatId: "c1" })),
  ).rejects.toThrow();
});

test("rejects when caller has no access to a private status (not owner, not in visibleToUids, not public)", async () => {
  await makeChat("c1", ["A", "B"]);
  await makeImageStatus({ ownerUid: "A", statusId: "s1", visibleToUids: ["A"], isPublic: false });

  await expect(
    copyStatusMediaToChat.run(req("B", { statusOwnerUid: "A", statusId: "s1", targetChatId: "c1" })),
  ).rejects.toThrow();
});

test("rejects a text status (no forwardable media)", async () => {
  await makeChat("c1", ["A", "B"]);
  await db().collection("users").doc("A").collection("statuses").doc("s1").set({
    ownerUid: "A",
    type: "text",
    text: "hello",
    createdAt: new Date(),
    expiresAt: new Date(Date.now() + 86400000),
    privacyMode: "contacts",
    privacyList: [],
    visibleToUids: ["A", "B"],
    isPublic: false,
  });

  await expect(
    copyStatusMediaToChat.run(req("B", { statusOwnerUid: "A", statusId: "s1", targetChatId: "c1" })),
  ).rejects.toThrow();
});

test("allows a public status even for a caller not in visibleToUids", async () => {
  await makeChat("c1", ["A", "B"]);
  // B is deliberately NOT in visibleToUids — only isPublic makes this
  // legal, mirroring firestore.rules' own `allow get` exactly.
  await makeImageStatus({
    ownerUid: "A",
    statusId: "s1",
    visibleToUids: ["A"],
    isPublic: true,
    privacyList: [],
  });

  const result = await copyStatusMediaToChat.run(
    req("B", { statusOwnerUid: "A", statusId: "s1", targetChatId: "c1" }),
  );
  expect(result.path).toBe(`chats/c1/${result.fileName}`);
});

test("copies the file, sets chat-scoped metadata, and writes a validatedUploads marker with real contentType/size", async () => {
  await makeChat("c1", ["A", "B"]);
  const { storagePath } = await makeImageStatus({
    ownerUid: "A",
    statusId: "s1",
    visibleToUids: ["A", "B"],
    fileBytes: "some real bytes here",
  });

  const result = await copyStatusMediaToChat.run(
    req("B", { statusOwnerUid: "A", statusId: "s1", targetChatId: "c1" }),
  );

  expect(result.type).toBe("image");
  expect(result.path).toBe(`chats/c1/${result.fileName}`);

  const bucket = getStorage(getAdminApp()).bucket(BUCKET);
  const destFile = bucket.file(result.path as string);
  const [destExists] = await destFile.exists();
  expect(destExists).toBe(true);

  const [destMeta] = await destFile.getMetadata();
  expect(destMeta.metadata?.uploaderUid).toBe("B");
  expect(destMeta.metadata?.chatId).toBe("c1");
  expect(destMeta.contentType).toBe("image/jpeg");

  // Source object must still exist — this is a copy, not a move (unlike
  // copyMediaToStatus which also never deletes its own source).
  const [sourceStillExists] = await bucket.file(storagePath).exists();
  expect(sourceStillExists).toBe(true);

  await waitFor(async () => {
    const snap = await db()
      .collection("validatedUploads")
      .doc("c1")
      .collection("files")
      .doc(result.fileName as string)
      .get();
    return snap.exists;
  });

  const markerSnap = await db()
    .collection("validatedUploads")
    .doc("c1")
    .collection("files")
    .doc(result.fileName as string)
    .get();
  const marker = markerSnap.data()!;
  expect(marker.uploaderUid).toBe("B");
  expect(marker.contentType).toBe("image/jpeg");
  expect(typeof marker.size).toBe("number");
  expect(marker.size).toBeGreaterThan(0);
});
