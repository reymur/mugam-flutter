import assert from "node:assert";
import {
  DEAD_TOKEN_CODES,
  DEAD_TOKEN_MESSAGES,
  isDeadTokenError,
  pushErrorOf,
  summarize,
} from "../src/pushDelivery";

// N186 — ОБЕ ПОЛОВИНЫ, И ОНИ ПРОВЕРЯЮТСЯ ПОРОЗНЬ.
//
// Первая: мёртвый токен приходит кодом, которого нет в списке смертей.
// Вторая: отправка «прошла» при недоставленном письме.
//
// Порознь — потому что они лечат разное время: удаление токена лечит
// СЛЕДУЮЩИЙ раз, видимость отказа — ЭТОТ. Почини одну и сочти работу
// сделанной — и письмо по-прежнему не дойдёт, только тихо.

/** Исключение в той форме, в какой его кладёт FirebaseMessagingError. */
function fcmError(code: string, message: string): unknown {
  return { errorInfo: { code, message }, code, message };
}

describe("смерть токена опознаётся кодом ЛИБО текстом (N186)", () => {
  it("КАНАРЕЙКА: старые коды смерти по-прежнему опознаются", () => {
    // Утверждает НАЛИЧИЕ (I31) и потому сама себе сторож: сузься разбор до
    // пустоты — покраснеет здесь, а не в проде через месяц.
    assert.equal(DEAD_TOKEN_CODES.length, 2);
    for (const code of DEAD_TOKEN_CODES) {
      assert.equal(isDeadTokenError(fcmError(code, "что угодно")), true, code);
    }
  });

  it("НАСТОЯЩИЙ СЛУЧАЙ 29.08: invalid-argument про APNs — это смерть", () => {
    // Дословно из журнала прода, 03:52:26.865 UTC: код общий, а текст
    // называет виноватого.
    assert.equal(
      isDeadTokenError(
        fcmError("messaging/invalid-argument", "APNs device token is invalid"),
      ),
      true,
    );
  });

  it("регистр текста значения не имеет", () => {
    assert.equal(
      isDeadTokenError(
        fcmError("messaging/invalid-argument", "apns DEVICE token IS invalid"),
      ),
      true,
    );
  });

  // ГЛАВНОЕ ОТРИЦАНИЕ ВСЕЙ ПОЧИНКИ, И ОНО ЖЕ — ЦЕНА ОШИБКИ.
  //
  // Внеси `messaging/invalid-argument` в список кодов, и этот случай начнёт
  // читаться смертью: первая же наша ошибка в формате письма снесёт живые
  // токены ВСЕХ адресатов разом, молча и необратимо. Токенов в проде 5 у 4
  // человек (замер 29.08) — то есть всех.
  it("ТОТ ЖЕ КОД про кривую нагрузку — НЕ смерть", () => {
    const payloadErrors = [
      "Invalid JSON payload received",
      "data must only contain string values",
      "Request contains an invalid argument: apns.payload",
      "The value of field 'notification.body' is too long",
    ];
    for (const message of payloadErrors) {
      assert.equal(
        isDeadTokenError(fcmError("messaging/invalid-argument", message)),
        false,
        message,
      );
    }
  });

  it("посторонний код смертью не считается, что бы ни было в тексте", () => {
    // Текст про токен при ЧУЖОМ коде не открывает дорогу: разбор строки —
    // запасная дорога только для общего кода, а не общее правило.
    assert.equal(
      isDeadTokenError(
        fcmError("messaging/server-unavailable", "APNs device token is invalid"),
      ),
      false,
    );
    assert.equal(isDeadTokenError(fcmError("messaging/internal-error", "")), false);
  });

  it("пустое и мусорное исключение смертью не считается", () => {
    // Иначе сетевой сбой без кода стирал бы токены.
    assert.equal(isDeadTokenError(null), false);
    assert.equal(isDeadTokenError(undefined), false);
    assert.equal(isDeadTokenError(new Error("boom")), false);
    assert.equal(isDeadTokenError({}), false);
  });

  it("код и текст достаются из обеих форм, в каких их кладёт SDK", () => {
    assert.deepEqual(pushErrorOf({ errorInfo: { code: "a", message: "b" } }), {
      code: "a",
      message: "b",
    });
    assert.deepEqual(pushErrorOf({ code: "c", message: "d" }), {
      code: "c",
      message: "d",
    });
    assert.deepEqual(pushErrorOf(null), { code: "", message: "" });
  });

  it("КАНАРЕЙКА к списку текстов: он не пуст и каждый оборот про токен", () => {
    // Опустей список — все проверки текста выше зазеленели бы наоборот, а
    // отрицания остались бы зелёными как были. Ноль здесь неотличим от
    // порядка ничем, кроме этой строки.
    assert.ok(DEAD_TOKEN_MESSAGES.length > 0);
    for (const m of DEAD_TOKEN_MESSAGES) {
      assert.ok(
        m.includes("token"),
        `оборот «${m}» не называет токен — он не про получателя`,
      );
    }
  });
});

describe("недоставка видна в возврате, а не только в журнале (N186)", () => {
  it("свод по пачке: сколько ушло, сколько нет, сколько мёртвых", () => {
    assert.deepEqual(
      summarize([
        { ok: true },
        { ok: false, code: "messaging/invalid-argument", message: "x", tokenDead: true },
        { ok: false, code: "messaging/internal-error", message: "y", tokenDead: false },
      ]),
      { sent: 1, failed: 2, dead: 1 },
    );
  });

  it("всё ушло — отказов ноль", () => {
    assert.deepEqual(summarize([{ ok: true }, { ok: true }]), {
      sent: 2,
      failed: 0,
      dead: 0,
    });
  });

  it("ГЛАВНЫЙ СЛУЧАЙ: не ушло НИЧЕГО — sent ноль при непустой пачке", () => {
    // Именно это отличает «человек увидел на второй трубке» от «человек не
    // узнал ничего», и по этому различию `index.ts` выбирает error против
    // warn. Свести их в одно число значило бы потерять различие между
    // нормой и поломкой (I47).
    const s = summarize([
      { ok: false, code: "messaging/invalid-argument", message: "x", tokenDead: true },
      { ok: false, code: "messaging/invalid-argument", message: "x", tokenDead: true },
    ]);
    assert.equal(s.sent, 0);
    assert.equal(s.failed, 2);
    assert.equal(s.dead, 2);
  });

  it("пустая пачка отличима от полностью отказавшей", () => {
    // «Некому слать» и «никому не дошло» — два разных незнания, и сводить
    // их к одному ответу нельзя (I47). Здесь оба дают sent: 0, поэтому
    // различает их вызывающий по длине пачки — и это записано, чтобы
    // следующий не «упростил».
    assert.deepEqual(summarize([]), { sent: 0, failed: 0, dead: 0 });
  });
});
