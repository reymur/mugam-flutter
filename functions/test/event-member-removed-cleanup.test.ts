import { getStorage } from "firebase-admin/storage";
import { getAdminApp, db, clearFirestore, waitFor, BUCKET } from "./helpers";

// ГОЛОС УБРАННОГО ИЗ СОСТАВА УХОДИТ ВМЕСТЕ С НИМ — `onPersonalEventUpdated`, N244.
//
// Настоящий документ, настоящий триггер, настоящее хранилище эмулятора.
// Замер прода 17.09 до починки: крестик удалил документ причины, файл голоса
// остался сиротой с живым токеном.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46; сверяется ПОИМЁННО).
// Порчи в `functions/src/index.ts`; перед прогоном — сборка (четвёртые ворота).
//   4. подать в уборку ОСТАВШИХСЯ (`a.musicians`) вместо убранных —
//      «убранный из состава уносит свой файл голоса»,
//      «оставшийся в составе свой файл сохраняет» и
//      «уборка идёт, даже когда уведомлять некого». ТРИ.
//      **ЗДЕСЬ БЫЛО ПРЕДСКАЗАНО «ДВА», УПАЛО ТРИ (17.09, I46 — занижение).**
//      Не учтено: в третьем состав после крестика пуст, «оставшихся» нет, и
//      порча не удаляет ничего — файл убранного остаётся. Порча верная (меняет
//      одно), ошибалось предсказание. Файл оставлен в предсказании поимённо.
//   5. `bucket()` без имени —
//      «убранный из состава уносит свой файл голоса»,
//      «оставшийся в составе свой файл сохраняет» и
//      «уборка идёт, даже когда уведомлять некого». ТРИ: файлы в тестовом
//      бакете не удалятся. «Оставшийся сохраняет» падает НЕ проверкой своего
//      файла, а своей канарейкой — ждёт, что уйдёт файл убранного, и не
//      дожидается. Здесь сперва стояло «ДВА, оставшийся зелёный» — пересчитано
//      ДО прогона, после промаха порчи 4 (I46).
//   6. поставить уборку ПОСЛЕ `if (pushes.length === 0) return` —
//      ТОЛЬКО «уборка идёт, даже когда уведомлять некого». В двух первых
//      убранный с ответом `going` получает «Tədbirdən çıxarıldınız», план не
//      пуст, и до уборки функция доходит и после порчи.
//
// Утверждение «файл оставшегося цел» — ОТСУТСТВИЕ удаления (I31), и дождаться
// его нечем. Поэтому сперва ждём, что ушёл файл убранного, — это доказывает,
// что триггер отработал, — и лишь потом смотрим на оставшегося.

const OWNER = "owner-uid";
const A = "member-a";
const B = "member-b";

function bucket() {
  return getStorage(getAdminApp()).bucket(BUCKET);
}

async function seedFile(path: string) {
  const f = bucket().file(path);
  await f.save(Buffer.from("voice"), { contentType: "audio/mp4" });
  return f;
}

async function seedEvent(id: string, musicians: string[], answers: Record<string, string>) {
  const ref = db().collection("personalEvents").doc(id);
  await ref.set({
    ownerUid: OWNER,
    musicians,
    answers,
    answersWrittenByOwner: true,
    date: "2026-09-20T19:00:00.000",
    type: "Toy",
    location: "",
    notes: "",
    isAgree: false,
    status: "agreed",
    lastActionBy: OWNER,
    lastActionType: "created",
  });
  return ref;
}

beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
});

test("убранный из состава уносит свой файл голоса", async () => {
  const id = "ev-removed-a";
  const ref = await seedEvent(id, [A, B], { [A]: "going", [B]: "going" });
  const fileA = await seedFile(`event_leave_notes/${id}/${A}`);
  expect((await fileA.exists())[0]).toBe(true);

  await ref.update({
    musicians: [B],
    answers: { [B]: "going" },
    lastActionBy: OWNER,
    lastActionType: "edited",
  });

  await waitFor(async () => !(await fileA.exists())[0]);
  expect((await fileA.exists())[0]).toBe(false);
});

test("оставшийся в составе свой файл сохраняет", async () => {
  const id = "ev-removed-a-keeps-b";
  const ref = await seedEvent(id, [A, B], { [A]: "going", [B]: "going" });
  const fileA = await seedFile(`event_leave_notes/${id}/${A}`);
  const fileB = await seedFile(`event_leave_notes/${id}/${B}`);

  await ref.update({
    musicians: [B],
    answers: { [B]: "going" },
    lastActionBy: OWNER,
    lastActionType: "edited",
  });

  // Канарейка: файл убранного ушёл — триггер отработал.
  await waitFor(async () => !(await fileA.exists())[0]);
  expect((await fileB.exists())[0]).toBe(true);
});

test("уборка идёт, даже когда уведомлять некого", async () => {
  // Крестик по вышедшему: у него ответ `left`, письмо «вас убрали» ему не
  // шлётся, план пуст, и функция выходит рано. Именно у такого голос и есть.
  const id = "ev-removed-left";
  const ref = await seedEvent(id, [A], { [A]: "left" });
  const fileA = await seedFile(`event_leave_notes/${id}/${A}`);

  await ref.update({
    musicians: [],
    answers: {},
    lastActionBy: OWNER,
    lastActionType: "edited",
  });

  await waitFor(async () => !(await fileA.exists())[0]);
  expect((await fileA.exists())[0]).toBe(false);
});

test("эмулятор хранилища отвечает на удаление несуществующего кодом 404", async () => {
  // Допущение правила «404 — молча» проверено на настоящем клиенте хранилища,
  // а не взято из памяти (I50). Канарейка: существующий файл тем же вызовом
  // удаляется без отказа — значит отказ ниже про отсутствие, а не про доступ.
  const present = await seedFile("event_leave_notes/ev-404/present");
  await expect(present.delete()).resolves.toBeDefined();
  let code: unknown = null;
  try {
    await bucket().file("event_leave_notes/ev-404/absent").delete();
  } catch (e) {
    code = (e as { code?: unknown }).code;
  }
  expect(code).toBe(404);
});
