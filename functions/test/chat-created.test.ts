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
/// ШУМНЫЙ СОСЕД ВМЕСТО ДВУХ СЕКУНД ПО ЧАСАМ (16.09).
///
/// **Чем плох был таймер.** «Подождали две секунды, поле не изменилось»
/// зелено и когда триггер верно промолчал, и когда он не запускался вовсе —
/// эмулятор не поднялся, функция не развернулась, очередь встала. Вывод при
/// поломке совпадает с выводом на исправном, то есть проверка не говорит
/// ничего (I14).
///
/// **Чем лучше сосед.** Заводится второй чат — заведомо ШУМНЫЙ, без
/// `lastMessageTime`, — и ждём, пока триггер допишет поле ЕМУ. Дождались —
/// значит машина триггеров жива и дошла до записи, сделанной ПОЗЖЕ той,
/// которую проверяем.
///
/// **ЧЕГО ЭТОТ ПРИЁМ НЕ ДАЁТ, И ЭТО НАДО ЗНАТЬ: он доказывает приход
/// СОСЕДА, а не молчание молчуна.** Порядок между разными документами
/// очередью не гарантирован, и под нагрузкой он инвертируется. Полной
/// местной починки у отрицания нет — нужна отметка «обработчик отработал и
/// решил не трогать», а `onChatCreated` при наличии поля выходит первой же
/// строкой и не пишет НИЧЕГО. Это долг **N239**, и эти два вердикта в нём
/// числятся.
///
/// **ПРАВКА ОБОСНОВАНА ЧТЕНИЕМ КОДА, А НЕ ВОСПРОИЗВЕДЁННЫМ ОТКАЗОМ:** эти
/// два вердикта 16.09 не падали ни разу. **N77 ею не закрывается.**
async function settleByNoisyNeighbour(): Promise<void> {
  const noisy = db().collection("chats").doc();
  await noisy.set({
    members: ["A", "B"],
    createdAt: new Date("2026-06-01T10:00:00Z"),
  });
  await waitFor(async () => {
    const snap = await noisy.get();
    return snap.data()?.lastMessageTime !== undefined;
  });
}

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

  await settleByNoisyNeighbour();

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

  await settleByNoisyNeighbour();

  const data = (await chatRef.get()).data()!;
  expect(data.lastMessageTime).toBeNull();
});
