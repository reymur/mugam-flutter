import fs from "fs";
import path from "path";
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, setDoc, updateDoc } from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// СОСТОЯНИЕ ВЕЧЕРА СТАВИТ ВЛАДЕЛЕЦ — решение автора 12.08 («Состояния
// пересмотрены», docs/plan.md).
//
// ПАРНО: у каждого разрешения свой запрет. Набор, проверяющий только
// «разрешено», не отличает работающее правило от правила, пропускающего всё.
//
// ЗАПРЕТЫ ЗДЕСЬ ГЛАВНЕЕ РАЗРЕШЕНИЙ, и два из них тоньше прочих:
//
//   • `hasOnly` на три ключа — этим ходом нельзя тронуть заодно дату, состав
//     или ответы. Без него смена состояния становится дорогой к правке всего
//     документа: правило смотрит на `status`, а запись несёт что угодно;
//   • имя поступка нельзя подменить именем ОТМЕНЫ. Сервер верит
//     `lastActionType` без проверки — по нему он решает, кого известить и
//     какими словами (I54). Разреши его здесь — и состояние можно поставить,
//     выдав за отмену, а триггер разошлёт не ту новость.

const OWNER = "owner-uid";
const GUEST = "guest-uid";
const EVENT = "ev-status";

async function seed(
  env: RulesTestEnvironment,
  over: Record<string, unknown> = {},
) {
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

const setStatus = (
  uid: string,
  status: string,
  deed: string,
): Record<string, unknown> => ({
  status,
  lastActionBy: uid,
  lastActionType: deed,
});

describe("шаг: состояние вечера ставит владелец", () => {
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
  // РАЗРЕШЕНО
  // ------------------------------------------------------------------

  it("владелец ставит «под вопросом» своим сомнением", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(OWNER, "unsettled", "ownerDoubt"),
      ),
    );
  });

  it("владелец ставит «под вопросом» по отменённой работе", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(OWNER, "unsettled", "workCancelled"),
      ),
    );
  });

  it("владелец возвращает «точно» — переход обратим", async () => {
    await seed(env, { status: "unsettled", lastActionType: "ownerDoubt" });
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(OWNER, "agreed", "ownerFirm"),
      ),
    );
  });

  it("владелец отменяет ЛИЧНЫЙ вечер один", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(OWNER, "cancelled", "ownerCancelled"),
      ),
    );
  });

  it("владелец возвращает ЛИЧНЫЙ вечер из отмены", async () => {
    await seed(env, { status: "cancelled" });
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(OWNER, "agreed", "ownerRestored"),
      ),
    );
  });

  it("участник помечает СЕБЯ вышедшим", async () => {
    await seed(env, { answers: { [OWNER]: "going", [GUEST]: "going" } });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "left",
      }),
    );
  });

  // ------------------------------------------------------------------
  // ЗАПРЕЩЕНО — главная половина
  // ------------------------------------------------------------------

  it("НЕЛЬЗЯ отменить вечер С ДОГОВОРЁННОСТЬЮ в одиночку", async () => {
    // «Расторгнуть договорённость» требует согласия второй стороны — оно её
    // и составляет. Разреши этот ход — и четыре проверенных хода отмены
    // становятся кодом без читателя.
    await seed(env, { isAgree: true });
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(OWNER, "cancelled", "ownerCancelled"),
      ),
    );
  });

  it("НЕЛЬЗЯ вернуть ДОГОВОРЁННОСТЬ из отмены в одиночку", async () => {
    // Отменить вдвоём, а вернуть в одиночку — дыра того же рода с другого
    // конца: согласие обходится в два хода.
    await seed(env, { isAgree: true, status: "cancelled" });
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(OWNER, "agreed", "ownerRestored"),
      ),
    );
  });

  it("НЕЛЬЗЯ ставить «под вопросом» по поводу memberLeft", async () => {
    // По решению 12.08 уход участника больше не ставит вечер под вопрос:
    // под вопросом ОДИН ЧЕЛОВЕК, а не вечер, и повод переехал на него
    // (`answers[uid] == 'left'`). Приняв его здесь, правило держало бы
    // открытой дорогу к состоянию, которого мы больше не порождаем.
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(OWNER, "unsettled", "memberLeft"),
      ),
    );
  });

  it("НЕЛЬЗЯ поставить cancelled через ход смены состояния", async () => {
    // Отмена идёт своими ходами; разреши её здесь — и различение личного
    // вечера и договорённости обходится этим ходом.
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(OWNER, "cancelled", "ownerDoubt"),
      ),
    );
  });

  it("НЕЛЬЗЯ тронуть заодно ДАТУ", async () => {
    // `hasOnly` на три ключа. Без него смена состояния становится дорогой к
    // правке всего документа: правило смотрит на `status`, а запись несёт
    // что угодно.
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        ...setStatus(OWNER, "unsettled", "ownerDoubt"),
        date: "2026-09-02T19:00:00.000",
      }),
    );
  });

  it("НЕЛЬЗЯ тронуть заодно СОСТАВ", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        ...setStatus(OWNER, "unsettled", "ownerDoubt"),
        musicians: [OWNER],
      }),
    );
  });

  it("НЕЛЬЗЯ приписать этому ходу ИМЯ ОТМЕНЫ", async () => {
    // Тоньше прочих запретов. Сервер верит `lastActionType` без проверки —
    // по нему он решает, кого известить и какими словами (I54). Разреши
    // подмену — и состояние можно поставить, выдав его за отмену, а триггер
    // разошлёт не ту новость.
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(OWNER, "unsettled", "cancelRequested"),
      ),
    );
  });

  it("НЕЛЬЗЯ участнику менять состояние вечера", async () => {
    await seed(env);
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(GUEST, "unsettled", "ownerDoubt"),
      ),
    );
  });

  it("НЕЛЬЗЯ подписать ход чужим именем", async () => {
    await seed(env);
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(
      updateDoc(
        doc(db, `personalEvents/${EVENT}`),
        setStatus(GUEST, "unsettled", "ownerDoubt"),
      ),
    );
  });

  it("НЕЛЬЗЯ пометить вышедшим ДРУГОГО", async () => {
    await seed(env, { answers: { [OWNER]: "going", [GUEST]: "going" } });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${OWNER}`]: "left",
      }),
    );
  });

  it("НЕЛЬЗЯ записать незнакомое значение вместо «вышел»", async () => {
    await seed(env, { answers: { [GUEST]: "going" } });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "gone",
      }),
    );
  });
});
