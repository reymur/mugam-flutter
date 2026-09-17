import { getStorage } from "firebase-admin/storage";
import { getAdminApp, db, clearFirestore, waitFor, BUCKET } from "./helpers";

// ЧТО ОСТАЁТСЯ ОТ УДАЛЁННОГО ВЕЧЕРА — `onPersonalEventDeleted` (17.09).
//
// Причины выхода с 17.09 — подколлекция `leaveNotes/{uid}`, а удаление
// документа подколлекций не удаляет (документация Firestore). Файлы голоса
// `event_leave_notes/{eventId}/{uid}` сиротели и до переноса. Уносит обоих
// сервер.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46; сверяется ПОИМЁННО):
//
//   1. ПЕРЕНЕСТИ вызов `removeLeaveNotesOfEvent` ПОСЛЕ раннего выхода «некого
//      известить» — «уборка идёт и у вечера без состава». ОДИН тест: у
//      остальных трёх вечер с составом, до уборки они доходят и так.
//
//   2. СНЯТЬ косую черту в конце префикса файлов — «удаление вечера НЕ трогает
//      файлы вечера с id-продолжением». ОДИН тест. «Уносит файлы причин»
//      остаётся зелёным: свои файлы префикс без черты тоже находит.
//
// Утверждение «соседа не тронули» — утверждение ОТСУТСТВИЯ (I31), и ждать его
// нечем: «ещё не удалили» и «не удалят» неотличимы. Поэтому сперва дожидаемся
// исчезновения СВОИХ файлов — это доказывает, что уборка отработала, — и лишь
// потом смотрим на соседа.

const OWNER = "owner-uid";
const LEAVER = "leaver-uid";
const OTHER = "other-uid";

function bucket() {
  return getStorage(getAdminApp()).bucket(BUCKET);
}

async function seedEvent(id: string, musicians: string[]) {
  const ref = db().collection("personalEvents").doc(id);
  await ref.set({
    ownerUid: OWNER,
    musicians,
    date: "2026-09-20T19:00:00.000",
    type: "Toy",
    location: "",
    notes: "",
    isAgree: false,
    status: "agreed",
  });
  return ref;
}

async function seedFile(filePath: string) {
  const file = bucket().file(filePath);
  await file.save(Buffer.from("voice bytes"), { contentType: "audio/mp4" });
  return file;
}

beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
});

test("удаление вечера уносит подколлекцию причин", async () => {
  const ref = await seedEvent("ev-cleanup-docs", [LEAVER, OTHER]);
  await ref.collection("leaveNotes").doc(LEAVER).set({ text: "səbəb" });
  await ref.collection("leaveNotes").doc(OTHER).set({ hasVoice: true });
  // Посеянное было на месте — иначе «пусто» ниже доказывало бы пустоту с
  // самого начала, а не работу уборки.
  expect((await ref.collection("leaveNotes").get()).size).toBe(2);

  await ref.delete();

  await waitFor(async () => (await ref.collection("leaveNotes").get()).empty);
  expect((await ref.collection("leaveNotes").get()).empty).toBe(true);
});

test("удаление вечера уносит файлы причин", async () => {
  const id = "ev-cleanup-files";
  const ref = await seedEvent(id, [LEAVER]);
  const file = await seedFile(`event_leave_notes/${id}/${LEAVER}`);
  expect((await file.exists())[0]).toBe(true);

  await ref.delete();

  await waitFor(async () => !(await file.exists())[0]);
  expect((await file.exists())[0]).toBe(false);
});

test("удаление вечера НЕ трогает файлы вечера с id-продолжением", async () => {
  // У вечеров серии id — продолжение id родителя. Префикс без косой черты
  // снёс бы их файлы вместе со своими.
  const id = "ev-series";
  const ref = await seedEvent(id, [LEAVER]);
  const own = await seedFile(`event_leave_notes/${id}/${LEAVER}`);
  const sibling = await seedFile(`event_leave_notes/${id}_2026-09-03/${LEAVER}`);

  await ref.delete();

  // Канарейка: своё исчезло — значит уборка отработала, и целость соседа ниже
  // что-то значит.
  await waitFor(async () => !(await own.exists())[0]);
  expect((await sibling.exists())[0]).toBe(true);
});

test("уборка идёт и у вечера без состава", async () => {
  // У вечера без состава извещать некого, и функция выходит рано. Уборка
  // обязана стоять ДО этого выхода: вопрос «кого известить» не отвечает на
  // вопрос «что осталось от вечера» (I34).
  const id = "ev-cleanup-empty";
  const ref = await seedEvent(id, []);
  await ref.collection("leaveNotes").doc(LEAVER).set({ text: "səbəb" });
  const file = await seedFile(`event_leave_notes/${id}/${LEAVER}`);

  await ref.delete();

  await waitFor(async () =>
    (await ref.collection("leaveNotes").get()).empty && !(await file.exists())[0],
  );
  expect((await ref.collection("leaveNotes").get()).empty).toBe(true);
  expect((await file.exists())[0]).toBe(false);
});
