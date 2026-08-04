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
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
  serverTimestamp,
  deleteDoc,
  Timestamp,
} from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT, db, waitFor } from "./helpers";

// Reloads the real firestore.rules file content into the already-running
// Firestore emulator (started by `firebase emulators:exec` per
// firebase.json's top-level firestore.rules config) so this suite is
// always validating the exact file on disk, not whatever the emulator
// happened to load at startup.
//
// visibleToUids-based rules rework: access is now gated on a denormalized
// `visibleToUids` array rather than a live exists()-based friends check
// (see firestore.rules' own comment on why — list/collectionGroup queries
// can't be gated by exists()). These tests seed real friends docs and
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
const CONTACT = "contactUid"; // a real friend of OWNER, not in any privacyList
const STRANGER = "strangerUid"; // not a friend at all
const EXCEPTED = "exceptedUid"; // a real friend of OWNER, ALSO in a contactsExcept privacyList
const ALLOWED = "allowedUid"; // in an onlyShareWith privacyList, NOT a friend at all
const EVENT = "ev-cancel"; // договор OWNER↔CONTACT для проверок отмены по согласию
const CHAT = "chat-n37"; // чат OWNER↔CONTACT для проверок «кто это сделал»

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

    await setDoc(doc(d, `users/${OWNER}/friends/${CONTACT}`), { since: new Date() });
    await setDoc(doc(d, `users/${CONTACT}/friends/${OWNER}`), { since: new Date() });
    await setDoc(doc(d, `users/${OWNER}/friends/${EXCEPTED}`), { since: new Date() });
    await setDoc(doc(d, `users/${EXCEPTED}/friends/${OWNER}`), { since: new Date() });
    // STRANGER and ALLOWED deliberately get no friends doc at all.

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

    // Чат OWNER↔CONTACT для проверок N37: три поля «кто это сделал»
    // стоят заполненными, чтобы проверялось не только их появление, но и
    // ПЕРЕПИСЫВАНИЕ чужого имени поверх стоящего.
    await setDoc(doc(d, `chats/${CHAT}`), {
      members: [OWNER, CONTACT],
      isGroup: false,
      lastMessage: "salam",
      jobOfferBy: OWNER,
      jobOfferAt: new Date().toISOString(),
      eventDate: "2026-09-01T19:00:00.000",
      eventType: "Toy",
      cancelledBy: null,
      roundEndedBy: null,
      roundStep: "dated",
    });

    // Договор для проверок отмены по согласию: владелец OWNER, вторая
    // сторона CONTACT, обе в musicians (именно это поле читает правило).
    await setDoc(doc(d, `personalEvents/${EVENT}`), {
      ownerUid: OWNER,
      musicians: [OWNER, CONTACT],
      partnerUid: CONTACT,
      date: "2026-09-01T19:00:00.000",
      type: "Toy",
      location: "",
      notes: "",
      isAgree: true,
      status: "agreed",
      cancelRequestedBy: null,
      cancelRequestedAt: null,
      cancelConfirmedBy: null,
      cancelledAt: null,
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

  // Три ожидания СРАЗУ, а не по очереди (N18). Они независимы, а порознь
  // складывались — и складывались именно здесь: это единственный набор с
  // тремя ожиданиями триггера в одном beforeEach, поэтому флаковал он, а не
  // кто-то случайный. При измеренном потолке одного ожидания 6.2 с три
  // подряд дают до ~18.6 с и упираются в потолок хука jest (20 с).
  // Параллельно сумма превращается в максимум.
  await Promise.all(
    ["s-contacts", "s-contactsExcept", "s-onlyShareWith"].map((id) =>
      waitFor(async () => (await visibleToUidsOf(`users/${OWNER}/statuses/${id}`)) !== undefined),
    ),
  );
});

test("privacyMode 'contacts': a real contact CAN read", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(getDoc(doc(contactDb, `users/${OWNER}/statuses/s-contacts`)));
});

// 'contacts' is the public default (soon-to-be-relabeled "Hamı") — the
// get/list split's whole point. onStatusCreated now writes isPublic: true
// for this mode (functions/src/index.ts), so a direct getDoc() is
// authorized for anyone signed in, not just friends. This deliberately
// replaces the old "a non-contact CANNOT read" test, which asserted the
// pre-split behavior this change intentionally overturns for get().
test("privacyMode 'contacts' (Hamı/public default): a stranger (non-friend) CAN get() the status directly", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertSucceeds(getDoc(doc(strangerDb, `users/${OWNER}/statuses/s-contacts`)));
});

