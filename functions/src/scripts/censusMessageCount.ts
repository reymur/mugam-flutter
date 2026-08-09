// Перепись: сходится ли `messageCount` на документе чата с тем, сколько
// сообщений там на самом деле лежит.
//
// ПОВОД И СРОЧНОСТЬ — те же, что у `censusLostAgreements`. С 09.08 17:16
// UTC Cloud Functions не выполняются (N102), а `messageCount` ведёт
// ТОЛЬКО сервер: `onNewMessage` прибавляет единицу на каждое созданное
// сообщение, `onMessageDeleted` отнимает на каждое удалённое. Пропущенное
// не догоняется ничем: пути пересчёта в проекте нет вовсе, и счётчик,
// отставший на время простоя, останется отставшим НАВСЕГДА.
//
// ПОЧЕМУ СНИМАТЬ ДО ВОССТАНОВЛЕНИЯ. События лежат в очереди Pub/Sub с
// удержанием 86400 с; часть их доедет задним числом и досчитает счётчик
// сама. После этого «доехало» и «не отставало» станут неотличимы. Снимок,
// сделанный сейчас, — единственное, с чем можно будет сравнить.
//
// ЧТО ИМЕННО СЧИТАЕТСЯ. `messageCount` — это «сколько сообщений
// СУЩЕСТВУЕТ сейчас», а не «сколько было отправлено за всё время».
// Удаление «у всех» (`Hamıdan sil`) документ не убирает, а ПРАВИТ
// (`deletedForAll: true`), и `onMessageDeleted` его не видит — значит
// такие сообщения в счёт входят и должны входить. Здесь считается то же
// самое: количество документов в подколлекции, без разбора их состояния.
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/censusMessageCount.js
//
// Только чтение: скрипт ничего не пишет и ничего не удаляет.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

/** Час, с которого функции перестали выполняться (N102). */
const OUTAGE_START_ISO = "2026-08-09T17:16:00Z";

interface Row {
  chatId: string;
  stored: number | null;
  actual: number;
  drift: number;
  sinceOutage: number;
  noTimestamp: number;
}

function pad(v: string | number, n: number): string {
  return String(v).padStart(n);
}

async function main(): Promise<void> {
  initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
  const db = getFirestore();

  const outageMs = Date.parse(OUTAGE_START_ISO);
  const chatsSnap = await db.collection("chats").get();

  const rows: Row[] = [];
  let fieldPresent = 0;
  let fieldMissing = 0;
  let totalMessages = 0;

  for (const chatDoc of chatsSnap.docs) {
    const raw = chatDoc.data().messageCount;
    const stored = typeof raw === "number" ? raw : null;
    if (stored === null) fieldMissing += 1;
    else fieldPresent += 1;

    const msgs = await chatDoc.ref.collection("messages").get();
    totalMessages += msgs.size;

    let sinceOutage = 0;
    let noTimestamp = 0;
    msgs.docs.forEach((m) => {
      const ts = m.data().timestamp;
      const ms = ts && typeof ts.toMillis === "function" ? ts.toMillis() : null;
      if (ms === null) {
        noTimestamp += 1;
        return;
      }
      if (ms >= outageMs) sinceOutage += 1;
    });

    rows.push({
      chatId: chatDoc.id,
      stored,
      actual: msgs.size,
      drift: msgs.size - (stored ?? 0),
      sinceOutage,
      noTimestamp,
    });
  }

  const drifted = rows.filter((r) => r.drift !== 0);
  const totalDrift = rows.reduce((s, r) => s + r.drift, 0);
  const totalSinceOutage = rows.reduce((s, r) => s + r.sinceOutage, 0);
  const totalNoTimestamp = rows.reduce((s, r) => s + r.noTimestamp, 0);

  console.log(`Снято: ${new Date().toISOString()}`);
  console.log(`Простой считается с: ${OUTAGE_START_ISO} (N102)`);
  console.log("");
  console.log(`Чатов:                              ${chatsSnap.size}`);
  console.log(`Сообщений всего (документов):        ${totalMessages}`);
  console.log(`Чатов, где счётчик РАСХОДИТСЯ:      ${drifted.length}`);
  console.log(`Суммарное расхождение:              ${totalDrift > 0 ? "+" : ""}${totalDrift}`);
  console.log(`Сообщений с начала простоя:         ${totalSinceOutage}`);

  console.log("");
  console.log("--- канарейки: разбор видит данные? ---");
  console.log(`  чатов с полем messageCount:       ${fieldPresent}`);
  console.log(`  чатов БЕЗ поля messageCount:      ${fieldMissing}`);
  console.log(`  сообщений без отметки времени:    ${totalNoTimestamp}`);
  if (totalMessages === 0) {
    console.log("");
    console.log("  ВНИМАНИЕ: сообщений не нашлось ни одного. Ноль расхождений");
    console.log("  выше ничего не значит — разбор не видит подколлекцию вовсе.");
  }

  console.log("");
  console.log("--- по чатам (все, а не только расходящиеся) ---");
  console.log("   счётчик   на деле   расхожд.  с простоя   чат");
  rows
    .sort((a, b) => Math.abs(b.drift) - Math.abs(a.drift))
    .forEach((r) => {
      const stored = r.stored === null ? "(нет)" : String(r.stored);
      const drift = r.drift === 0 ? "0" : `${r.drift > 0 ? "+" : ""}${r.drift}`;
      console.log(
        `  ${pad(stored, 8)}  ${pad(r.actual, 8)}  ${pad(drift, 9)}  ${pad(r.sinceOutage, 9)}   ${r.chatId}`
      );
    });

  // ═══════════════════════════════════════════════════════════════════
  // ЧТО ЭТОТ СЧЁТ НЕ ЗНАЧИТ — печатается всегда, как и у сверки
  // договоров: читают вывод, а не исходник.
  // ═══════════════════════════════════════════════════════════════════
  console.log("");
  console.log("═══ ЧТО ЭТОТ СЧЁТ НЕ ЗНАЧИТ ═══");
  console.log("");
  console.log("1. Расхождение НЕ равно потерям простоя. Счётчик заведён позже");
  console.log("   самих чатов, и всё, что написано до него, в нём не учтено —");
  console.log("   это старый долг, а не сегодняшняя потеря. Разделяет их только");
  console.log("   столбец «с простоя»: сообщения с отметкой времени ПОСЛЕ");
  console.log(`   ${OUTAGE_START_ISO}. Где расхождение примерно равно ему —`);
  console.log("   это простой; где больше — разница накопилась раньше.");
  console.log("");
  console.log("2. Отметка времени сообщения ставится КЛИЕНТОМ и бывает пустой");
  console.log("   до подтверждения сервером. Сообщения без неё в столбец");
  console.log("   «с простоя» не попадают вовсе — их число напечатано выше");
  console.log("   отдельно, и на столько же счёт простоя может быть занижен.");
  console.log("");
  console.log("3. Счётчик чинится ТОЛЬКО пересчётом, и пересчёта в проекте нет.");
  console.log("   Само ничто не сойдётся: ни открытие чата, ни новое сообщение");
  console.log("   отставания не убирают — они прибавляют к уже неверному числу.");
  console.log("");
  console.log("4. Цена ошибки НЕ в самом числе: `messageCount` виден человеку");
  console.log("   ровно в одном месте — порядок «часто пишу» в листе пересылки");
  console.log("   (forward_sheet, топ-5 по убыванию). Ошибка сдвигает порядок,");
  console.log("   а не показывает неверную цифру на экране.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
