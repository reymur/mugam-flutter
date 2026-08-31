import fs from "fs";
import path from "path";
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, setDoc, updateDoc, serverTimestamp, Timestamp } from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// ВРЕМЯ ПОСТУПКА — СЕРВЕРНОЕ (N181).
//
// Работа заводит `lastActionAt` рядом с `lastActionBy`/`lastActionType` и
// включает его в ключ, по которому строка «что случилось» прячется
// крестиком. До него ключ у двух ОДИНАКОВЫХ поступков совпадал, и второй
// такой же поступок оставался невидимым навсегда.
//
// ПАРНО: у каждого разрешения свой запрет. Набор, проверяющий только
// «разрешено», не отличает работающее правило от правила, пропускающего всё.
//
// ТРИ ВЕЩИ ЗДЕСЬ ГЛАВНЫЕ, И КАЖДАЯ ЛОВИТСЯ ОТДЕЛЬНЫМ ВЕРДИКТОМ:
//
//   1. КЛЮЧ ПРОХОДИТ `hasOnly`. Забудь его вписать хоть в одну ветку — и
//      этот ход перестанет работать ЦЕЛИКОМ: `hasOnly` отвергает запись, а
//      не лишний ключ. То есть отмена или смена состояния сломались бы в
//      проде, а не «время не сохранилось»;
//   2. ВРЕМЯ НЕЛЬЗЯ ПОДДЕЛАТЬ. Оно часть ключа видимости, значит участник,
//      пишущий своё время, попадает в чужой прежний ключ (I54);
//   3. ЗАПИСЬ БЕЗ КЛЮЧА ПО-ПРЕЖНЕМУ ПРОХОДИТ. Это переходное окно: правила
//      выкладываются ПЕРВЫМИ, и сутки-другие в проде живёт сборка, которая
//      ключа не пишет. Сломай это — и выкладка правил положит прод до
//      выкладки клиента.
//
// Вердикт 3 — единственный, который выглядит как «правило ничего не
// проверяет», и потому объяснён здесь: он проверяет ОКНО, и без него
// порядок выкладки становится недоказанным.

const OWNER = "owner-uid";
const GUEST = "guest-uid";
const EVENT = "ev-lastactionat";

async function seed(
  env: RulesTestEnvironment,
  over: Record<string, unknown> = {},
): Promise<void> {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `personalEvents/${EVENT}`), {
      ownerUid: OWNER,
      musicians: [OWNER, GUEST],
      date: "2026-09-01T19:00:00.000",
      type: "Toy",
      location: "",
      notes: "",
      isAgree: false,
      status: "agreed",
      ...over,
    });
  });
}

