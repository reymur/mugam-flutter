import fs from "fs";
import path from "path";
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
  writeBatch,
} from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// ПРИЧИНА ВЫХОДА — СВОЙ ДОКУМЕНТ `personalEvents/{id}/leaveNotes/{uid}` (17.09).
//
// До 17.09 причина была полем `leaveNotes.<uid>` документа вечера, и этот
// набор проверял ход `leavesWithNote()`. Главного он проверить не мог — ЧТЕНИЕ:
// поле читал весь состав. Теперь чтение — первая половина файла.
//
// ПАРНО: у каждого `assertSucceeds` свои `assertFails`, и запреты — главная
// половина. Набор из одних разрешений не отличит правило от пускающего всё.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46; сверяется ПОИМЁННО):
//
//   1. СНЯТЬ условие `leaveEventAfter()...answers... == 'left'` целиком —
//      «НЕЛЬЗЯ оставить причину, не выходя — ответ после пачки не left» и
//      «НЕЛЬЗЯ причину отдельной записью, не выходя вовсе». ДВА теста.
//      Остальные зелены: разрешения не зависят от снятого, прочие запреты
//      держатся своими условиями.
//
//   2. ЗАМЕНИТЬ `getAfter` НА `get` в `leaveEventAfter()` — «выход с причиной
//      текстом — ответ left и документ причины одной пачкой» и «выход с
//      причиной голосом — hasVoice и волна». ДВА теста: `get` видит ответ ДО
//      пачки (`going`), и законный выход отклоняется. Запреты «не выходя»
//      остаются зелёными — отказ им даёт и `get`. «Вышедший заменяет свою
//      причину позже» тоже зелёный: у него `left` уже в базе. Пара порч 1 и 2
//      и различает «условия нет» от «условие смотрит не туда».
//
//   3. В `allow read` ЗАМЕНИТЬ ветвь владельца на `request.auth.uid in
//      leaveEvent().get('musicians', [])` — «участник того же вечера НЕ читает
//      чужую причину» и «участник НЕ получает причины вечера запросом», плюс
//      «владелец читает причину участника» и «владелец получает все причины
//      вечера одним запросом». ЧЕТЫРЕ теста. Это сама дыра, которую перенос
//      закрывает.
//
// ЧЕГО НЕ ЛОВИТ: дошла ли пачка с трубки (это проба), и удаляет ли сервер
// подколлекцию при удалении вечера (`event-deleted-cleanup.test.ts`).

const OWNER = "owner-uid";
const LEAVER = "leaver-uid";
const OTHER = "other-uid";
const STRANGER = "stranger-uid";
const EVENT = "ev-leave-notes";

const eventPath = `personalEvents/${EVENT}`;
const notePath = (uid: string) => `${eventPath}/leaveNotes/${uid}`;

async function seed(env: RulesTestEnvironment) {
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, eventPath), {
      ownerUid: OWNER,
      musicians: [LEAVER, OTHER],
      date: "2026-09-20T19:00:00.000",
      type: "Toy",
      location: "",
      notes: "",
      isAgree: false,
      status: "agreed",
      answers: { [LEAVER]: "going", [OTHER]: "left" },
    });
    // Причина уже вышедшего участника — предмет всех проверок чтения.
    await setDoc(doc(db, notePath(OTHER)), { text: "Toyum var o gün" });
  });
}

