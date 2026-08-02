import { getStorage } from "firebase-admin/storage";
import { getAdminApp, db, clearFirestore, BUCKET } from "./helpers";
import { sweepOrphanMedia } from "../src/orphanSweep";

beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
  // Объекты эмулятор между тестами сам не чистит — иначе сирота из
  // предыдущего теста считалась бы находкой следующего.
  await getStorage(getAdminApp()).bucket(BUCKET).deleteFiles({ prefix: "" });
});

const HOUR = 3600000;
const DAY = 24 * HOUR;

function bucket() {
  return getStorage(getAdminApp()).bucket(BUCKET);
}

async function putObject(path: string): Promise<void> {
  await bucket().file(path).save(Buffer.from(`bytes for ${path}`), {
    contentType: "application/octet-stream",
  });
}

function downloadUrl(path: string): string {
  return (
    `https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o/` +
    `${encodeURIComponent(path)}?alt=media&token=abc`
  );
}

async function exists(path: string): Promise<boolean> {
  const [found] = await bucket().file(path).exists();
  return found;
}

// Объекты в эмуляторе создаются «сейчас», поэтому окно ожидания в тестах
// задаётся не возрастом файла, а сдвигом nowMs вперёд — так проверяется
// именно граница, а не выдержка паузы в тесте.
function sweep(opts: { dryRun?: boolean; aheadMs?: number; minAgeMs?: number } = {}) {
  return sweepOrphanMedia({
    db: db(),
    bucket: bucket(),
    dryRun: opts.dryRun ?? false,
    minAgeMs: opts.minAgeMs ?? DAY,
    nowMs: Date.now() + (opts.aheadMs ?? 2 * DAY),
  });
}

test("удаляет объект чата, на который не ссылается ни один документ", async () => {
  const orphan = "chats/C1/1700000000000_orphan.jpg";
  await putObject(orphan);
  // Живой документ, чтобы обход не был пустым — иначе сработал бы отказ
  // «0 документов», и тест прошёл бы по другой причине.
  await db().collection("chats").doc("C1").set({ members: ["A", "B"] });

  const result = await sweep();

  expect(result.orphans.map((o) => o.path)).toEqual([orphan]);
  expect(result.deleted).toBe(1);
  expect(await exists(orphan)).toBe(false);
});

test("не трогает объект, на который ссылается сообщение", async () => {
  const live = "chats/C1/1700000000000_live.jpg";
  await putObject(live);
  await db().collection("chats").doc("C1").set({ members: ["A", "B"] });
  await db().collection("chats").doc("C1").collection("messages").doc("m1").set({
    senderId: "A",
    type: "image",
    imageURL: downloadUrl(live),
    seq: 1,
  });

  const result = await sweep();

  expect(result.orphans).toEqual([]);
  expect(await exists(live)).toBe(true);
});

// Главный случай, ради которого множество ссылок глобальное:
// forwardMessage переиспользует URL исходного сообщения, поэтому объект
// чата A штатно держится сообщением чата B. Сборщик «по своему чату»
// снёс бы его у всех, кому переслали.
test("не трогает объект чата A, на который ссылается пересланное сообщение в чате B", async () => {
  const live = "chats/A/1700000000000_forwarded.jpg";
  await putObject(live);
  await db().collection("chats").doc("A").set({ members: ["u1", "u2"] });
  await db().collection("chats").doc("B").set({ members: ["u1", "u3"] });
  // В чате A исходное сообщение уже удалено начисто — единственная
  // оставшаяся ссылка живёт в другом чате.
  await db().collection("chats").doc("B").collection("messages").doc("m1").set({
    senderId: "u1",
    type: "image",
    imageURL: downloadUrl(live),
    forwardCount: 1,
    mediaOriginChatId: "A",
    mediaFileName: "1700000000000_forwarded.jpg",
    seq: 1,
  });

  const result = await sweep();

  expect(result.orphans).toEqual([]);
  expect(await exists(live)).toBe(true);
});

