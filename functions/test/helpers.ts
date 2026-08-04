import * as admin from "firebase-admin";

// A "demo-*" project id tells the Admin/client SDKs and the emulators
// themselves that this is a fully offline test project — no real GCP
// project or credentials are ever touched by this suite.
export const PROJECT_ID = "demo-mugam-test";
export const BUCKET = "mugam-club.firebasestorage.app";
export const FIRESTORE_EMULATOR_PORT = 8080;

let app: admin.app.App | undefined;

// firebase emulators:exec injects FIRESTORE_EMULATOR_HOST /
// FIREBASE_STORAGE_EMULATOR_HOST into this process's env automatically —
// no explicit host/port wiring needed here.
//
// admin.apps.length check added for copy-status-media-to-chat.test.ts,
// the first test to import a function straight from ../src/index —
// that module's own top-level initializeApp() (firebase-admin/app, no
// args) runs at import time, before this function ever gets called, so
// calling admin.initializeApp() unconditionally a second time here would
// throw "the default Firebase app already exists". The modular
// (firebase-admin/app) and namespaced (firebase-admin) APIs share the
// same underlying app registry in the Admin SDK, so admin.app() reuses
// that same app correctly rather than needing a second one.
export function getAdminApp(): admin.app.App {
  if (!app) {
    app = admin.apps.length > 0
      ? admin.app()
      : admin.initializeApp({ projectId: PROJECT_ID, storageBucket: BUCKET });
  }
  return app;
}

export function db(): admin.firestore.Firestore {
  return getAdminApp().firestore();
}

export async function clearFirestore(): Promise<void> {
  const res = await fetch(
    `http://localhost:${FIRESTORE_EMULATOR_PORT}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: "DELETE" },
  );
  if (!res.ok) {
    throw new Error(`clearFirestore failed: ${res.status} ${await res.text()}`);
  }
}

export async function docExists(path: string): Promise<boolean> {
  const snap = await db().doc(path).get();
  return snap.exists;
}

// Порог ожидания триггера — 15 с, и это не круглое число, а замер (N18).
//
// Три полных прогона 04.08: самое долгое ОДНО ожидание — 6.2 с (6201 мс и
// 6144 мс в двух зелёных прогонах, профиль устойчив: ровно 5 ожиданий
// дольше 3 с). Прежние 10 с давали запас всего 1.6×, и прогон, где рантайм
// функций перезапускался 51 раз вместо обычных 23, этот запас съедал.
//
// 15 с — 2.4× от измеренного потолка и при этом заведомо МЕНЬШЕ потолка
// jest (`testTimeout: 20000`, jest.config.js). Верхняя граница здесь не
// вкусовая: перевалив за неё, ожидание убивал бы сам jest, и вместо
// «waitFor: condition not met» в отчёте стояло бы безымянное «Exceeded
// timeout», не называющее причину вовсе.
//
// Поднимать порог, не печатая фактическое ожидание, нельзя: это спрятало
// бы настоящее замедление вместо того, чтобы его показать. Поэтому ниже
// печатается всё, что ждало дольше 3 с, — порог ограничивает только отказ,
// а печать держит хвост на виду.
const DEFAULT_TIMEOUT_MS = 15000;

// Cloud Functions triggers fire asynchronously in response to emulated
// Firestore/Storage writes — there's no way to await "the trigger finished"
// directly from the client side, so every assertion on a trigger's side
// effect polls until it observes the expected state (or times out and
// fails loudly, which is a real failure: either the trigger has a bug or
// it never ran within a generous margin).
export async function waitFor(
  check: () => Promise<boolean>,
  opts: { timeoutMs?: number; intervalMs?: number } = {},
): Promise<void> {
  const envTimeout = Number(process.env.WAITFOR_TIMEOUT_MS ?? "");
  const timeoutMs = opts.timeoutMs ?? (envTimeout > 0 ? envTimeout : DEFAULT_TIMEOUT_MS);
  const intervalMs = opts.intervalMs ?? 250;
  const started = Date.now();
  const deadline = started + timeoutMs;
  for (;;) {
    if (await check()) {
      const waited = Date.now() - started;
      if (waited > 3000) {
        console.log(`[waitFor] ждал ${waited}ms (порог ${timeoutMs}ms)`);
      }
      return;
    }
    if (Date.now() >= deadline) {
      throw new Error(`waitFor: condition not met within ${timeoutMs}ms`);
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}