// Proves the get/list split actually behaves differently for the exact
// same status doc — the test above shows a stranger CAN get() it directly,
// this shows they still can't see it via the friends-scoped collectionGroup
// feed query, since `allow list` still only checks visibleToUids
// (unchanged, deliberately not isPublic-aware). Same "succeeds-empty or
// fails-cleanly are both acceptable" pattern as
// status-feed-query.test.ts's own STRANGER test, since this rule shape can
// legitimately produce either outcome for a query with zero matches.
test("privacyMode 'contacts' (Hamı/public default): a stranger (non-friend) does NOT see it via the collectionGroup feed query", async () => {
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

  if (outcome === "succeeded") {
    expect(resultSize).toBe(0);
  } else {
    expect(outcome).toBe("failed");
  }
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

// friends list access — needed by the Status creation privacy picker
// (choosing who's in a contactsExcept/onlyShareWith list). This is a real
// list query (getDocs on the whole subcollection), not a single getDoc(),
// same "prove it, don't just test one doc" bar as the feed query tests.
test("friends list: a user CAN read their own friends (list query)", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  const snap = await assertSucceeds(getDocs(collection(ownerDb, `users/${OWNER}/friends`)));
  expect(snap.size).toBe(2); // CONTACT + EXCEPTED, seeded in beforeEach
});

test("friends list: a user CANNOT read another user's friends (list query)", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertFails(getDocs(collection(strangerDb, `users/${OWNER}/friends`)));
});

// ---------------------------------------------------------------------
// personalEvents — отмена договора по согласию
//
// Проверяется не только разрешённое, но и запрещённое, и запрещённого
// здесь больше: правило существует РАДИ отказов. Разрешающая половина
// доказывает лишь, что сценарий вообще работает; смысл «по согласию»
// держится на том, что одна сторона не может пройти обе ступени сама.
// ---------------------------------------------------------------------

// Ставит чужой запрос на отмену в обход правил — исходное состояние для
// проверок подтверждения.
async function seedCancelRequest(by: string) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), `personalEvents/${EVENT}`), {
      cancelRequestedBy: by,
      cancelRequestedAt: new Date(),
    });
  });
}

// Все четыре хода отмены называют автора и поступок. Имя нужно не для
// порядка: текст уведомления берёт автора из `lastActionBy`, и без него
// «{Ad} müqavilənin ləğvini təklif etdi» назвало бы владельца вместо
// просящего.
const request = (uid: string) => ({
  cancelRequestedBy: uid,
  cancelRequestedAt: new Date(),
  lastActionBy: uid,
  lastActionType: "cancelRequested",
});

const confirm = (uid: string) => ({
  status: "cancelled",
  cancelConfirmedBy: uid,
  cancelledAt: new Date(),
  lastActionBy: uid,
  lastActionType: "cancelConfirmed",
});

test("отмена: вторая сторона МОЖЕТ предложить отмену своим uid", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      ...request(CONTACT),
    }),
  );
});

test("отмена: владелец МОЖЕТ предложить отмену своим uid", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), {
      ...request(OWNER),
    }),
  );
});

test("отмена: вторая сторона МОЖЕТ подтвердить запрос владельца", async () => {
  await seedCancelRequest(OWNER);
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), confirm(CONTACT)),
  );
});

test("обычная правка договора владельцем не сломана", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), {
      location: "Bakı",
      notes: "saat 19:00",
    }),
  );
});

test("отмена: НЕЛЬЗЯ выставить cancelRequestedBy чужим uid", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      cancelRequestedBy: OWNER,
      cancelRequestedAt: new Date(),
    }),
  );
});

test("отмена: НЕЛЬЗЯ перевести в cancelled без стоящего запроса", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      status: "cancelled",
      cancelConfirmedBy: CONTACT,
      cancelledAt: new Date(),
    }),
  );
});

test("отмена: НЕЛЬЗЯ подтвердить собственный запрос", async () => {
  await seedCancelRequest(CONTACT);
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      status: "cancelled",
      cancelConfirmedBy: CONTACT,
      cancelledAt: new Date(),
    }),
  );
});

