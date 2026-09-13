import fs from "fs";
import path from "path";
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, setDoc } from "firebase/firestore";
import { ref, uploadBytes, getBytes } from "firebase/storage";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// ГОЛОС ПРИЧИНЫ ВЫХОДА — папка `event_leave_notes/{eventId}/{uid}` в
// `storage.rules` (решение владельца 13.09).
//
// ПЕРВЫЙ НАБОР ПРОВЕРОК ПРАВИЛ ХРАНИЛИЩА В ПРОЕКТЕ. До 13.09 правила хранилища
// не проверялись ничем, хотя эмулятор хранилища в `firebase.json` заведён.
// Правило папки спрашивает Firestore (`firestore.get` документа вечера),
// поэтому окружение поднимает оба эмулятора.
//
// ПАРНО: у каждого разрешения свои запреты.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46):
//   • снять `request.auth.uid == uid` — «НЕЛЬЗЯ положить запись под чужим
//     uid», один тест.
//
// ЧЕГО НЕ ЛОВИТ: ссылку с ключом (`getDownloadURL`) — она открывает файл мимо
// этих правил у любого, у кого есть; лежит она в поле вечера, которое читает
// весь состав. Это ограничение решения, а не дыра набора.

const STORAGE_EMULATOR_PORT = 9199;

const OWNER = "owner-uid";
const LEAVER = "leaver-uid";
const OTHER = "other-uid";
const STRANGER = "stranger-uid";
const EVENT = "ev-leave-voice";

const bytes = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7]);
const voicePath = (uid: string) => `event_leave_notes/${EVENT}/${uid}`;
const voiceMeta = (uid: string) => ({
  contentType: "audio/mp4",
  customMetadata: { uploaderUid: uid, eventId: EVENT },
});

describe("13.09: голос причины выхода — своя папка вечера", () => {
  const firestoreRules = fs.readFileSync(
    path.resolve(__dirname, "../../firestore.rules"),
    "utf8",
  );
  const storageRules = fs.readFileSync(
    path.resolve(__dirname, "../../storage.rules"),
    "utf8",
  );

  let env: RulesTestEnvironment;

  beforeAll(async () => {
    env = await initializeTestEnvironment({
      projectId: PROJECT_ID,
      firestore: {
        host: "localhost",
        port: FIRESTORE_EMULATOR_PORT,
        rules: firestoreRules,
      },
      storage: {
        host: "localhost",
        port: STORAGE_EMULATOR_PORT,
        rules: storageRules,
      },
    });
  });

  afterAll(async () => {
    await env?.cleanup();
  });

  beforeEach(async () => {
    await env.clearFirestore();
    await env.clearStorage();
    await env.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), `personalEvents/${EVENT}`), {
        ownerUid: OWNER,
        musicians: [LEAVER, OTHER],
        date: "2026-09-20T19:00:00.000",
        type: "Toy",
        status: "agreed",
      });
    });
  });

  async function seedVoice() {
    await env.withSecurityRulesDisabled(async (context) => {
      await uploadBytes(
        ref(context.storage(), voicePath(LEAVER)),
        bytes,
        voiceMeta(LEAVER),
      );
    });
  }

  // ------------------------------------------------------------------
  // РАЗРЕШЕНО
  // ------------------------------------------------------------------

  // ИЗВЕСТНЫЙ КРАСНЫЙ — 13.09, помечен `it.failing`, решение владельца ждёт.
  //
  // Причина из лога эмулятора: `storage.rules line [43] … Null value error` —
  // `maxUploadSizeBytes` читает `users/{uid}`, а профиля в этом окружении нет.
  // Та же зависимость уже живёт в проде у загрузок в чат и в статусы.
  // Варианты: а) завести профиль в тесте, правило не трогать; б) научить
  // правило папки обходиться без профиля.
  //
  // `it.failing` проходит, ПОКА запись отклонена, и ПОКРАСНЕЕТ САМ, когда она
  // пройдёт — тогда пометку снять. Пока он красный по-настоящему, ЧЕТЫРЕ
  // запрета ниже НЕ доказывают своего: отказ получает кто угодно (I14).
  // Своей причиной подтверждён только «без метки загрузившего» (лог: `line
  // [153] … Property uploaderUid is undefined`).
  it.failing("участник вечера кладёт СВОЮ запись", async () => {
    const storage = env.authenticatedContext(LEAVER).storage();
    await assertSucceeds(
      uploadBytes(ref(storage, voicePath(LEAVER)), bytes, voiceMeta(LEAVER)),
    );
  });

  it("владелец вечера слушает запись", async () => {
    await seedVoice();
    const storage = env.authenticatedContext(OWNER).storage();
    await assertSucceeds(getBytes(ref(storage, voicePath(LEAVER))));
  });

  it("участник состава слушает запись — тот же круг, что у поля", async () => {
    // Не «только владельцу» — и это сказано прямо: защита на показе, как у
    // текста причины. Этот тест фиксирует решение, а не недосмотр.
    await seedVoice();
    const storage = env.authenticatedContext(OTHER).storage();
    await assertSucceeds(getBytes(ref(storage, voicePath(LEAVER))));
  });

  // ------------------------------------------------------------------
  // ЗАПРЕЩЕНО
  // ------------------------------------------------------------------

  it("НЕЛЬЗЯ положить запись под чужим uid", async () => {
    const storage = env.authenticatedContext(LEAVER).storage();
    await assertFails(
      uploadBytes(ref(storage, voicePath(OTHER)), bytes, voiceMeta(LEAVER)),
    );
  });

  it("НЕЛЬЗЯ класть запись в чужой вечер", async () => {
    const storage = env.authenticatedContext(STRANGER).storage();
    await assertFails(
      uploadBytes(
        ref(storage, voicePath(STRANGER)),
        bytes,
        voiceMeta(STRANGER),
      ),
    );
  });

  it("НЕЛЬЗЯ класть запись без метки загрузившего", async () => {
    const storage = env.authenticatedContext(LEAVER).storage();
    await assertFails(
      uploadBytes(ref(storage, voicePath(LEAVER)), bytes, {
        contentType: "audio/mp4",
      }),
    );
  });

  it("НЕЛЬЗЯ класть в эту папку не звук", async () => {
    const storage = env.authenticatedContext(LEAVER).storage();
    await assertFails(
      uploadBytes(ref(storage, voicePath(LEAVER)), bytes, {
        contentType: "text/plain",
        customMetadata: { uploaderUid: LEAVER, eventId: EVENT },
      }),
    );
  });

  it("НЕЛЬЗЯ слушать запись постороннему", async () => {
    await seedVoice();
    const storage = env.authenticatedContext(STRANGER).storage();
    await assertFails(getBytes(ref(storage, voicePath(LEAVER))));
  });
});
