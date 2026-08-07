import fs from "fs";
import path from "path";
import assert from "node:assert";
import {
  initializeTestEnvironment,
  assertFails,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, updateDoc } from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// N45, вторая половина — ПАРНАЯ проверка различителя «гонка или нет».
//
// Правило разбора живёт на клиенте (`core/agreements/agreement_cancel.dart`,
// `explainCancelDenial`) и проверено юнит-тестами по состояниям. Здесь
// проверяется то, чего юнит-тест увидеть не может: что оба состояния
// РЕАЛЬНО ВОЗНИКАЮТ на настоящих правилах, и возникают по разным
// причинам, дающим один и тот же `permission-denied`.
//
// Пара, а не один случай, — ровно по разбору посева N49: набор, где
// сеется только «сломанное» состояние, не отличает работающее правило от
// неработающего.
//
//   А. Правила БЕЗ функции снятия запроса (так прод и жил до 06.08):
//      клиентская форма записи отклоняется, а состояние документа
//      остаётся НЕТРОНУТЫМ — запрос по-прежнему мой. Для `explainCancelDenial`
//      это «неизвестный отказ»: осторожные слова плюс Crashlytics.
//
//   Б. Настоящие правила, но поле уже занято второй стороной: та же
//      форма записи отклоняется, а состояние объясняет отказ — гонка,
//      и сообщение про «вас опередили» верно.

const OWNER = "owner";
const CONTACT = "contactUid";
const EVENT = "ev-denial";

/** Правила, из которых вынута дорога отзыва: `clearsCancelFields` всегда
 *  ложна. Ровно то, чем прод был до выкладки 06.08 — функции не
 *  существовало вовсе, и клиент получал отказ на законный ход. */
function rulesWithoutWithdraw(source: string): string {
  const marker = "function clearsCancelFields() {";
  const start = source.indexOf(marker);
  assert.ok(start > -1, "clearsCancelFields не найдена — правила изменились");
  const end = source.indexOf("\n      }", start) + "\n      }".length;
  return (
    source.slice(0, start) +
    "function clearsCancelFields() { return false; }" +
    source.slice(end)
  );
}

async function seedAgreement(env: RulesTestEnvironment, requestedBy: string) {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `personalEvents/${EVENT}`), {
      ownerUid: OWNER,
      musicians: [OWNER, CONTACT],
      partnerUid: CONTACT,
      date: "2026-09-01T19:00:00.000",
      type: "Toy",
      location: "",
      notes: "",
      isAgree: true,
      status: "agreed",
      cancelRequestedBy: requestedBy,
      cancelRequestedAt: new Date(),
      cancelConfirmedBy: null,
      cancelledAt: null,
    });
  });
}

/** Форма записи ровно та, что шлёт клиент (`withdrawAgreementCancel`). */
const withdraw = (uid: string) => ({
  cancelRequestedBy: null,
  cancelRequestedAt: null,
  lastActionBy: uid,
  lastActionType: "cancelWithdrawn",
});

describe("N45: отказ по правам — две причины, одна ошибка", () => {
  const rulesPath = path.resolve(__dirname, "../../firestore.rules");
  const realRules = fs.readFileSync(rulesPath, "utf8");

  let real: RulesTestEnvironment;
  let stripped: RulesTestEnvironment;

  beforeAll(async () => {
    real = await initializeTestEnvironment({
      projectId: PROJECT_ID,
      firestore: {
        host: "localhost",
        port: FIRESTORE_EMULATOR_PORT,
        rules: realRules,
      },
    });
    stripped = await initializeTestEnvironment({
      projectId: `${PROJECT_ID}-stripped`,
      firestore: {
        host: "localhost",
        port: FIRESTORE_EMULATOR_PORT,
        rules: rulesWithoutWithdraw(realRules),
      },
    });
  });

  afterAll(async () => {
    await real?.cleanup();
    await stripped?.cleanup();
  });

  it("А. правила без функции: отказ есть, а состояние его НЕ объясняет", async () => {
    await seedAgreement(stripped, OWNER);
    const db = stripped.authenticatedContext(OWNER).firestore();

    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), withdraw(OWNER)),
    );

    // Состояние, которое клиент прочитает С СЕРВЕРА после отказа.
    // Запрос по-прежнему мой, договор в силе — объяснить отказ этим
    // нечем. `explainCancelDenial` обязан ответить `unknown`.
    await stripped.withSecurityRulesDisabled(async (context) => {
      const snap = await getDoc(
        doc(context.firestore(), `personalEvents/${EVENT}`),
      );
      assert.equal(snap.data()?.cancelRequestedBy, OWNER);
      assert.equal(snap.data()?.status, "agreed");
    });
  });

  it("Б. настоящие правила, чужой запрос: отказ ОБЪЯСНЯЕТСЯ состоянием", async () => {
    // Запрос подала вторая сторона — отозвать его владелец не может, и
    // это законный исход, а не поломка.
    await seedAgreement(real, CONTACT);
    const db = real.authenticatedContext(OWNER).firestore();

    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), withdraw(OWNER)),
    );

    await real.withSecurityRulesDisabled(async (context) => {
      const snap = await getDoc(
        doc(context.firestore(), `personalEvents/${EVENT}`),
      );
      // Запрос не мой — ровно то состояние, по которому клиентское
      // правило скажет «гонка» и покажет предметное сообщение.
      assert.equal(snap.data()?.cancelRequestedBy, CONTACT);
      assert.equal(snap.data()?.status, "agreed");
    });
  });

  it("пара имеет смысл: отказ в обоих случаях ОДИН И ТОТ ЖЕ", async () => {
    // Если бы причины различались самой ошибкой, весь разбор был бы не
    // нужен. Здесь оба хода отклонены одинаково — различает их только
    // состояние документа, прочитанное следом.
    await seedAgreement(stripped, OWNER);
    await seedAgreement(real, CONTACT);

    const a = stripped.authenticatedContext(OWNER).firestore();
    const b = real.authenticatedContext(OWNER).firestore();

    let codeA = "";
    let codeB = "";
    try {
      await updateDoc(doc(a, `personalEvents/${EVENT}`), withdraw(OWNER));
    } catch (e) {
      codeA = (e as { code?: string }).code ?? "";
    }
    try {
      await updateDoc(doc(b, `personalEvents/${EVENT}`), withdraw(OWNER));
    } catch (e) {
      codeB = (e as { code?: string }).code ?? "";
    }

    assert.ok(codeA.includes("permission-denied"), `А: ${codeA}`);
    assert.equal(codeA, codeB);
  });
});