test("отмена: владелец НЕ может подтвердить собственный запрос", async () => {
  await seedCancelRequest(OWNER);
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), {
      status: "cancelled",
      cancelConfirmedBy: OWNER,
      cancelledAt: new Date(),
    }),
  );
});

test("отмена: владелец НЕ может отменить договор обычной правкой", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), { status: "cancelled" }),
  );
});

test("отмена: НЕЛЬЗЯ переписать чужой запрос своим", async () => {
  await seedCancelRequest(OWNER);
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      cancelRequestedBy: CONTACT,
      cancelRequestedAt: new Date(),
    }),
  );
});

test("отмена: запрос БЕЗ имени поступка не проходит", async () => {
  // Без `lastActionType` сервер возьмёт автора из прошлого действия либо
  // из владельца, и текст назовёт не того человека. Имя обязательно у
  // всех четырёх ходов, а не только у снятия.
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      cancelRequestedBy: CONTACT,
      cancelRequestedAt: new Date(),
    }),
  );
});

test("отмена: подтверждение БЕЗ имени поступка не проходит", async () => {
  await seedCancelRequest(OWNER);
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      status: "cancelled",
      cancelConfirmedBy: CONTACT,
      cancelledAt: new Date(),
    }),
  );
});

test("отмена: запрос НЕЛЬЗЯ назвать чужим именем поступка", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      ...request(CONTACT),
      lastActionType: "cancelConfirmed",
    }),
  );
});

test("отмена: владелец НЕ может выдать обычную правку за отмену", async () => {
  // Ветка обычной правки владельца закрыта `namesCancelDeed()` для ВСЕХ
  // четырёх имён. Иначе владелец поставил бы `cancelConfirmed` на пустом
  // ходу, и вторая сторона получила бы «договор отменён» при живом
  // договоре.
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  for (const type of [
    "cancelRequested",
    "cancelConfirmed",
    "cancelWithdrawn",
    "cancelDeclined",
  ]) {
    await assertFails(
      updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), {
        location: "Bakı",
        lastActionBy: OWNER,
        lastActionType: type,
      }),
    );
  }
});

test("отмена: посторонний не может ни предложить, ни подтвердить", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertFails(
    updateDoc(doc(strangerDb, `personalEvents/${EVENT}`), {
      cancelRequestedBy: STRANGER,
      cancelRequestedAt: new Date(),
    }),
  );
  await seedCancelRequest(OWNER);
  await assertFails(
    updateDoc(doc(strangerDb, `personalEvents/${EVENT}`), {
      status: "cancelled",
      cancelConfirmedBy: STRANGER,
      cancelledAt: new Date(),
    }),
  );
});

// ---------------------------------------------------------------------
// chats — «кто это сделал» нельзя написать за другого (N37)
//
// Три поля переговоров заведены ради сервера: по ним он называет автора
// уведомления, по ним же обе стороны читают историю раунда. Проверяется
// каждое ПОРОЗНЬ — общая проверка сказала бы «где-то держится», а нужен
// ответ про каждое поле: они закрываются одним правилом, но забыть его
// можно у любого по отдельности.
// ---------------------------------------------------------------------

const AUTHOR_FIELDS = ["cancelledBy", "roundEndedBy", "jobOfferBy"] as const;

for (const field of AUTHOR_FIELDS) {
  test(`N37: ${field} НЕЛЬЗЯ записать чужим uid`, async () => {
    // STRANGER, а не OWNER: он отличается и от пишущего, и от значения в
    // посеве, поэтому запись — настоящая подмена в любом из трёх полей, а
    // не холостой ход. На OWNER этот же тест у `jobOfferBy` прошёл бы
    // мимо: там OWNER уже стоит, и записать его заново значит не изменить
    // ничего (проверено — первый прогон падал именно так).
    const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
    await assertFails(
      updateDoc(doc(contactDb, `chats/${CHAT}`), { [field]: STRANGER }),
    );
  });

  test(`N37: ${field} МОЖНО записать своим uid`, async () => {
    const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
    await assertSucceeds(
      updateDoc(doc(contactDb, `chats/${CHAT}`), { [field]: CONTACT }),
    );
  });

  test(`N37: ${field} МОЖНО очистить — новый раунд`, async () => {
    // Стирание никого не называет, а `setJobOffer` его делает на каждом
    // новом предложении. Запрети — и предложить работу станет нельзя.
    const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
    await assertSucceeds(
      updateDoc(doc(contactDb, `chats/${CHAT}`), { [field]: null }),
    );
  });
}

