import * as fs from "fs";
import * as path from "path";
import {
  initializeTestEnvironment,
  RulesTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { collection, doc, getDoc, getDocs, setDoc, serverTimestamp, Timestamp } from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT, db, waitFor } from "./helpers";

// Reloads the real firestore.rules file content into the already-running
// Firestore emulator (started by `firebase emulators:exec` per
// firebase.json's top-level firestore.rules config) so this suite is
// always validating the exact file on disk, not whatever the emulator
// happened to load at startup.
//
// visibleToUids-based rules rework: access is now gated on a denormalized
// `visibleToUids` array rather than a live exists()-based contacts check
// (see firestore.rules' own comment on why — list/collectionGroup queries
// can't be gated by exists()). These tests seed real contacts docs and
// status docs WITHOUT visibleToUids, then wait for the real onStatusCreated
// trigger to compute it — deliberately NOT hand-seeding visibleToUids
// directly, because onStatusCreated is a real trigger running in this same
// emulator session regardless of withSecurityRulesDisabled, and it would
// silently overwrite any hand-seeded value moments later (it did, before
// this fix — see functions/src/index.ts's onStatusCreated for the
// matching robustness fix this surfaced). The real collectionGroup+
// array-contains access pattern (as opposed to a single getDoc(), used
// throughout below) is covered by status-feed-query.test.ts.
let testEnv: RulesTestEnvironment;

const OWNER = "owner";
const CONTACT = "contactUid"; // a real contact of OWNER, not in any privacyList
const STRANGER = "strangerUid"; // not a contact at all
const EXCEPTED = "exceptedUid"; // a real contact of OWNER, ALSO in a contactsExcept privacyList
const ALLOWED = "allowedUid"; // in an onlyShareWith privacyList, NOT a contact at all

beforeAll(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      host: "localhost",
      port: FIRESTORE_EMULATOR_PORT,
      rules: fs.readFileSync(path.resolve(__dirname, "../../firestore.rules"), "utf8"),
    },
  });
});

afterAll(async () => {
  await testEnv.cleanup();
});

async function visibleToUidsOf(path: string): Promise<string[] | undefined> {
  const snap = await db().doc(path).get();
  return snap.data()?.visibleToUids as string[] | undefined;
}

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const d = context.firestore();

    await setDoc(doc(d, `users/${OWNER}/contacts/${CONTACT}`), { since: new Date() });
    await setDoc(doc(d, `users/${CONTACT}/contacts/${OWNER}`), { since: new Date() });
    await setDoc(doc(d, `users/${OWNER}/contacts/${EXCEPTED}`), { since: new Date() });
    await setDoc(doc(d, `users/${EXCEPTED}/contacts/${OWNER}`), { since: new Date() });
    // STRANGER and ALLOWED deliberately get no contacts doc at all.

    const base = {
      ownerUid: OWNER,
      type: "text",
      text: "hi",
      createdAt: new Date(),
      expiresAt: new Date(Date.now() + 86400000),
    };
    // No visibleToUids here — the real onStatusCreated trigger computes it
    // (waited for below), so these tests validate against what that
    // trigger actually produces, not a hand-typed guess.
    await setDoc(doc(d, `users/${OWNER}/statuses/s-contacts`), {
      ...base, privacyMode: "contacts", privacyList: [],
    });
    await setDoc(doc(d, `users/${OWNER}/statuses/s-contactsExcept`), {
      ...base, privacyMode: "contactsExcept", privacyList: [EXCEPTED],
    });
    await setDoc(doc(d, `users/${OWNER}/statuses/s-onlyShareWith`), {
      ...base, privacyMode: "onlyShareWith", privacyList: [ALLOWED],
    });

    await setDoc(doc(d, `users/${OWNER}/statuses/s-contacts/viewers/${CONTACT}`), {
      viewedAt: new Date(),
    });
    // A second viewer doc, so tests can prove a viewer can read their OWN
    // record but not another viewer's.
    await setDoc(doc(d, `users/${OWNER}/statuses/s-contacts/viewers/${EXCEPTED}`), {
      viewedAt: new Date(),
    });
  });

  await waitFor(async () => (await visibleToUidsOf(`users/${OWNER}/statuses/s-contacts`)) !== undefined);
  await waitFor(
    async () => (await visibleToUidsOf(`users/${OWNER}/statuses/s-contactsExcept`)) !== undefined,
  );
  await waitFor(
    async () => (await visibleToUidsOf(`users/${OWNER}/statuses/s-onlyShareWith`)) !== undefined,
  );
});

test("privacyMode 'contacts': a real contact CAN read", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(getDoc(doc(contactDb, `users/${OWNER}/statuses/s-contacts`)));
});

test("privacyMode 'contacts': a non-contact CANNOT read", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertFails(getDoc(doc(strangerDb, `users/${OWNER}/statuses/s-contacts`)));
});

