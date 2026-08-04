import * as fs from "fs";
import * as path from "path";
import {
  initializeTestEnvironment,
  RulesTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import {
  collection,
  collectionGroup,
  query,
  where,
  doc,
  setDoc,
  getDocs,
  Timestamp,
} from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// Firestore only authorizes a list()/collectionGroup() query when the
// query's OWN filters alone can prove the security rule for every possible
// result — it never consults document content to decide. Every query shape
// here is copied one-for-one from lib/firebase/firestore_service.dart's
// real .where() call sites (see that file's own comments on each — several
// were themselves written after a permission-denied caught this exact gap
// in production, e.g. watchStatusFeed/agreementExistsForRound). Changing a
// query's filters, or a rule's condition, without re-running this file can
// silently reintroduce the same gap — see docs/handoff.md §0.
//
// Each proving-filter case is paired with a same-shape query that OMITS the
// filter the rule depends on, asserted to fail — without that pair, a test
// that only ever calls assertSucceeds can't tell "the rule was checked and
// passed" apart from "the rule was never exercised at all."
//
// The one exception is the isChatMember()-gated messages subcollection,
// where the rule is proved via a get() on the parent chat doc (path-based,
// not filter-based) — there the meaningful negative is a non-member, not a
// stripped filter.
let testEnv: RulesTestEnvironment;

const OWNER = "owner";
const PARTNER = "partner"; // real chat member / event participant / friend-request counterpart
const STRANGER = "stranger"; // in none of the seeded docs

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

    await setDoc(doc(d, "chats/chat1"), {
      members: [OWNER, PARTNER],
      activeUsers: [OWNER],
      isGroup: false,
    });
    await setDoc(doc(d, "chats/chat1/messages/msg-image"), {
      type: "image",
      senderId: OWNER,
      deletedForAll: false,
      seq: 1,
    });
    await setDoc(doc(d, "chats/chat1/messages/msg-text"), {
      type: "text",
      senderId: OWNER,
      seq: 2,
    });

    await setDoc(doc(d, "calls/call1"), {
      callerId: PARTNER,
      calleeId: OWNER,
      status: "ringing",
    });

    await setDoc(doc(d, "personalEvents/ev1"), {
      ownerUid: OWNER,
      musicians: [OWNER, PARTNER],
      status: "agreed",
    });

    await setDoc(doc(d, "friendRequests/fr-incoming"), {
      fromUid: PARTNER,
      toUid: OWNER,
      status: "pending",
    });
    await setDoc(doc(d, "friendRequests/fr-outgoing"), {
      fromUid: OWNER,
      toUid: PARTNER,
      status: "pending",
    });
  });
});

// --- chats: watchChats / getOrCreateDirectChat's legacy lookup ---
// firestore_service.dart:273/826 — .where('members', arrayContains: uid)

test("chats: members array-contains uid — a real member's query succeeds", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  const snap = await assertSucceeds(
    getDocs(query(collection(ownerDb, "chats"), where("members", "array-contains", OWNER))),
  );
  expect(snap.docs.map((d) => d.id)).toEqual(["chat1"]);
});

test("chats: the same query WITHOUT the members filter fails — proves the filter, not just auth, is doing the work", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(getDocs(collection(ownerDb, "chats")));
});

// --- chats: clearActiveUserFromAllChats (firestore_service.dart:2945) ---
// .where('activeUsers', arrayContains: uid).
//
// ЭТИ ДВА ТЕСТА ЗАПИСЫВАЮТ ДЕЙСТВУЮЩИЙ ДЕФЕКТ (N32), А НЕ ЖЕЛАЕМОЕ
// ПОВЕДЕНИЕ. Правило чтения chats/{chatId} доказывается полем `members`,
// а фильтр здесь — по `activeUsers`, поэтому сервер отказывает по правам
// на КАЖДОМ вызове. Отказ уходит в тихий catch, и уборка activeUsers на
// логауте не срабатывала ни разу (разбор — AUDIT_TODO.md, класс
// «перехват без последствий делает поломку невидимой»).
//
// Когда дефект починят, ПЕРВЫЙ тест обязан быть перевёрнут в
// assertSucceeds — он для того и оставлен красным по смыслу, чтобы
// починку нельзя было счесть законченной, не тронув его. ВТОРОЙ тест
// (чужой uid) переворачивать нельзя ни при какой починке.
//
// Осторожно с выбором починки: дизъюнкт `uid in activeUsers` в правиле
// чтения этот тест зазеленит, но откроет чтение чата тому, кто из группы
// ВЫШЕЛ и застрял в activeUsers (leaveGroup чистит только members/admins)
// — проверено опытом на двух наборах правил 04.08. Второй тест ниже эту
// утечку НЕ ловит: она в другую сторону.
test("chats: activeUsers array-contains uid — ОТКАЗ по правам, действующий дефект N32", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    getDocs(query(collection(ownerDb, "chats"), where("activeUsers", "array-contains", OWNER))),
  );
});

test("chats: activeUsers array-contains ЧУЖОГО uid — отказ, и должен остаться отказом после любой починки", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertFails(
    getDocs(query(collection(strangerDb, "chats"), where("activeUsers", "array-contains", OWNER))),
  );
});

// --- chats/{chatId}/messages: watchChatMedia (firestore_service.dart:1309) ---
// .where('type', whereIn: ['image', 'video']) — gated via isChatMember(),
// a get() on the parent chat doc, not on the query's own filters.

test("messages: type whereIn [image,video] — a real chat member succeeds", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  const snap = await assertSucceeds(
    getDocs(
      query(collection(ownerDb, "chats/chat1/messages"), where("type", "in", ["image", "video"])),
    ),
  );
  expect(snap.docs.map((d) => d.id)).toEqual(["msg-image"]);
});

