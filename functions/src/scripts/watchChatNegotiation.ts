// Живой наблюдатель за переговорами «İş təklif et» в одном чате.
//
// Зачем: весь A-блок реестра (A1 — чистый прогон, A2 — «İmtina» без
// подтверждения, A3 — две функции на один документ) крутится вокруг
// одного и того же документа `chats/{chatId}` и его полей переговоров.
// Проверять их по экрану телефона недостаточно: экран показывает
// результат, а не то, какая запись дошла до сервера и в каком порядке —
// а именно это и было непонятно в A1, где «setJobOffer не долетал».
//
// Печатает только ИЗМЕНЕНИЯ полей, по одной строке на переход, с меткой
// времени — чтобы соотносить нажатия на телефоне с тем, что реально
// произошло в базе. Отдельно ловит появление новых документов в
// `personalEvents`: их создаёт onChatUpdated в ответ на согласие
// получателя, и это единственный способ увидеть снаружи, что серверная
// половина сценария отработала.
//
// В деплой не попадает: файл не импортируется из index.ts.
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/watchChatNegotiation.js <chatId>
//   Ctrl+C — остановить.
//
// Только чтение: скрипт ничего не пишет.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

// Поля переговоров ровно в том составе, в каком их пишут setJobOffer,
// saveChatEventDate, setWaitingForDate, acceptJobOffer, cancelChat и
// markNegotiationSeen (firestore_service.dart).
const FIELDS = [
  "jobOfferBy",
  "jobOfferAt",
  "eventDate",
  "eventType",
  "eventLocation",
  "eventNotes",
  "waitingForDateAt",
  "recipientAgreed",
  "recipientAgreedAt",
  "cancelledBy",
  "completed",
  "negotiationSeenAt",
] as const;

type Snapshot = Record<string, unknown>;

function format(value: unknown): string {
  if (value === undefined) return "—";
  if (value === null) return "null";
  const asTimestamp = value as { toDate?: () => Date };
  if (typeof asTimestamp?.toDate === "function") {
    return asTimestamp.toDate!().toISOString();
  }
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function stamp(): string {
  return new Date().toISOString().slice(11, 23);
}

async function main() {
  const chatId = process.argv[2];
  if (!chatId) {
    throw new Error("Укажите chatId: node lib/scripts/watchChatNegotiation.js <chatId>");
  }

  initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
  const db = getFirestore();

  console.log(`Слежу за chats/${chatId}. Ctrl+C — остановить.\n`);

  let previous: Snapshot | null = null;
  db.collection("chats")
    .doc(chatId)
    .onSnapshot(
      (snap) => {
        const data = snap.data() ?? {};
        const current: Snapshot = {};
        for (const field of FIELDS) current[field] = data[field];

        if (previous === null) {
          console.log(`[${stamp()}] ИСХОДНОЕ СОСТОЯНИЕ`);
          const filled = FIELDS.filter(
            (f) => current[f] !== undefined && current[f] !== null,
          );
          if (filled.length === 0) {
            console.log("    (все поля переговоров пусты)");
          } else {
            for (const f of filled) console.log(`    ${f} = ${format(current[f])}`);
          }
        } else {
          const changed = FIELDS.filter(
            (f) => format(previous![f]) !== format(current[f]),
          );
          if (changed.length > 0) {
            console.log(`[${stamp()}] ИЗМЕНЕНИЕ (${changed.length} полей)`);
            for (const f of changed) {
              console.log(`    ${f}: ${format(previous![f])}  ->  ${format(current[f])}`);
            }
          }
        }
        previous = current;
      },
      (e) => console.error("Слушатель чата упал:", e),
    );

  // Первый снимок коллекции приходит целиком — он не событие, а фон.
  let firstEventsSnapshot = true;
  db.collection("personalEvents").onSnapshot(
    (snap) => {
      if (firstEventsSnapshot) {
        firstEventsSnapshot = false;
        console.log(`    (в проде уже ${snap.size} договоров — слежу только за новыми)`);
        return;
      }
      for (const change of snap.docChanges()) {
        if (change.type !== "added") continue;
        const d = change.doc.data();
        console.log(
          `[${stamp()}] СОЗДАН personalEvent ${change.doc.id}: ` +
            `type=${d.type} date=${format(d.date)} status=${d.status} owner=${d.ownerUid}`,
        );
      }
    },
    (e) => console.error("Слушатель договоров упал:", e),
  );
}

main().catch((e) => {
  console.error("Наблюдатель не запустился:", e);
  process.exit(1);
});