test("N37: сам случай из находки — получатель «отменяет» от имени инициатора", async () => {
  // Дословно то, ради чего правило написано: CONTACT закрывает раунд и
  // записывает автором OWNER. Прошло бы — и у OWNER экран сказал бы «вы
  // отказались», у CONTACT «он отказался». Две правды об одном договоре.
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `chats/${CHAT}`), {
      cancelledBy: OWNER,
      roundEndedBy: OWNER,
      roundStep: "ended",
    }),
  );
});

test("N37: свой законный отказ проходит целиком", async () => {
  // Вторая половина: правило обязано пропускать настоящий отказ той
  // формы, какой его пишет cancelChat, — иначе оно чинит подделку ценой
  // самой возможности отказаться.
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(
    updateDoc(doc(contactDb, `chats/${CHAT}`), {
      cancelledBy: CONTACT,
      roundStep: "ended",
      roundEndedBy: CONTACT,
      roundEndedAt: new Date().toISOString(),
      recipientAgreed: false,
    }),
  );
});

test("N37: новое предложение проходит целиком", async () => {
  // Форма setJobOffer: своё имя в jobOfferBy и очистка следов прошлого
  // раунда. Тоже вторая половина — запрети очистку, и предложить работу
  // станет нельзя вовсе.
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(
    updateDoc(doc(contactDb, `chats/${CHAT}`), {
      jobOfferBy: CONTACT,
      jobOfferAt: new Date().toISOString(),
      cancelledBy: null,
      roundEndedBy: null,
      roundStep: "dated",
      recipientAgreed: false,
    }),
  );
});

test("N37: обычная правка соседних полей НЕ сломана", async () => {
  // Осторожность, названная до написания правила: `.update()` по одному
  // ключу приносит остальные поля со старыми значениями, и сравнение
  // ЗНАЧЕНИЙ их пропускает само. Построй правило на changedKeys() — и
  // оно не только сломало бы это, но и дало бы щель на записи тем же
  // значением (запись про changedKeys() в реестре).
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(
    updateDoc(doc(contactDb, `chats/${CHAT}`), {
      lastMessage: "yeni mesaj",
      eventLocation: "Bakı",
    }),
  );
});

test("N37: холостая запись чужого uid тем же значением проходит", async () => {
  // `jobOfferBy` уже равен OWNER. CONTACT пишет туда OWNER же — значение
  // не меняется, лжи не появляется, и запрещать нечего. Проверяется
  // потому, что правило на changedKeys() повело бы себя тут иначе, и
  // разница между двумя формами правила должна быть зафиксирована, а не
  // подразумеваться.
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(
    updateDoc(doc(contactDb, `chats/${CHAT}`), { jobOfferBy: OWNER }),
  );
});

test("N37: нельзя протащить чужой uid вместе с законной правкой", async () => {
  // Правило стоит на КАЖДОМ обновлении документа, а не только на том,
  // где меняется одно это поле. Иначе подделка уехала бы прицепом к
  // обычной записи.
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `chats/${CHAT}`), {
      lastMessage: "yeni mesaj",
      cancelledBy: OWNER,
    }),
  );
});

// ---------------------------------------------------------------------
// personalEvents — СНЯТИЕ стоящего запроса отмены: отзыв и отказ
//
// В данных у этих двух поступков один и тот же след — пустые
// `cancelRequestedBy`/`cancelRequestedAt`. Различает их только имя,
// записанное в `lastActionType`, и потому проверяется здесь не столько
// «можно ли снять», сколько НЕЛЬЗЯ ЛИ СНЯТЬ ЧУЖИМ ИМЕНЕМ: подмена имени
// увела бы уведомление не тому человеку, и ни одна из сторон об этом бы
// не узнала.
//
// Каждая дорога проверяется отдельно — правило «проверка называет
// ДОРОГУ»: «снять запрос» это не проверка, «отозвать свой» и «отклонить
// чужой» — две разные.
// ---------------------------------------------------------------------

// Отменённый договор: подтверждение уже прошло. Ставится в обход правил,
// потому что проверяется как раз то, что после него ничего не проходит.
async function seedCancelled(requestedBy: string, confirmedBy: string) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), `personalEvents/${EVENT}`), {
      cancelRequestedBy: requestedBy,
      cancelRequestedAt: new Date(),
      cancelConfirmedBy: confirmedBy,
      cancelledAt: new Date(),
      status: "cancelled",
    });
  });
}

