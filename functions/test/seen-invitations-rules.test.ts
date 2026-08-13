import fs from "fs";
import path from "path";
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, setDoc, getDoc, deleteDoc } from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// ПРАВИЛО «Я ЭТО ПРИГЛАШЕНИЕ ВИДЕЛ» — users/{uid}/seenInvitations/{eventId}.
//
// Заведено 12.08 для числа непросмотренных приглашений на клетке календаря.
//
// ПАРНО, а не по одному разрешению: набор, проверяющий только «разрешено»,
// не отличает работающее правило от правила, которое пропускает вообще всё.
// У каждого `assertSucceeds` здесь есть свой `assertFails`.
//
// ЧТО СТОРОЖИТСЯ ПО СУЩЕСТВУ: пометка личная в ОБЕ стороны. Чужую читать
// нельзя — иначе видно, что человек смотрел и когда; чужую писать нельзя —
// иначе можно погасить чужой счётчик, то есть **спрятать от человека
// приглашение, которого он не видел**. Второе хуже первого, и ради него
// запрет на запись проверяется отдельно от запрета на чтение.
//
// ЧЕГО ЭТОТ НАБОР НЕ ЛОВИТ (границы пишутся рядом со сторожем):
//   • он ничего не говорит о СОДЕРЖИМОМ документа — правило его не
//     разбирает вовсе, и человек волен положить в свою пометку что угодно.
//     Это осознанно: пометка личная, и врать ею можно только себе;
//   • он не проверяет, что `eventId` — существующее мероприятие. Правило
//     этого не требует, и пометка о несуществующем вечере безвредна: её
//     никто не прочитает, потому что такого дня в календаре нет.

const ME = "me-uid";
const OTHER = "other-uid";
const EVENT = "ev-seen";

describe("пометка «просмотрено» — личная в обе стороны", () => {
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

  it("человек помечает приглашение просмотренным у СЕБЯ", async () => {
    const db = env.authenticatedContext(ME).firestore();
    await assertSucceeds(
      setDoc(doc(db, `users/${ME}/seenInvitations/${EVENT}`), {
        seenAt: new Date().toISOString(),
      }),
    );
  });

  it("человек читает СВОИ пометки", async () => {
    await env.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), `users/${ME}/seenInvitations/${EVENT}`),
        { seenAt: "2026-08-12T22:00:00.000Z" },
      );
    });
    const db = env.authenticatedContext(ME).firestore();
    await assertSucceeds(
      getDoc(doc(db, `users/${ME}/seenInvitations/${EVENT}`)),
    );
  });

  it("повторная пометка того же приглашения проходит", async () => {
    // Запись идемпотентна по замыслу: человек может открыть приглашение
    // дважды, и второй раз не должен ни падать, ни менять смысл.
    const db = env.authenticatedContext(ME).firestore();
    const ref = doc(db, `users/${ME}/seenInvitations/${EVENT}`);
    await assertSucceeds(setDoc(ref, { seenAt: "1" }));
    await assertSucceeds(setDoc(ref, { seenAt: "2" }));
  });

  it("человек снимает СВОЮ пометку", async () => {
    // Прямого повода в приложении нет, но запрещать владельцу удалять своё
    // значило бы завести данные, от которых он не может избавиться.
    const db = env.authenticatedContext(ME).firestore();
    await assertSucceeds(
      setDoc(doc(db, `users/${ME}/seenInvitations/${EVENT}`), { seenAt: "1" }),
    );
    await assertSucceeds(
      deleteDoc(doc(db, `users/${ME}/seenInvitations/${EVENT}`)),
    );
  });

  // ------------------------------------------------------------------
  // ЗАПРЕЩЕНО — главная половина файла
  // ------------------------------------------------------------------

  it("ЧУЖУЮ пометку писать нельзя — иначе можно погасить чужой счётчик", async () => {
    // Самый опасный из запретов: сумев записать чужую пометку, посторонний
    // спрятал бы от человека приглашение, которого тот не видел. Пропажа
    // выглядела бы как «мне не звонили».
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(
      setDoc(doc(db, `users/${ME}/seenInvitations/${EVENT}`), { seenAt: "1" }),
    );
  });

  it("ЧУЖУЮ пометку читать нельзя", async () => {
    await env.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), `users/${ME}/seenInvitations/${EVENT}`),
        { seenAt: "1" },
      );
    });
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(getDoc(doc(db, `users/${ME}/seenInvitations/${EVENT}`)));
  });

  it("ЧУЖУЮ пометку удалять нельзя", async () => {
    await env.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), `users/${ME}/seenInvitations/${EVENT}`),
        { seenAt: "1" },
      );
    });
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(
      deleteDoc(doc(db, `users/${ME}/seenInvitations/${EVENT}`)),
    );
  });

  it("НЕВОШЕДШИЙ не пишет и не читает ничего", async () => {
    const db = env.unauthenticatedContext().firestore();
    await assertFails(
      setDoc(doc(db, `users/${ME}/seenInvitations/${EVENT}`), { seenAt: "1" }),
    );
    await assertFails(getDoc(doc(db, `users/${ME}/seenInvitations/${EVENT}`)));
  });
});
