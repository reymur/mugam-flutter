import fs from "fs";
import path from "path";
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, setDoc, updateDoc, deleteField } from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// ПРАВИЛО «УЧАСТНИК ОТВЕЧАЕТ ЗА СЕБЯ» — шаг 4, пункт 1 (`docs/plan.md`).
//
// ПАРНО, а не по одному разрешению: набор, проверяющий только «разрешено»,
// не отличает работающее правило от правила, которое пропускает вообще всё.
// Поэтому у каждого `assertSucceeds` здесь есть свой `assertFails`, и
// запреты — главная половина файла, а не довесок.
//
// ЧТО ИМЕННО СТОРОЖИТСЯ, если читать список запретов сверху вниз: участник
// не должен мочь ответить за другого, тронуть этим ходом состав, дату или
// статус, отвечать после выхода из состава — и не должен мочь ОТМЕНИТЬ САМ
// ФАКТ ВОПРОСА, стерев свой ключ или записав в него мусор.

const OWNER = "owner-uid";
const GUEST = "guest-uid";
const OTHER = "other-uid";
const STRANGER = "stranger-uid";
const EVENT = "ev-answers";

async function seed(
  env: RulesTestEnvironment,
  answers: Record<string, unknown> | undefined,
  musicians: string[] = [OWNER, GUEST, OTHER],
) {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `personalEvents/${EVENT}`), {
      ownerUid: OWNER,
      musicians,
      date: "2026-09-01T19:00:00.000",
      type: "Toy",
      location: "",
      notes: "",
      isAgree: false,
      status: "agreed",
      ...(answers === undefined ? {} : { answers }),
    });
  });
}

describe("шаг 4: участник отвечает за себя, и только за себя", () => {
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

  it("участник ставит «иду»", async () => {
    await seed(env, { [GUEST]: "waiting", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
      }),
    );
  });

  it("участник ставит «не могу»", async () => {
    await seed(env, { [GUEST]: "waiting", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "cant",
      }),
    );
  });

  it("участник меняет свой ответ второй раз подряд", async () => {
    // Ответ не приколочен: передумать можно, и это не отдельный поступок.
    await seed(env, { [GUEST]: "going", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "cant",
      }),
    );
  });

  it("у СТАРОГО документа без карты участник отвечает впервые", async () => {
    // 75 записей прода живут без поля `answers` вовсе. Первый ответ в таком
    // документе создаёт карту — и это законный ход, а не обход.
    await seed(env, undefined);
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "cant",
      }),
    );
  });

  // ------------------------------------------------------------------
  // ЗАПРЕЩЕНО — по одному запрету на каждое разрешение выше и сверх того
  // ------------------------------------------------------------------

  it("НЕЛЬЗЯ ответить за другого", async () => {
    await seed(env, { [GUEST]: "waiting", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${OTHER}`]: "going",
      }),
    );
  });

  it("НЕЛЬЗЯ написать свой и чужой ключ ОДНОЙ записью", async () => {
    // Главный случай: «свой» рядом с чужим выглядит законным ходом.
    await seed(env, { [GUEST]: "waiting", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
        [`answers.${OTHER}`]: "going",
      }),
    );
  });

  it("НЕЛЬЗЯ этим ходом сдвинуть дату", async () => {
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
        date: "2026-09-02T19:00:00.000",
      }),
    );
  });

  it("НЕЛЬЗЯ этим ходом тронуть состав", async () => {
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
        musicians: [OWNER, GUEST],
      }),
    );
  });

  it("НЕЛЬЗЯ этим ходом отменить вечер", async () => {
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
        status: "cancelled",
      }),
    );
  });

  it("НЕЛЬЗЯ приписать этому ходу ИМЯ ПОСТУПКА", async () => {
    // Ход выглядит безобидным: свой ключ на месте, чужого нет. Но
    // `lastActionType` — это РАССКАЗ о случившемся, и сервер верит ему без
    // проверки: по нему он решает, кого известить и какими словами. Дать
    // участнику ставить его вместе с ответом значило бы дать ему выдать
    // ответ за уход, отмену или возврат в силу.
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
        lastActionType: "left",
        lastActionBy: GUEST,
      }),
    );
  });

  // ОБХОД ЧЕРЕЗ ОТСУТСТВИЕ — два запрета, один класс.
  //
  // `answerOf` читает пустоту и мусор ОДИНАКОВО: как `notAsked`, то есть «его
  // не спрашивали». Значит обе дороги ведут к одному — участник отменяет сам
  // факт вопроса, и выглядит это не как отказ, а как будто его не звали.

  it("НЕЛЬЗЯ стереть свой ключ — это подделка «меня не спрашивали»", async () => {
    await seed(env, { [GUEST]: "going", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: deleteField(),
      }),
    );
  });

  it("НЕЛЬЗЯ записать незнакомую строку — та же подделка другим путём", async () => {
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "нечто",
      }),
    );
  });

  it("НЕЛЬЗЯ записать notAsked — оно И ЕСТЬ отсутствие ключа", async () => {
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "notAsked",
      }),
    );
  });

  it("НЕЛЬЗЯ отвечать в вечере, где тебя нет в составе", async () => {
    await seed(env, { [GUEST]: "waiting" }, [OWNER, GUEST]);
    const db = env.authenticatedContext(STRANGER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${STRANGER}`]: "going",
      }),
    );
  });

  it("УШЕДШИЙ не может ответить после выхода", async () => {
    // Его ключ в карте остался — `leavesEvent` к `answers` не пускает. Но
    // `isParty()` его больше не признаёт, и вся ветка ему закрыта.
    await seed(env, { [GUEST]: "going" }, [OWNER, OTHER]);
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "cant",
      }),
    );
  });
});
