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
//   • снять `request.auth.uid == uid` в ПРАВИЛЕ ЗАПИСИ — «НЕЛЬЗЯ положить
//     запись под чужим uid», один тест;
//   • снять `request.auth.uid == uid` в ПРАВИЛЕ ЧТЕНИЯ — «вышедший слушает
//     СВОЮ запись», один тест, и только он;
//   • снять `request.auth.uid == leaveEvent().ownerUid` в правиле чтения —
//     «владелец вечера слушает запись», один тест, и только он.
// У каждой ветви чтения свой свидетель. Покраснели обе разом — ветви не
// разделены, и правило написано не так, как задумано.
//
// ЧЕГО НЕ ЛОВИТ: ссылку с ключом (`getDownloadURL`) — она открывает файл мимо
// этих правил у любого, у кого есть; лежит она в поле вечера, которое читает
// весь состав. Сужение 15.09 этого НЕ меняет и не может: набор проверяет
// право, а ссылка ходит мимо права. Разбор — `docs/n232-token-links.md`.

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

  // БЫЛ КРАСНЫМ 13.09 (`it.failing`), ПОЧИНЕН 14.09 РЕШЕНИЕМ ВЛАДЕЛЬЦА —
  // вариант «б» с условием: у `maxUploadSizeBytes` появилось умолчание на
  // случай отсутствующего документа профиля, и число взято не новое, а то же,
  // что получают все двенадцать учёток с профилем (перепись прода 14.09).
  //
  // Прежняя причина отказа, для памяти: `maxUploadSizeBytes` читает
  // `users/{uid}`, профиля в этом окружении нет, `firestore.get()` отдаёт
  // `null` — `storage.rules line [43] … Null value error`. Та же зависимость
  // живёт в проде у загрузок в чат и в статусы с 14.07, и чинится она этой
  // же правкой: функция одна на все три места.
  //
  // ЗДЕСЬ СТОЯЛО «ЧЕТЫРЕ ЗАПРЕТА ИЗ ПЯТИ НЕ ДОКАЗАНЫ», И ЭТО БЫЛО НЕВЕРНО
  // (снято 14.09 замером). `maxUploadSizeBytes` стоит ПОСЛЕДНИМ звеном в
  // цепочке `&&`, и вычисление до него не доходит, пока не пройдено всё
  // предыдущее: три запрета записи обрываются раньше на своей лжи, четвёртый
  // — своей ошибкой на `uploaderUid`, пятый вовсе про чтение. Замер вместо
  // рассуждения: за прогон из восьми тестов `Null value error` в логе РОВНО
  // ОДИН, а не пять (14.09 04:19 +04). Не будь короткого замыкания, своя
  // такая ошибка нашлась бы у каждого запрета записи.
  it("участник вечера кладёт СВОЮ запись", async () => {
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

  // ЗАВЕДЁН 15.09 ВМЕСТЕ С СУЖЕНИЕМ (N232, шаг 1), и вот зачем.
  //
  // До сужения автор читал свою запись ПОБОЧНО — как член состава, своей
  // ветви у него не было. После сужения на ветви `== uid` стоит САМА
  // ОТПРАВКА ПРИЧИНЫ: `uploadLeaveNoteVoice` зовёт `getDownloadURL()` сразу
  // после загрузки, от имени загрузившего, а это чтение. Убери ветвь — и
  // отправка перестанет работать целиком, причём у всех.
  //
  // Несущее без сторожа — это I9, поэтому сторож заведён тем же заходом, что
  // и правило, а не «когда-нибудь потом».
  it("вышедший слушает СВОЮ запись", async () => {
    await seedVoice();
    const storage = env.authenticatedContext(LEAVER).storage();
    await assertSucceeds(getBytes(ref(storage, voicePath(LEAVER))));
  });

  // ------------------------------------------------------------------
  // ЗАПРЕЩЕНО
  // ------------------------------------------------------------------

  // ПЕРЕПИСАН 15.09. ЗДЕСЬ СТОЯЛО ОБРАТНОЕ — «участник состава слушает
  // запись — тот же круг, что у поля», `assertSucceeds`, с подписью «этот
  // тест фиксирует решение, а не недосмотр».
  //
  // ПОДПИСЬ БЫЛА НЕВЕРНА. Решение владельца — «причину видит ТОЛЬКО
  // ВЛАДЕЛЕЦ», сказано 13.09 (`lib/core/agreements/leave_note.dart:116`) и
  // повторено 15.09. Прежний тест закреплял не решение владельца, а наше
  // собственное толкование правил хранилища — и потому противоречил тому,
  // что обещано человеку. Меняется вместе с правилом.
  //
  // Круг файла и круг поля теперь РАЗОШЛИСЬ нарочно: поле `leaveNotes` на
  // документе вечера читает весь состав (`isParty()` в `firestore.rules`),
  // файл — только владелец и сам вышедший.
  it("участник состава БОЛЬШЕ НЕ слушает чужую запись", async () => {
    await seedVoice();
    const storage = env.authenticatedContext(OTHER).storage();
    await assertFails(getBytes(ref(storage, voicePath(LEAVER))));
  });

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

  // ------------------------------------------------------------------
  // ПРЕДЕЛ РАЗМЕРА — ПАРА К ПОЧИНКЕ 14.09
  //
  // Починка подставляет умолчание там, где документа профиля нет. Отдельно
  // стоящий вопрос — НЕ ПРЕВРАТИЛАСЬ ЛИ ПОДСТАНОВКА В СНЯТИЕ ПРЕДЕЛА: «без
  // профиля пускаем» и «без профиля пускаем что угодно» на зелёном тесте
  // выше неотличимы (I14 — вывод один и тот же с обеих сторон).
  //
  // Поэтому пара: один тест держит потолок там, где профиля НЕТ, второй
  // доказывает, что при существующем профиле читается ПОЛЕ, а не константа.
  // Без второго первый прошёл бы и на правиле, где умолчание прибито
  // намертво и профиль не читается вовсе.
  // ------------------------------------------------------------------

  it("БЕЗ ПРОФИЛЯ предел всё равно действует — 105 МБ отклонены", async () => {
    // Профиля у LEAVER в этом окружении нет (beforeEach сеет только вечер) —
    // то есть ровно тот случай, ради которого заведено умолчание. 105 МБ
    // больше умолчания в 100 МБ = 104 857 600 байт.
    const tooBig = new Uint8Array(105 * 1024 * 1024);
    const storage = env.authenticatedContext(LEAVER).storage();
    await assertFails(
      uploadBytes(ref(storage, voicePath(LEAVER)), tooBig, voiceMeta(LEAVER)),
    );
  }, 180_000);

  it("предел берётся ИЗ ПРОФИЛЯ, а не из умолчания", async () => {
    // Профиль с нулевым потолком — тогда отказ получает даже запись в восемь
    // байт. Ноль вне [100, 2048], которые стережёт `firestore.rules`, и
    // кладётся он мимо правил нарочно: проверяется, что правило хранилища
    // ЧИТАЕТ поле, а не что такое значение бывает в проде.
    await env.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), `users/${LEAVER}`), {
        maxUploadSizeMb: 0,
      });
    });
    const storage = env.authenticatedContext(LEAVER).storage();
    await assertFails(
      uploadBytes(ref(storage, voicePath(LEAVER)), bytes, voiceMeta(LEAVER)),
    );
  });
});