test("privacyMode 'contactsExcept': a contact NOT in privacyList CAN read", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(getDoc(doc(contactDb, `users/${OWNER}/statuses/s-contactsExcept`)));
});

test("privacyMode 'contactsExcept': a contact WHO IS in privacyList CANNOT read", async () => {
  const exceptedDb = testEnv.authenticatedContext(EXCEPTED).firestore();
  await assertFails(getDoc(doc(exceptedDb, `users/${OWNER}/statuses/s-contactsExcept`)));
});

test("privacyMode 'onlyShareWith': a uid in privacyList CAN read with zero shared chats", async () => {
  const allowedDb = testEnv.authenticatedContext(ALLOWED).firestore();
  await assertSucceeds(getDoc(doc(allowedDb, `users/${OWNER}/statuses/s-onlyShareWith`)));
});

test("privacyMode 'onlyShareWith': a uid NOT in privacyList CANNOT read even if they ARE a contact", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(getDoc(doc(contactDb, `users/${OWNER}/statuses/s-onlyShareWith`)));
});

test("the owner can always read their own status regardless of mode", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(getDoc(doc(ownerDb, `users/${OWNER}/statuses/s-contacts`)));
  await assertSucceeds(getDoc(doc(ownerDb, `users/${OWNER}/statuses/s-contactsExcept`)));
  await assertSucceeds(getDoc(doc(ownerDb, `users/${OWNER}/statuses/s-onlyShareWith`)));
});

test("create: a status WITHOUT a client-supplied visibleToUids succeeds", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(
    setDoc(doc(ownerDb, `users/${OWNER}/statuses/new-status`), {
      ownerUid: OWNER,
      type: "text",
      text: "hey",
      createdAt: serverTimestamp(),
      expiresAt: new Date(Date.now() + 86400000),
      privacyMode: "contacts",
      privacyList: [],
    }),
  );
});

test("create: a status WITH a client-supplied visibleToUids is REJECTED", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    setDoc(doc(ownerDb, `users/${OWNER}/statuses/new-status-2`), {
      ownerUid: OWNER,
      type: "text",
      text: "hey",
      createdAt: serverTimestamp(),
      expiresAt: new Date(Date.now() + 86400000),
      privacyMode: "contacts",
      privacyList: [],
      visibleToUids: [OWNER, STRANGER],
    }),
  );
});

test("viewers subcollection: owner can read a viewer doc", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(getDoc(doc(ownerDb, `users/${OWNER}/statuses/s-contacts/viewers/${CONTACT}`)));
});

// Superseded by the viewer-can-read-their-own-record change below: a viewer
// CAN now get() their own record. A true stranger (neither owner nor that
// specific viewer) still cannot.
test("viewers subcollection: a stranger (neither owner nor that viewer) CANNOT read", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertFails(getDoc(doc(strangerDb, `users/${OWNER}/statuses/s-contacts/viewers/${CONTACT}`)));
});

test("viewers subcollection: a viewer CAN get() their own viewer doc", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(getDoc(doc(contactDb, `users/${OWNER}/statuses/s-contacts/viewers/${CONTACT}`)));
});

// Proves the fix is scoped to "your own record only" — it doesn't
// accidentally open up reading arbitrary viewer docs just because you're
// signed in and a viewer of the same status.
test("viewers subcollection: a viewer CANNOT get() a DIFFERENT viewer's doc", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(getDoc(doc(contactDb, `users/${OWNER}/statuses/s-contacts/viewers/${EXCEPTED}`)));
});

test("viewer write with a client-supplied (non-request.time) viewedAt is REJECTED", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    setDoc(doc(contactDb, `users/${OWNER}/statuses/s-contacts/viewers/${CONTACT}`), {
      viewedAt: Timestamp.fromDate(new Date(2020, 0, 1)),
    }),
  );
});

// Not explicitly requested, but included as a control: proves the
// previous test's rejection is actually about the timestamp value
// specifically, not e.g. a typo elsewhere in the rule blocking all writes.
test("(control) viewer write using serverTimestamp() for viewedAt is ACCEPTED", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(
    setDoc(doc(contactDb, `users/${OWNER}/statuses/s-contacts/viewers/${CONTACT}`), {
      viewedAt: serverTimestamp(),
    }),
  );
});

// contacts list access — needed by the Status creation privacy picker
// (choosing who's in a contactsExcept/onlyShareWith list). This is a real
// list query (getDocs on the whole subcollection), not a single getDoc(),
// same "prove it, don't just test one doc" bar as the feed query tests.
test("contacts list: a user CAN read their own contacts (list query)", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  const snap = await assertSucceeds(getDocs(collection(ownerDb, `users/${OWNER}/contacts`)));
  expect(snap.size).toBe(2); // CONTACT + EXCEPTED, seeded in beforeEach
});

test("contacts list: a user CANNOT read another user's contacts (list query)", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertFails(getDocs(collection(strangerDb, `users/${OWNER}/contacts`)));
});
