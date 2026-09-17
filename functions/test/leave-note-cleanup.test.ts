import { logger } from "firebase-functions";
import {
  leaveNoteVoiceObjectPath,
  removeLeaveNoteVoices,
  VoiceBucket,
} from "../src/leaveNoteCleanup";

// УДАЛЕНИЕ ГОЛОСА УБРАННОГО — ПРАВИЛО БЕЗ ЭМУЛЯТОРА (N244, 17.09).
//
// Подставная корзина отвечает на удаление тем кодом, который нужен, и так
// различение «файла нет» от «удалить не вышло» проверяется напрямую. Что
// настоящее хранилище отвечает именно 404 — отдельный вердикт с эмулятором
// (`event-member-removed-cleanup.test.ts`), здесь это допущение.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46; сверяется ПОИМЁННО):
//   1. снять строку `if (code === 404) return` —
//      «удаление несуществующего файла молчит — 404 в журнал не пишется». ОДИН.
//   2. снять вызов `logger.error` —
//      «сбой удаления, кроме 404, пишется в журнал». ОДИН.
//   3. дописать `throw e` после журнала —
//      «сбой удаления не выбрасывается наружу». ОДИН: вердикт о журнале
//      проглатывает отказ сам и остаётся зелёным.
//
// ЧЕГО НЕ ЛОВИТ: зовёт ли `onPersonalEventUpdated` это правило и с теми ли
// uid — это эмуляторный набор.

type Call = { path: string };

function bucketAnswering(code: number | null, calls: Call[] = []): VoiceBucket {
  return {
    file(path: string) {
      return {
        async delete() {
          calls.push({ path });
          if (code !== null) throw Object.assign(new Error(`code ${code}`), { code });
          return [{}];
        },
      };
    },
  };
}

let errorSpy: jest.SpyInstance;

beforeEach(() => {
  errorSpy = jest.spyOn(logger, "error").mockImplementation(() => undefined);
});

afterEach(() => {
  errorSpy.mockRestore();
});

test("удаление несуществующего файла молчит — 404 в журнал не пишется", async () => {
  // Убранный без причины — обычный случай: файла нет, хранилище отвечает 404.
  await removeLeaveNoteVoices(bucketAnswering(404), "ev1", ["u1"]);
  expect(errorSpy).not.toHaveBeenCalled();
});

test("сбой удаления, кроме 404, пишется в журнал", async () => {
  await removeLeaveNoteVoices(bucketAnswering(403), "ev1", ["u1"]).catch(() => undefined);
  expect(errorSpy).toHaveBeenCalledTimes(1);
  expect(String(errorSpy.mock.calls[0][0])).toContain("[member-removed]");
});

test("сбой удаления не выбрасывается наружу", async () => {
  // Уборка и извещение — разные дела: отказ уборки не должен оборвать рассылку.
  await expect(removeLeaveNoteVoices(bucketAnswering(500), "ev1", ["u1"])).resolves.toBeUndefined();
});

test("удаляется ровно путь event_leave_notes/{eventId}/{uid} каждого убранного", async () => {
  const calls: Call[] = [];
  await removeLeaveNoteVoices(bucketAnswering(null, calls), "ev1", ["a", "b"]);
  expect(calls.map((c) => c.path).sort()).toEqual([
    "event_leave_notes/ev1/a",
    "event_leave_notes/ev1/b",
  ]);
  // Путь — тот же, что у клиента (`leaveNoteVoicePath` в Dart).
  expect(leaveNoteVoiceObjectPath("ev1", "a")).toBe("event_leave_notes/ev1/a");
  expect(errorSpy).not.toHaveBeenCalled();
});