describe("время поступка — серверное (N181)", () => {
  const rulesPath = path.resolve(__dirname, "../../firestore.rules");
  const realRules = fs.readFileSync(rulesPath, "utf8");

  let env: RulesTestEnvironment;

  beforeAll(async () => {
    env = await initializeTestEnvironment({
      projectId: PROJECT_ID,
      firestore: {
        host: "localhost",
        port: FIRESTORE_EMULATOR_PORT,
        rules: realRules,
      },
    });
  });

  afterAll(async () => {
    await env?.cleanup();
  });

  beforeEach(async () => {
    await env.clearFirestore();
  });

  // ------------------------------------------------------------------
  // РАЗРЕШЕНО — по одному на каждую ветку, где стоит `hasOnly`.
  //
  // Веток семь, и они перечислены поимённо, а не «проверим одну как
  // образец»: `hasOnly` живёт СВОИМ списком в каждой, и забытый ключ в
  // шестой не виден по зелёной пятой (I64 — проверять каждого, кто
  // подпадает, а не наличие правила).
  // ------------------------------------------------------------------

  it("1/7 ownerSetsStatus — состояние со временем", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        status: "unsettled",
        lastActionBy: OWNER,
        lastActionType: "ownerDoubt",
        lastActionAt: serverTimestamp(),
      }),
    );
  });

  it("2/7 ownerCancelsOwnEvent — отмена личного вечера со временем", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        status: "cancelled",
        lastActionBy: OWNER,
        lastActionType: "ownerCancelled",
        lastActionAt: serverTimestamp(),
      }),
    );
  });

  it("3/7 ownerRestoresOwnEvent — возврат личного вечера со временем", async () => {
    await seed(env, { status: "cancelled" });
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        status: "agreed",
        lastActionBy: OWNER,
        lastActionType: "ownerRestored",
        lastActionAt: serverTimestamp(),
      }),
    );
  });

  it("4/7 requestsCancel — просьба об отмене со временем", async () => {
    await seed(env, { isAgree: true });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        cancelRequestedBy: GUEST,
        cancelRequestedAt: serverTimestamp(),
        lastActionBy: GUEST,
        lastActionType: "cancelRequested",
        lastActionAt: serverTimestamp(),
      }),
    );
  });

  it("5/7 confirmsCancel — подтверждение чужой просьбы со временем", async () => {
    await seed(env, { isAgree: true, cancelRequestedBy: GUEST });
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        status: "cancelled",
        cancelConfirmedBy: OWNER,
        cancelledAt: serverTimestamp(),
        lastActionBy: OWNER,
        lastActionType: "cancelConfirmed",
        lastActionAt: serverTimestamp(),
      }),
    );
  });

  it("6/7 clearsCancelFields — отзыв своей просьбы со временем", async () => {
    await seed(env, { isAgree: true, cancelRequestedBy: GUEST });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        cancelRequestedBy: null,
        cancelRequestedAt: null,
        lastActionBy: GUEST,
        lastActionType: "cancelWithdrawn",
        lastActionAt: serverTimestamp(),
      }),
    );
  });

  it("7/7 restoresEvent — возврат вечера после ухода, со временем", async () => {
    await seed(env, { status: "unsettled", lastActionType: "memberLeft" });
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        status: "agreed",
        lastActionBy: OWNER,
        lastActionType: "restored",
        lastActionAt: serverTimestamp(),
      }),
    );
  });

  // ------------------------------------------------------------------
  // ЗАПРЕЩЕНО — подделка времени
  // ------------------------------------------------------------------

  it("время из прошлого не проходит — попадание в чужой прежний ключ", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        status: "unsettled",
        lastActionBy: OWNER,
        lastActionType: "ownerDoubt",
        // Ровно тот вред, ради которого правило написано: подставив время
        // прежнего такого же поступка, участник попадает в ключ, по
        // которому строка уже спрятана, — и новость исчезает молча.
        lastActionAt: Timestamp.fromDate(new Date("2026-08-01T00:00:00Z")),
      }),
    );
  });

  it("время из будущего не проходит", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        status: "unsettled",
        lastActionBy: OWNER,
        lastActionType: "ownerDoubt",
        lastActionAt: Timestamp.fromDate(new Date("2027-01-01T00:00:00Z")),
      }),
    );
  });

  it("подделать время нельзя и владельцу — своей широкой ветвью тоже", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    // Ветвь владельца перечисления ключей не имеет вовсе, то есть правит
    // что угодно. Привратник времени стоит ВЫШЕ неё — на самом `allow
    // update`, — и потому накрывает и её. Уедь он внутрь ходов — здесь
    // стало бы зелено.
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        notes: "любая правка владельца",
        lastActionBy: OWNER,
        lastActionType: "eventEdited",
        lastActionAt: Timestamp.fromDate(new Date("2026-08-01T00:00:00Z")),
      }),
    );
  });

  // ------------------------------------------------------------------
  // ПЕРЕХОДНОЕ ОКНО — старая сборка ключа не пишет и обязана работать
  // ------------------------------------------------------------------

  it("ОКНО: запись без ключа проходит — старая сборка не ломается", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    // Порядок выкладки — правила первыми, клиент вторым. Между ними в
    // проде живёт сборка, которая `lastActionAt` не пишет. Покрасней этот
    // вердикт — и выкладка правил положила бы прод до выкладки клиента:
    // `hasOnly` отвергает запись целиком, то есть перестала бы работать
    // сама смена состояния, а не отметка времени.
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        status: "unsettled",
        lastActionBy: OWNER,
        lastActionType: "ownerDoubt",
      }),
    );
  });

  it("ОКНО: старая сборка отменяет вечер без ключа", async () => {
    await seed(env, { isAgree: true, cancelRequestedBy: GUEST });
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        status: "cancelled",
        cancelConfirmedBy: OWNER,
        cancelledAt: serverTimestamp(),
        lastActionBy: OWNER,
        lastActionType: "cancelConfirmed",
      }),
    );
  });
});