test("messages: the same query for a non-member of the chat fails", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertFails(
    getDocs(
      query(
        collection(strangerDb, "chats/chat1/messages"),
        where("type", "in", ["image", "video"]),
      ),
    ),
  );
});

// --- chats/{chatId}/messages: countChatImages (firestore_service.dart:2384-2387) ---

test("messages: type isEqualTo image, plus deletedForAll isEqualTo true — a real chat member succeeds", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(
    getDocs(query(collection(ownerDb, "chats/chat1/messages"), where("type", "==", "image"))),
  );
  await assertSucceeds(
    getDocs(
      query(
        collection(ownerDb, "chats/chat1/messages"),
        where("type", "==", "image"),
        where("deletedForAll", "==", true),
      ),
    ),
  );
});

test("messages: same count-style query for a non-member fails", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertFails(
    getDocs(query(collection(strangerDb, "chats/chat1/messages"), where("type", "==", "image"))),
  );
});

// --- calls: watchIncomingCalls (firestore_service.dart:2533-2534) ---
// .where('calleeId', isEqualTo: uid).where('status', isEqualTo: 'ringing')

test("calls: calleeId isEqualTo uid, status isEqualTo ringing — the callee's query succeeds", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  const snap = await assertSucceeds(
    getDocs(
      query(
        collection(ownerDb, "calls"),
        where("calleeId", "==", OWNER),
        where("status", "==", "ringing"),
      ),
    ),
  );
  expect(snap.docs.map((d) => d.id)).toEqual(["call1"]);
});

test("calls: the same collection with no filter at all fails", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(getDocs(collection(ownerDb, "calls")));
});

// --- personalEvents: watchPersonalEvents (firestore_service.dart:3469) ---
// .where('ownerUid', isEqualTo: uid)

test("personalEvents: ownerUid isEqualTo uid — the owner's query succeeds", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  const snap = await assertSucceeds(
    getDocs(query(collection(ownerDb, "personalEvents"), where("ownerUid", "==", OWNER))),
  );
  expect(snap.docs.map((d) => d.id)).toEqual(["ev1"]);
});

test("personalEvents: the same collection with no filter fails", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(getDocs(collection(ownerDb, "personalEvents")));
});

// --- personalEvents: watchEventsAsParticipant / agreementExistsForRound ---
// (firestore_service.dart:3488, 3584) — .where('musicians', arrayContains: uid)

test("personalEvents: musicians array-contains uid — a participant's query succeeds", async () => {
  const partnerDb = testEnv.authenticatedContext(PARTNER).firestore();
  const snap = await assertSucceeds(
    getDocs(query(collection(partnerDb, "personalEvents"), where("musicians", "array-contains", PARTNER))),
  );
  expect(snap.docs.map((d) => d.id)).toEqual(["ev1"]);
});

test("personalEvents: the same query, but for a stranger's own uid, comes back empty rather than failing", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  const snap = await assertSucceeds(
    getDocs(
      query(collection(strangerDb, "personalEvents"), where("musicians", "array-contains", STRANGER)),
    ),
  );
  expect(snap.size).toBe(0);
});

// --- friendRequests: watchIncomingFriendRequests (firestore_service.dart:3708-3709) ---
// .where('toUid', isEqualTo: uid).where('status', isEqualTo: 'pending')

test("friendRequests: toUid isEqualTo uid, status pending — the recipient's query succeeds", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  const snap = await assertSucceeds(
    getDocs(
      query(
        collection(ownerDb, "friendRequests"),
        where("toUid", "==", OWNER),
        where("status", "==", "pending"),
      ),
    ),
  );
  expect(snap.docs.map((d) => d.id)).toEqual(["fr-incoming"]);
});

test("friendRequests: the same collection with no filter fails", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(getDocs(collection(ownerDb, "friendRequests")));
});

// --- friendRequests: watchOutgoingFriendRequests (firestore_service.dart:3721-3722) ---
// .where('fromUid', isEqualTo: uid).where('status', isEqualTo: 'pending')

test("friendRequests: fromUid isEqualTo uid, status pending — the sender's query succeeds", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  const snap = await assertSucceeds(
    getDocs(
      query(
        collection(ownerDb, "friendRequests"),
        where("fromUid", "==", OWNER),
        where("status", "==", "pending"),
      ),
    ),
  );
  expect(snap.docs.map((d) => d.id)).toEqual(["fr-outgoing"]);
});

// --- collectionGroup('statuses'), visibleToUids + expiresAt ---
// (firestore_service.dart:383-385) — the exact production filter shape,
// including the extra expiresAt >= filter watchStatusFeed adds, which
// status-feed-query.test.ts/rules.test.ts don't exercise (they filter on
// visibleToUids alone). Kept minimal here since those two files already
// cover the visibleToUids rule itself in depth.

test("statuses collectionGroup: visibleToUids array-contains + expiresAt filter — proving query succeeds", async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `users/${OWNER}/statuses/st1`), {
      ownerUid: OWNER,
      visibleToUids: [OWNER],
      expiresAt: Timestamp.fromMillis(Date.now() + 86400000),
    });
  });
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  const snap = await assertSucceeds(
    getDocs(
      query(
        collectionGroup(ownerDb, "statuses"),
        where("visibleToUids", "array-contains", OWNER),
        where("expiresAt", ">", Timestamp.now()),
      ),
    ),
  );
  expect(snap.docs.map((d) => d.id)).toEqual(["st1"]);
});

test("statuses collectionGroup: same collectionGroup with no filter at all fails", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(getDocs(collectionGroup(ownerDb, "statuses")));
});