// Ссылка может лежать не в «главном» поле медиа, а в превью ответа —
// исходное сообщение удалено, а свайп-ответ на него продолжает
// показывать картинку. Перечисление известных полей эту ссылку бы
// потеряло; обход всех строк — нет.
test("не трогает объект, на который ссылается только replyTo-превью", async () => {
  const live = "chats/C1/1700000000000_replied.jpg";
  await putObject(live);
  await db().collection("chats").doc("C1").set({ members: ["A", "B"] });
  await db().collection("chats").doc("C1").collection("messages").doc("m2").set({
    senderId: "B",
    type: "text",
    text: "cavab",
    replyTo: { id: "m1", imageURL: downloadUrl(live) },
    seq: 2,
  });

  const result = await sweep();

  expect(result.orphans).toEqual([]);
  expect(await exists(live)).toBe(true);
});

test("не трогает медиа статуса, пока жив его документ, и удаляет, когда документа нет", async () => {
  const live = "statuses/U1/1700000000000_live.jpg";
  const orphan = "statuses/U1/1700000000000_orphan.jpg";
  await putObject(live);
  await putObject(orphan);
  await db().collection("users").doc("U1").set({ name: "U" });
  await db().collection("users").doc("U1").collection("statuses").doc("s1").set({
    ownerUid: "U1",
    type: "image",
    mediaUrl: downloadUrl(live),
    createdAt: new Date(),
    expiresAt: new Date(Date.now() + DAY),
    privacyMode: "contacts",
    privacyList: [],
  });

  const result = await sweep();

  expect(result.orphans.map((o) => o.path)).toEqual([orphan]);
  expect(await exists(live)).toBe(true);
  expect(await exists(orphan)).toBe(false);
});

test("не трогает объект моложе окна ожидания", async () => {
  const fresh = "chats/C1/1700000000000_fresh.jpg";
  await putObject(fresh);
  await db().collection("chats").doc("C1").set({ members: ["A", "B"] });

  const result = await sweep({ aheadMs: HOUR });

  expect(result.orphans).toEqual([]);
  expect(result.skippedTooYoung).toBe(1);
  expect(await exists(fresh)).toBe(true);
});

test("не трогает аватары, фото групп и вложенные пути mugam-v2", async () => {
  const untouched = [
    "avatars/U1.jpg",
    "groups/C1/avatar.jpg",
    "chats/C1/images/v2-nested.jpg",
    "chats/C1/voice/v2-nested.m4a",
  ];
  for (const path of untouched) await putObject(path);
  await db().collection("chats").doc("C1").set({ members: ["A", "B"] });

  const result = await sweep();

  expect(result.orphans).toEqual([]);
  for (const path of untouched) {
    expect(await exists(path)).toBe(true);
  }
});

test("режим отчёта находит сироту, но не удаляет её", async () => {
  const orphan = "chats/C1/1700000000000_orphan.jpg";
  await putObject(orphan);
  await db().collection("chats").doc("C1").set({ members: ["A", "B"] });

  const result = await sweep({ dryRun: true });

  expect(result.orphans.map((o) => o.path)).toEqual([orphan]);
  expect(result.deleted).toBe(0);
  expect(await exists(orphan)).toBe(true);
});

// Тот самый класс ошибки, по которому в проекте уже прошлись отдельно:
// пустой результат обхода — «не знаю», а не «ничего не ссылается».
// Здесь его цена максимальна: обход, упавший или обрезанный правами,
// выглядит ровно как «на всё в бакете ничто не ссылается».
test("при пустом обходе документов не удаляет ничего, хотя бакет не пуст", async () => {
  const path = "chats/C1/1700000000000_looks-orphaned.jpg";
  await putObject(path);
  // Ни одного документа в Firestore — clearFirestore в beforeEach.

  const result = await sweep();

  expect(result.scannedDocs).toBe(0);
  expect(result.orphans).toEqual([]);
  expect(result.deleted).toBe(0);
  expect(await exists(path)).toBe(true);
});

test("повторный прогон по вычищенному бакету ничего не находит и не падает", async () => {
  const orphan = "chats/C1/1700000000000_orphan.jpg";
  await putObject(orphan);
  await db().collection("chats").doc("C1").set({ members: ["A", "B"] });

  const first = await sweep();
  expect(first.deleted).toBe(1);

  const second = await sweep();
  expect(second.orphans).toEqual([]);
  expect(second.deleted).toBe(0);
});
