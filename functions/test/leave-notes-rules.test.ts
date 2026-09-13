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

// ВЫХОД С ПРИЧИНОЙ — ход `leavesWithNote()` в `firestore.rules` (13.09).
//
// Решение владельца: причина выхода хранится в самом вечере, `leaveNotes.<uid>`,
// текстом и/или ссылкой на голос, и показывается только владельцу.
//
// ПАРНО, как у соседнего набора ответов: у каждого `assertSucceeds` свои
// `assertFails`, и запреты — главная половина файла. Набор, проверяющий одни
// разрешения, не отличит работающее правило от пропускающего всё.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46):
//   • снять `answers.get(uid) == 'left'` — «НЕЛЬЗЯ оставить причину, не
//     выходя», один тест.
//
// ЧЕГО НЕ ЛОВИТ — И НЕ МОЖЕТ: ЧТЕНИЕ. Правила Firestore отдают документ
// целиком, поле не прячут; причину увидит любой из состава, обойдя экран.
// Это ограничение решения, записанное прямо (`docs/handoff.md`), а не дыра
// этого набора. «Только владельцу» держится на показе (`offersLeaveNote`).

const OWNER = "owner-uid";
const LEAVER = "leaver-uid";
const OTHER = "other-uid";
const STRANGER = "stranger-uid";
const EVENT = "ev-leave-notes";

async function seed(env: RulesTestEnvironment) {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `personalEvents/${EVENT}`), {
      ownerUid: OWNER,
      musicians: [LEAVER, OTHER],
      date: "2026-09-20T19:00:00.000",
      type: "Toy",
      location: "",
      notes: "",
      isAgree: false,
      status: "agreed",
      answers: { [LEAVER]: "going", [OTHER]: "going" },
    });
  });
}

describe("13.09: выход с причиной — ответ left и своя причина одной записью", () => {
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
    await seed(env);
  });

  // ------------------------------------------------------------------
  // РАЗРЕШЕНО
  // ------------------------------------------------------------------

  it("вышедший оставляет причину ТЕКСТОМ одной записью с выходом", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${LEAVER}`]: "left",
        [`leaveNotes.${LEAVER}`]: { text: "Toyum var o gün" },
      }),
    );
  });

  it("вышедший оставляет причину ГОЛОСОМ — ссылка и волна", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${LEAVER}`]: "left",
        [`leaveNotes.${LEAVER}`]: {
          voiceUrl: "https://example/voice",
          voiceWaveform: [3, 50, 100],
        },
      }),
    );
  });

  it("выход БЕЗ причины проходит по-прежнему", async () => {
    // Канарейка к новому ходу: причина необязательна, и выход без неё идёт
    // старым `answersForSelf`. Сломай правка его — ушёл бы и молчаливый выход.
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${LEAVER}`]: "left",
      }),
    );
  });

  // ------------------------------------------------------------------
  // ЗАПРЕЩЕНО
  // ------------------------------------------------------------------

  it("НЕЛЬЗЯ оставить причину, не выходя", async () => {
    // Причина говорится про уход. «Иду» с приписанной причиной — это слова
    // об уходе, которого не было.
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${LEAVER}`]: "cant",
        [`leaveNotes.${LEAVER}`]: { text: "səbəb" },
      }),
    );
  });

  it("НЕЛЬЗЯ оставить причину за другого", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${LEAVER}`]: "left",
        [`leaveNotes.${OTHER}`]: { text: "o da gəlmir" },
      }),
    );
  });

  it("НЕЛЬЗЯ положить в причину лишнее поле", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${LEAVER}`]: "left",
        [`leaveNotes.${LEAVER}`]: { text: "səbəb", lastActionType: "cancelled" },
      }),
    );
  });

  it("НЕЛЬЗЯ причине быть не картой", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${LEAVER}`]: "left",
        [`leaveNotes.${LEAVER}`]: "просто строка",
      }),
    );
  });

  it("НЕЛЬЗЯ этим ходом тронуть другое поле вечера", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${LEAVER}`]: "left",
        [`leaveNotes.${LEAVER}`]: { text: "səbəb" },
        date: "2026-09-21T19:00:00.000",
      }),
    );
  });

  it("НЕЛЬЗЯ оставить причину в вечере, где тебя нет в составе", async () => {
    const db = env.authenticatedContext(STRANGER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${STRANGER}`]: "left",
        [`leaveNotes.${STRANGER}`]: { text: "səbəb" },
      }),
    );
  });
});
