import fs from "fs";
import path from "path";
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, deleteDoc, serverTimestamp } from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// АДРЕС PUSHKIT — users/{uid}/voipPushTokens/{deviceId} (N172, N190).
//
// ПАРНО: у каждого разрешения свой запрет. Набор, проверяющий только
// «разрешено», не отличает работающее правило от правила, пропускающего всё.
//
// ГЛАВНЫЙ ЗАПРЕТ ЗДЕСЬ — ЧУЖОЕ ЧТЕНИЕ, и он не симметричен соседней
// коллекции `pushTokens`, где чтение открыто любому вошедшему. Разница
// намеренная: там чужой читатель есть по-настоящему (клиент mugam-v2 сам
// шлёт Expo push), здесь его нет — VoIP-адрес нужен только нашему серверу,
// а он ходит Admin SDK мимо правил.
//
// Цена ошибки здесь выше, чем у обычного токена, и вердикт «чужой не
// читает» стоит первым именно поэтому: обычный адрес позволяет прислать
// человеку лишнее уведомление, VoIP-адрес — заставить его телефон показать
// окно ВХОДЯЩЕГО ЗВОНКА.
//
// СОСЕДКА НА СОБСТВЕННУЮ СЛЕПОТУ (I31): вердикт «свой читает свой» падает,
// если правило запретит вообще всё. Без него набор из одних запретов
// зазеленел бы на правиле `allow read, write: if false` — то есть на
// коллекции, в которую никто не может записать адрес, и звонок не пришёл
// бы никогда.

const ME = "me-uid";
const OTHER = "other-uid";
const DEVICE = "device-1";

const p = (uid: string) => `users/${uid}/voipPushTokens/${DEVICE}`;

const tokenDoc = () => ({
  token: "a".repeat(64),
  platform: "ios",
  environment: "sandbox",
  updatedAt: serverTimestamp(),
});

describe("адрес PushKit: voipPushTokens", () => {
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

  async function seedFor(uid: string): Promise<void> {
    await env.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), p(uid)), {
        token: "b".repeat(64),
        platform: "ios",
        environment: "sandbox",
      });
    });
  }

  // ------------------------------------------------------------------
  // РАЗРЕШЕНО
  // ------------------------------------------------------------------

  it("свой пишет свой адрес", async () => {
    const db = env.authenticatedContext(ME).firestore();
    await assertSucceeds(setDoc(doc(db, p(ME)), tokenDoc()));
  });

  it("свой читает свой адрес — СОСЕДКА, падает на правиле «запретить всё»", async () => {
    await seedFor(ME);
    const db = env.authenticatedContext(ME).firestore();
    await assertSucceeds(getDoc(doc(db, p(ME))));
  });

  it("свой снимает свой адрес — выход из учётки обязан его убрать", async () => {
    await seedFor(ME);
    const db = env.authenticatedContext(ME).firestore();
    await assertSucceeds(deleteDoc(doc(db, p(ME))));
  });

  // ------------------------------------------------------------------
  // ЗАПРЕЩЕНО
  // ------------------------------------------------------------------

  it("ЧУЖОЙ НЕ ЧИТАЕТ — иначе чужим телефоном можно позвонить", async () => {
    await seedFor(ME);
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(getDoc(doc(db, p(ME))));
  });

  it("чужой не пишет — подменённый адрес увёл бы звонок на другой телефон", async () => {
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(setDoc(doc(db, p(ME)), tokenDoc()));
  });

  it("чужой не удаляет — снятый адрес это тихая потеря звонков", async () => {
    await seedFor(ME);
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(deleteDoc(doc(db, p(ME))));
  });

  it("невошедший не читает", async () => {
    await seedFor(ME);
    const db = env.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(db, p(ME))));
  });

  it("невошедший не пишет", async () => {
    const db = env.unauthenticatedContext().firestore();
    await assertFails(setDoc(doc(db, p(ME)), tokenDoc()));
  });

  // ------------------------------------------------------------------
  // РАЗНИЦА С СОСЕДНЕЙ КОЛЛЕКЦИЕЙ — вердикт на саму несимметричность
  // ------------------------------------------------------------------

  it("у pushTokens чужое чтение ОТКРЫТО — и это не должно перетечь сюда", async () => {
    // Вердикт сторожит РАЗЛИЧИЕ, а не одну из сторон. Сведи кто-нибудь две
    // коллекции «как одинаковые» — здесь станет красно, и станет ясно, что
    // сведены разные задачи (I58), а не устранено дублирование.
    await env.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), `users/${ME}/pushTokens/${DEVICE}`), {
        token: "c".repeat(64),
      });
    });
    const db = env.authenticatedContext(OTHER).firestore();
    await assertSucceeds(getDoc(doc(db, `users/${ME}/pushTokens/${DEVICE}`)));
  });
});
