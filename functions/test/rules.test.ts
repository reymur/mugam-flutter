import * as fs from "fs";
import * as path from "path";
import {
  initializeTestEnvironment,
  RulesTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, serverTimestamp, Timestamp } from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// First rules test in this repo — no prior pattern to match. Reloads the
// real firestore.rules file content into the already-running Firestore
// emulator (started by `firebase emulators:exec` per firebase.json's
// top-level firestore.rules config) so this suite is always validating
// the exact file on disk, not whatever the emulator happened to load at
// startup.
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
  });
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

test("viewers subcollection: owner can read a viewer doc", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(getDoc(doc(ownerDb, `users/${OWNER}/statuses/s-contacts/viewers/${CONTACT}`)));
});

test("viewers subcollection: a non-owner (even the viewer themselves) CANNOT read", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(getDoc(doc(contactDb, `users/${OWNER}/statuses/s-contacts/viewers/${CONTACT}`)));
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
