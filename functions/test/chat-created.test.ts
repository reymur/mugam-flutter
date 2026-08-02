import { getAdminApp, db, clearFirestore, waitFor } from "./helpers";

beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
});

// Ровно тот случай, ради которого триггер и написан: mugam-v2 создаёт чат
// без lastMessageTime, а запрос списка чатов в mugam-flutter сортирует по
// этому полю — документ без поля Firestore из выдачи исключает, то есть
// чат исчез бы из списка целиком, а не встал не туда.
test("чат, созданный без lastMessageTime (форма mugam-v2), получает его из lastMessageAt", async () => {
  const chatRef = db().collection("chats").doc();
  const lastMessageAt = new Date("2026-07-01T10:00:00Z");
  await chatRef.set({
    members: ["A", "B"],
    isGroup: false,
    preview: "",
    completed: false,
    lastMessageAt,
    createdAt: new Date("2026-06-01T10:00:00Z"),
    unreadCount: {},
  });

  await waitFor(async () => {
    const snap = await chatRef.get();
    return snap.data()?.lastMessageTime !== undefined;
  });

  const data = (await chatRef.get()).data()!;
  expect(data.lastMessageTime.toDate()).toEqual(lastMessageAt);
});

test("при отсутствии lastMessageAt берётся createdAt", async () => {
  const chatRef = db().collection("chats").doc();
  const createdAt = new Date("2026-06-01T10:00:00Z");
  await chatRef.set({ members: ["A", "B"], createdAt });

  await waitFor(async () => {
    const snap = await chatRef.get();
    return snap.data()?.lastMessageTime !== undefined;
  });

  const data = (await chatRef.get()).data()!;
  expect(data.lastMessageTime.toDate()).toEqual(createdAt);
});

// Чат в форме mugam-flutter уже несёт поле — триггер обязан его не
// тронуть, иначе он бы переписывал время последнего сообщения временем
// создания на каждом новом чате.
test("существующее lastMessageTime не переписывается", async () => {
  const chatRef = db().collection("chats").doc();
  const lastMessageTime = new Date("2026-07-15T12:00:00Z");
  await chatRef.set({
    members: ["A", "B"],
    lastMessageAt: new Date("2026-07-01T10:00:00Z"),
    createdAt: new Date("2026-06-01T10:00:00Z"),
    lastMessageTime,
  });

  // Дать триггеру время сработать, если бы он собирался.
  await new Promise((resolve) => setTimeout(resolve, 2000));

  const data = (await chatRef.get()).data()!;
  expect(data.lastMessageTime.toDate()).toEqual(lastMessageTime);
});

// Явный null — это НЕ отсутствие поля: такой документ Firestore из
// выдачи orderBy не выбрасывает (null просто сортируется как наименьшее),
// и он штатно возникает, когда вся история чата удалена (B13). Триггер
// не должен принимать его за пропуск и подставлять время создания —
// иначе пустой чат всплывал бы в списке как свежий.
test("явный null не считается отсутствием поля", async () => {
  const chatRef = db().collection("chats").doc();
  await chatRef.set({
    members: ["A", "B"],
    createdAt: new Date("2026-06-01T10:00:00Z"),
    lastMessageTime: null,
  });

  await new Promise((resolve) => setTimeout(resolve, 2000));

  const data = (await chatRef.get()).data()!;
  expect(data.lastMessageTime).toBeNull();
});