const withdraw = (uid: string) => ({
  cancelRequestedBy: null,
  cancelRequestedAt: null,
  lastActionBy: uid,
  lastActionType: "cancelWithdrawn",
});

const decline = (uid: string) => ({
  cancelRequestedBy: null,
  cancelRequestedAt: null,
  lastActionBy: uid,
  lastActionType: "cancelDeclined",
});

// --- разрешено ровно тому, кому положено ---

test("отзыв: запросивший МОЖЕТ снять свой запрос", async () => {
  await seedCancelRequest(OWNER);
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), withdraw(OWNER)),
  );
});

test("отказ: вторая сторона МОЖЕТ отклонить чужой запрос", async () => {
  await seedCancelRequest(OWNER);
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), decline(CONTACT)),
  );
});

// --- отказ всем прочим: имя поступка нельзя взять чужое ---

test("отзыв: НЕ запросивший не может назвать своё снятие отзывом", async () => {
  // Вторая сторона снимает чужой запрос под именем 'cancelWithdrawn' —
  // след в данных тот же, но уведомление ушло бы запросившему как «он сам
  // передумал». Это и есть подделка поступка.
  await seedCancelRequest(OWNER);
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), withdraw(CONTACT)),
  );
});

test("отказ: запросивший не может назвать своё снятие отказом", async () => {
  await seedCancelRequest(OWNER);
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), decline(OWNER)),
  );
});

test("снятие: НЕЛЬЗЯ подделать автора записи", async () => {
  // `lastActionBy` чужой — тогда сервер, который этому полю доверяет
  // безоговорочно, назвал бы в уведомлении не того человека.
  await seedCancelRequest(OWNER);
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), {
      ...withdraw(OWNER),
      lastActionBy: CONTACT,
    }),
  );
});

test("снятие: НЕЛЬЗЯ снять запрос безымянно", async () => {
  // Без имени поступка триггер не отличит отзыв от отказа — а отличить
  // ему больше нечем: кто писал, он не видит.
  await seedCancelRequest(OWNER);
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), {
      cancelRequestedBy: null,
      cancelRequestedAt: null,
    }),
  );
});

test("снятие: НЕЛЬЗЯ протащить этим ходом что-то ещё", async () => {
  await seedCancelRequest(OWNER);
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), {
      ...withdraw(OWNER),
      location: "Bakı",
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), {
      ...withdraw(OWNER),
      status: "cancelled",
    }),
  );
});

test("снятие: НЕЛЬЗЯ снять запрос, которого нет", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), withdraw(OWNER)),
  );
});

test("снятие: посторонний не может ни отозвать, ни отклонить", async () => {
  await seedCancelRequest(OWNER);
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertFails(
    updateDoc(doc(strangerDb, `personalEvents/${EVENT}`), withdraw(STRANGER)),
  );
  await assertFails(
    updateDoc(doc(strangerDb, `personalEvents/${EVENT}`), decline(STRANGER)),
  );
});

// --- после подтверждения не проходит ничего ---

test("отзыв: после подтверждения отмены отозвать УЖЕ НЕЛЬЗЯ", async () => {
  await seedCancelled(OWNER, CONTACT);
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), withdraw(OWNER)),
  );
});

test("отказ: после подтверждения отмены отклонить УЖЕ НЕЛЬЗЯ", async () => {
  await seedCancelled(OWNER, CONTACT);
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), decline(CONTACT)),
  );
});

test("N36: повторное подтверждение после cancelled отклоняется", async () => {
  // Щель, найденная 04.08 чтением правил: `cancelRequestedBy` при отмене
  // не очищается, поэтому условие confirmsCancel продолжало выполняться и
  // после неё — вторая сторона могла подтвердить ещё раз и переписать
  // `cancelConfirmedBy` на себя. Договор и так отменён, но «отменил Х»
  // перестало бы значить «решение принял Х».
  await seedCancelled(OWNER, CONTACT);
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      status: "cancelled",
      cancelConfirmedBy: CONTACT,
      cancelledAt: new Date(),
    }),
  );
});

// --- одновременность решают правила, а не UI ---