describe("17.09: причина выхода — свой документ, читают автор и владелец", () => {
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
  // ЧТЕНИЕ
  // ------------------------------------------------------------------

  it("автор читает свою причину", async () => {
    const db = env.authenticatedContext(OTHER).firestore();
    await assertSucceeds(getDoc(doc(db, notePath(OTHER))));
  });

  it("владелец вечера читает причину участника", async () => {
    const db = env.authenticatedContext(OWNER).firestore();
    await assertSucceeds(getDoc(doc(db, notePath(OTHER))));
  });

  it("участник того же вечера НЕ читает чужую причину", async () => {
    // САМА ДЫРА, ради которой перенос. До 17.09 это чтение проходило: поле
    // лежало в документе вечера, а его читает весь состав.
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(getDoc(doc(db, notePath(OTHER))));
  });

  it("посторонний НЕ читает причину", async () => {
    const db = env.authenticatedContext(STRANGER).firestore();
    await assertFails(getDoc(doc(db, notePath(OTHER))));
  });

  it("владелец получает все причины вечера одним запросом", async () => {
    const db = env.authenticatedContext(OWNER).firestore();
    const snap = await assertSucceeds(getDocs(collection(db, `${eventPath}/leaveNotes`)));
    // Число названо, а не «что-то пришло»: запрос обязан вернуть именно
    // посеянную причину, иначе успех доказывал бы пустую подколлекцию.
    expect(snap.docs.map((d) => d.id)).toEqual([OTHER]);
  });

  it("участник НЕ получает причины вечера запросом", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(getDocs(collection(db, `${eventPath}/leaveNotes`)));
  });

  // ------------------------------------------------------------------
  // ЗАПИСЬ — РАЗРЕШЕНО
  // ------------------------------------------------------------------

  it("выход с причиной текстом — ответ left и документ причины одной пачкой", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    const batch = writeBatch(db);
    batch.update(doc(db, eventPath), { [`answers.${LEAVER}`]: "left" });
    batch.set(doc(db, notePath(LEAVER)), { text: "Maşın xarab oldu" });
    await assertSucceeds(batch.commit());
  });

  it("выход с причиной голосом — hasVoice и волна", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    const batch = writeBatch(db);
    batch.update(doc(db, eventPath), { [`answers.${LEAVER}`]: "left" });
    batch.set(doc(db, notePath(LEAVER)), { hasVoice: true, voiceWaveform: [3, 50, 100] });
    await assertSucceeds(batch.commit());
  });

  it("выход без причины проходит по-прежнему", async () => {
    // Канарейка к снятию `leavesWithNote()`: выход без причины идёт старым
    // `answersForSelf` и сломаться от переноса не должен.
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertSucceeds(updateDoc(doc(db, eventPath), { [`answers.${LEAVER}`]: "left" }));
  });

  it("вышедший заменяет свою причину позже отдельной записью", async () => {
    // У OTHER ответ `left` уже в базе — `getAfter` без пачки видит его же.
    const db = env.authenticatedContext(OTHER).firestore();
    await assertSucceeds(setDoc(doc(db, notePath(OTHER)), { text: "Başqa səbəb" }));
  });

  // ------------------------------------------------------------------
  // ЗАПИСЬ — ЗАПРЕЩЕНО
  // ------------------------------------------------------------------

  it("НЕЛЬЗЯ оставить причину, не выходя — ответ после пачки не left", async () => {
    // Причина говорится про уход. «Не могу» с приписанной причиной — слова об
    // уходе, которого не было.
    const db = env.authenticatedContext(LEAVER).firestore();
    const batch = writeBatch(db);
    batch.update(doc(db, eventPath), { [`answers.${LEAVER}`]: "cant" });
    batch.set(doc(db, notePath(LEAVER)), { text: "səbəb" });
    await assertFails(batch.commit());
  });

  it("НЕЛЬЗЯ причину отдельной записью, не выходя вовсе", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(setDoc(doc(db, notePath(LEAVER)), { text: "səbəb" }));
  });

  it("НЕЛЬЗЯ оставить причину за другого", async () => {
    // У OTHER ответ `left` — отказ обязан прийти от «документ не твой», а не
    // от «человек не вышел».
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(setDoc(doc(db, notePath(OTHER)), { text: "o da gəlmir" }));
  });

  it("НЕЛЬЗЯ лишнее поле в причине", async () => {
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(
      setDoc(doc(db, notePath(OTHER)), { text: "səbəb", lastActionType: "cancelled" }),
    );
  });

  it("НЕЛЬЗЯ voiceUrl в причине", async () => {
    // N236, шаг 3 — явным вердиктом. Ссылка с токеном открывает файл без
    // входа; вернуть её в данные не должна никакая рука.
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(
      setDoc(doc(db, notePath(OTHER)), { voiceUrl: "https://example/v?token=x" }),
    );
  });

  it("НЕЛЬЗЯ hasVoice: false", async () => {
    // Прибито ЗНАЧЕНИЕ, а не тип: `false` значило бы то же, что отсутствие
    // ключа, и два написания одного смысла разъезжаются молча (I47).
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(setDoc(doc(db, notePath(OTHER)), { hasVoice: false }));
  });

  it("НЕЛЬЗЯ hasVoice строкой", async () => {
    // Порознь с тестом выше различают `is bool` (пустит false, но не строку)
    // от снятого условия (пустит оба).
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(setDoc(doc(db, notePath(OTHER)), { hasVoice: "true" }));
  });

  it("НЕЛЬЗЯ причину в вечере, где тебя нет в составе", async () => {
    const db = env.authenticatedContext(STRANGER).firestore();
    await assertFails(setDoc(doc(db, notePath(STRANGER)), { text: "səbəb" }));
  });

  it("НЕЛЬЗЯ владельцу оставить причину в своём вечере", async () => {
    // Владелец вечер создал, а не согласился (N112): уходить ему не из чего.
    await env.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), eventPath), {
        musicians: [LEAVER, OTHER, OWNER],
        [`answers.${OWNER}`]: "left",
      });
    });
    const db = env.authenticatedContext(OWNER).firestore();
    await assertFails(setDoc(doc(db, notePath(OWNER)), { text: "səbəb" }));
  });

  it("НЕЛЬЗЯ записать поле leaveNotes в документ вечера", async () => {
    // Снятый ход `leavesWithNote()`: поле больше не пишется никем из
    // участников, иначе дыра вернулась бы старой дорогой.
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(
      updateDoc(doc(db, eventPath), {
        [`answers.${LEAVER}`]: "left",
        [`leaveNotes.${LEAVER}`]: { text: "səbəb" },
      }),
    );
  });

  // ------------------------------------------------------------------
  // УДАЛЕНИЕ
  // ------------------------------------------------------------------

  it("владелец удаляет причину убранного из состава", async () => {
    // Крестик: правка состава и удаление причины одной пачкой.
    const db = env.authenticatedContext(OWNER).firestore();
    const batch = writeBatch(db);
    batch.update(doc(db, eventPath), { musicians: [LEAVER], answers: { [LEAVER]: "going" } });
    batch.delete(doc(db, notePath(OTHER)));
    await assertSucceeds(batch.commit());
  });

  it("НЕЛЬЗЯ участнику удалить чужую причину", async () => {
    const db = env.authenticatedContext(LEAVER).firestore();
    await assertFails(deleteDoc(doc(db, notePath(OTHER))));
  });

  it("НЕЛЬЗЯ автору удалить свою причину", async () => {
    // Решение владельца 17.09: «приложение помнит, но не судит; человек
    // сказал, почему не может, стирать это задним числом незачем».
    const db = env.authenticatedContext(OTHER).firestore();
    await assertFails(deleteDoc(doc(db, notePath(OTHER))));
  });

  // ------------------------------------------------------------------
  // ВЫХОД ИЗ ОЖИДАНИЯ — предусловие к снятию «Bacarmıram» (17.09)
  // ------------------------------------------------------------------
  // ЗАЧЕМ ОТДЕЛЬНЫЙ ВЕРДИКТ, ЕСЛИ ВЫХОД УЖЕ ПРОВЕРЕН ВЫШЕ. Тот проверяет
  // выход из `going`: посев кладёт `LEAVER: "going"`. Владелец снимает
  // «Bacarmıram» и оставляет один способ отказаться — «Gələ bilmirəm», и
  // нажимать его будет человек, которого ТОЛЬКО ЧТО ПОЗВАЛИ, то есть с
  // ответом `waiting`. Это другой вход, и «там же правило» — рассуждение, а
  // не замер.
  //
  // ПРОВЕРЯЕТСЯ ДО СНЯТИЯ НАРОЧНО (требование владельца): откажи правила —
  // и работа пойдёт иначе, а узнать это надо раньше, чем у человека не
  // останется ни одной кнопки отказа.
  describe("выход с причиной ИЗ ОЖИДАНИЯ", () => {
    async function seedWaiting() {
      await env.withSecurityRulesDisabled(async (context) => {
        await updateDoc(doc(context.firestore(), eventPath), {
          [`answers.${LEAVER}`]: "waiting",
        });
      });
    }

    it("позванный, ещё не ответивший, выходит с причиной одной пачкой", async () => {
      await seedWaiting();
      const db = env.authenticatedContext(LEAVER).firestore();
      const batch = writeBatch(db);
      batch.update(doc(db, eventPath), { [`answers.${LEAVER}`]: "left" });
      batch.set(doc(db, notePath(LEAVER)), { text: "Başqa iş çıxdı" });
      await assertSucceeds(batch.commit());
    });

    it("он же выходит с причиной ГОЛОСОМ", async () => {
      await seedWaiting();
      const db = env.authenticatedContext(LEAVER).firestore();
      const batch = writeBatch(db);
      batch.update(doc(db, eventPath), { [`answers.${LEAVER}`]: "left" });
      batch.set(doc(db, notePath(LEAVER)), {
        hasVoice: true,
        voiceWaveform: [1, 2, 3],
      });
      await assertSucceeds(batch.commit());
    });

    it("он же выходит БЕЗ причины", async () => {
      // Причина необязательна — окно её предлагает, а не требует.
      await seedWaiting();
      const db = env.authenticatedContext(LEAVER).firestore();
      await assertSucceeds(
        updateDoc(doc(db, eventPath), { [`answers.${LEAVER}`]: "left" }),
      );
    });

    it("ЗАПРЕТ: из ожидания тоже нельзя оставить причину, НЕ выходя", async () => {
      // Пара к трём разрешениям выше. Без неё «из ожидания можно» не
      // отличить от «из ожидания можно всё».
      await seedWaiting();
      const db = env.authenticatedContext(LEAVER).firestore();
      const batch = writeBatch(db);
      batch.update(doc(db, eventPath), { [`answers.${LEAVER}`]: "going" });
      batch.set(doc(db, notePath(LEAVER)), { text: "передумал" });
      await assertFails(batch.commit());
    });
  });
});
