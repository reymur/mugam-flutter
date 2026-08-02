import { isWatchingChatDecision, PRESENCE_FRESH_MS } from "../src/presence";

// N19: решение «молчать вместо push» во всех сочетаниях старой и новой
// сборки. Цена ошибки здесь несимметрична и невидима — потерянный push не
// замечает никто, поэтому проверяются именно граничные случаи, а не
// счастливый путь.
//
// Прежнее правило было `activeUsers.includes(uid)`: отметка ставилась при
// входе на экран и снималась только в dispose, то есть при сворачивании,
// убийстве приложения или обрыве сети оставалась навсегда — и человек
// молча переставал получать уведомления об этом чате.

const NOW = 1_800_000_000_000;
const UID = "reader";
const CHAT = "chat-1";

function decide(over: Partial<Parameters<typeof isWatchingChatDecision>[0]>) {
  return isWatchingChatDecision({
    userData: {},
    chatId: CHAT,
    activeUsers: [],
    uid: UID,
    lastSeenMs: NOW,
    nowMs: NOW,
    ...over,
  });
}

describe("переходное окно: сборка без activeChatId", () => {
  test("документа пользователя нет вовсе — работает прежнее правило", () => {
    expect(decide({ userData: undefined, activeUsers: [UID] })).toBe(true);
    expect(decide({ userData: undefined, activeUsers: [] })).toBe(false);
  });

  test("ключа activeChatId нет — работает прежнее правило по activeUsers", () => {
    expect(decide({ userData: { name: "Ч" }, activeUsers: [UID] })).toBe(true);
    expect(decide({ userData: { name: "Ч" }, activeUsers: [] })).toBe(false);
  });

  test("старая сборка, сидящая в чате, push НЕ получает", () => {
    // Обратная сторона правки: пока человек не обновился, он не должен
    // начать получать уведомления о чате, который открыт у него на экране.
    expect(decide({ userData: { name: "Ч" }, activeUsers: [UID] })).toBe(true);
  });
});

describe("новая сборка: признак с сроком годности", () => {
  test("смотрит в этот чат, отметка свежая — молчим", () => {
    expect(decide({ userData: { activeChatId: CHAT } })).toBe(true);
  });

  test("смотрит в ДРУГОЙ чат — push нужен", () => {
    expect(decide({ userData: { activeChatId: "другой" } })).toBe(false);
  });

  test("вышел из чата (null) — push нужен", () => {
    expect(decide({ userData: { activeChatId: null } })).toBe(false);
  });

  test("застрявшая старая отметка больше не заглушает", () => {
    // Ровно случай, ради которого N19 заведён: activeUsers держит uid от
    // давнего визита, но новая сборка честно говорит, что чат другой.
    expect(
      decide({ userData: { activeChatId: "другой" }, activeUsers: [UID] }),
    ).toBe(false);
  });
});

describe("срок годности отметки", () => {
  test("чат тот, но приложение молчит дольше окна — push нужен", () => {
    expect(
      decide({
        userData: { activeChatId: CHAT },
        lastSeenMs: NOW - PRESENCE_FRESH_MS - 1,
      }),
    ).toBe(false);
  });

  test("на границе окна ещё молчим", () => {
    expect(
      decide({
        userData: { activeChatId: CHAT },
        lastSeenMs: NOW - PRESENCE_FRESH_MS + 1,
      }),
    ).toBe(true);
  });

  test("одно пропущенное сердцебиение не выталкивает наружу", () => {
    // Интервал 60 с, окно 120 с — один потерянный удар не должен
    // приводить к уведомлению у человека, который смотрит в экран.
    expect(
      decide({
        userData: { activeChatId: CHAT },
        lastSeenMs: NOW - 61_000,
      }),
    ).toBe(true);
  });

  test("lastSeen отсутствует — push нужен", () => {
    expect(
      decide({ userData: { activeChatId: CHAT }, lastSeenMs: null }),
    ).toBe(false);
  });
});