test("одновременность: после отзыва подтверждение отклоняется", async () => {
  // Кто первым записал, тот и прав. Запросивший отозвал — второй стороне
  // подтверждать больше нечего, и её ход обязан ОТКАЗАТЬ, а не пройти
  // вхолостую: отказ здесь превращается в слова «запрос уже отозван».
  await seedCancelRequest(OWNER);
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), withdraw(OWNER)),
  );
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      status: "cancelled",
      cancelConfirmedBy: CONTACT,
      cancelledAt: new Date(),
    }),
  );
});

test("одновременность: после подтверждения отзыв отклоняется", async () => {
  await seedCancelRequest(OWNER);
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), confirm(CONTACT)),
  );
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), withdraw(OWNER)),
  );
});

test("после отзыва можно запросить отмену ЗАНОВО", async () => {
  // Отзыв не запирает договор навсегда: поля очищены, значит
  // `requestsCancel` снова проходит. Признак нового запроса сервер обязан
  // строить по `cancelRequestedAt`, а не по появлению поля из пустого —
  // класс «признак построен так, будто прошлого не было» (N29).
  await seedCancelRequest(OWNER);
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), withdraw(OWNER)),
  );
  await assertSucceeds(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), request(OWNER)),
  );
});

// ---------------------------------------------------------------------
// personalEvents — выход из чужого мероприятия и признак автора
//
// Ход заведён 03.08: «своё удаляется у всех, чужое — только у меня».
// Удалять документ участнику нельзя (в мероприятии заняты другие), но
// вычеркнуть из него СЕБЯ он вправе.
//
// Запрещённого здесь снова больше, чем разрешённого: ход существует ради
// границ. Признак автора (`lastActionBy`) сервер принимает на веру — на
// нём держится решение, кому слать уведомление, — поэтому подделать его
// не должно быть возможно НИКОМУ, включая владельца.
// ---------------------------------------------------------------------

test("выход: участник МОЖЕТ вычеркнуть себя из чужого мероприятия", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertSucceeds(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      musicians: [OWNER],
      lastActionBy: CONTACT,
      lastActionType: "left",
    }),
  );
});

test("выход: участник НЕ может вычеркнуть кого-то другого", async () => {
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      musicians: [CONTACT],
      lastActionBy: CONTACT,
      lastActionType: "left",
    }),
  );
});

test("выход: участник НЕ может под видом выхода изменить дату", async () => {
  // Главная граница хода: он меняет состав и только состав. Иначе через
  // «выход» правился бы весь договор.
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      musicians: [OWNER],
      date: "2027-01-01T10:00:00.000",
      lastActionBy: CONTACT,
      lastActionType: "left",
    }),
  );
});

test("выход: участник НЕ может выставить lastActionBy чужим uid", async () => {
  // Подделка автора означала бы уведомление «{Ad} sizi çıxardı» с чужим
  // именем — сервер этому признаку доверяет безоговорочно.
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(
    updateDoc(doc(contactDb, `personalEvents/${EVENT}`), {
      musicians: [OWNER],
      lastActionBy: OWNER,
      lastActionType: "left",
    }),
  );
});

test("выход: владелец НЕ может выставить lastActionBy чужим uid", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertFails(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), {
      location: "Gülüstan",
      lastActionBy: CONTACT,
    }),
  );
});

test("выход: владелец МОЖЕТ править своё, отметив себя автором", async () => {
  const ownerDb = testEnv.authenticatedContext(OWNER).firestore();
  await assertSucceeds(
    updateDoc(doc(ownerDb, `personalEvents/${EVENT}`), {
      location: "Gülüstan",
      lastActionBy: OWNER,
      lastActionType: "edited",
    }),
  );
});

test("выход: посторонний не может вычеркнуть себя из чужого мероприятия", async () => {
  const strangerDb = testEnv.authenticatedContext(STRANGER).firestore();
  await assertFails(
    updateDoc(doc(strangerDb, `personalEvents/${EVENT}`), {
      musicians: [OWNER],
      lastActionBy: STRANGER,
      lastActionType: "left",
    }),
  );
});

test("удаление: участник НЕ может удалить чужое мероприятие целиком", async () => {
  // Именно эта граница и заставила завести «выход»: в мероприятии заняты
  // другие люди, и у них оно должно остаться.
  const contactDb = testEnv.authenticatedContext(CONTACT).firestore();
  await assertFails(deleteDoc(doc(contactDb, `personalEvents/${EVENT}`)));
});
