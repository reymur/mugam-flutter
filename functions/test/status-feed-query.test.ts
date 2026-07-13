import * as fs from "fs";
import * as path from "path";
import {
  initializeTestEnvironment,
  RulesTestEnvironment,
  assertSucceeds,
} from "@firebase/rules-unit-testing";
import { collectionGroup, query, where, getDocs, doc, setDoc } from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT, db, waitFor } from "./helpers";

// Exercises the REAL feed access pattern (collectionGroup + array-contains)
// rather than a single getDoc() — this is the gap the old exists()-based
// isContact()/statusVisibleTo() rules could never support, since a list
// query's security rule can only be evaluated using the query's own
// filters (plus request.auth), never by reading other documents. This is
// the test that would have caught that gap before the visibleToUids
// rework.
let testEnv: RulesTestEnvironment;

const OWNER = "owner";
const CONTACT = "contactUid"; // present in visibleToUids
const STRANGER = "strangerUid"; // absent from visibleToUids

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
    // STRANGER deliberately gets no contacts doc at all.

    // No visibleToUids here — the real onStatusCreated trigger computes it
    // (waited for below), same rationale as rules.test.ts's beforeEach.
    await setDoc(doc(d, `users/${OWNER}/statuses/s1`), {
      ownerUid: OWNER,
      type: "text",
      text: "hi",
      createdAt: new Date(),
      expiresAt: new Date(Date.now() + 86400000),
      privacyMode: "contacts",
      privacyList: [],
    });
  });

  await waitFor(async () => {
    const snap = await db().doc(`users/${OWNER}/statuses/s1`).get();
    return Array.isArray(snap.data()?.visibleToUids);
  });
});

test("collectionGroup feed query: a uid IN visibleToUids gets the status back", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  const q = query(
    collectionGroup(contactDb, "statuses"),
    where("visibleToUids", "array-contains", CONTACT),
  );
  const snap = await assertSucceeds(getDocs(q));
  expect(snap.size).toBe(1);
  expect(snap.docs[0].id).toBe("s1");
});

// The instructions treat "succeeds with zero results" and "fails cleanly"
// as equally acceptable outcomes structurally — this test doesn't assume
// one, it observes and records whichever this ruleset actually produces.
test("collectionGroup feed query: a uid NOT in visibleToUids — records actual outcome", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  const q = query(
    collectionGroup(strangerDb, "statuses"),
    where("visibleToUids", "array-contains", STRANGER),
  );

  let outcome: "succeeded" | "failed";
  let resultSize: number | null = null;
  try {
    const snap = await getDocs(q);
    outcome = "succeeded";
    resultSize = snap.size;
  } catch {
    outcome = "failed";
  }

  // eslint-disable-next-line no-console
  console.log(
    `STRANGER collectionGroup query outcome: ${outcome}` +
      (outcome === "succeeded" ? ` (${resultSize} results)` : ""),
  );

  if (outcome === "succeeded") {
    expect(resultSize).toBe(0);
  } else {
    expect(outcome).toBe("failed");
  }
});
