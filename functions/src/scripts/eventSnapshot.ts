// Снимок ОДНОГО мероприятия по всем двадцати известным ключам — ТОЛЬКО
// ЧТЕНИЕ.
//
// Зачем. Проверка правки на месте (N40) сверяет ПОСЛЕ хода с тем, что было
// ДО. «До» надо снять заранее: после хода снимать уже нечего. Печатается и
// то, чего в документе НЕТ, — отсутствие ключа не менее важно, чем
// значение: у пяти из семи договоров нет `jobOfferAt` (поле появилось с
// починкой N29), и якорь на таком документе проверял бы 11 полей из 13,
// выдавая два оставшихся за пройденные.
//
// Список ключей держится ровно тот же, что в чистом правиле
// `lib/core/agreements/event_edit.dart` (`kEventDocKeys`). Разойдутся —
// снимок начнёт молча пропускать поле, и «сверено всё» будет неправдой.
//
// --- Как запускать ---
//   из functions/:
//     npm run build
//     node lib/scripts/eventSnapshot.js <eventId>

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

initializeApp({ credential: applicationDefault(), projectId: "mugam-club" });
const db = getFirestore();

/** Те же 20 ключей, что перечислены в `kEventDocKeys` на клиенте. */
const KEYS = [
  "ownerUid",
  "date",
  "type",
  "location",
  "notes",
  "musicians",
  "isAgree",
  "agreementChatId",
  "partnerUid",
  "partnerName",
  "status",
  "jobOfferAt",
  "cancelRequestedBy",
  "cancelRequestedAt",
  "cancelConfirmedBy",
  "cancelledAt",
  "replacedEventId",
  "lastActionBy",
  "lastActionType",
  "createdAt",
];

function show(v: unknown): string {
  if (v && typeof (v as { toDate?: unknown }).toDate === "function") {
    return (v as { toDate: () => Date }).toDate().toISOString();
  }
  if (Array.isArray(v)) return `[${v.join(", ")}]`;
  return String(v);
}

async function main(): Promise<void> {
  const id = process.argv[2];
  if (!id) {
    console.error("нужен id: node lib/scripts/eventSnapshot.js <eventId>");
    process.exit(1);
  }
  const d = await db.collection("personalEvents").doc(id).get();
  if (!d.exists) {
    console.log(`personalEvents/${id}: ДОКУМЕНТА НЕТ`);
    return;
  }
  const v = d.data() as Record<string, unknown>;
  console.log(`personalEvents/${id}  — снято ${new Date().toISOString()}\n`);
  for (const k of KEYS) {
    const has = Object.prototype.hasOwnProperty.call(v, k);
    console.log(`  ${k.padEnd(20)} ${has ? show(v[k]) : "— ключа нет —"}`);
  }
  // Ключ, которого нет в списке, — либо новое поле, либо опечатка в
  // писателе. И то и другое надо увидеть, а не пропустить молча.
  const extra = Object.keys(v).filter((k) => !KEYS.includes(k));
  if (extra.length > 0) {
    console.log(`\n  ⚠ ключи СВЕРХ известных двадцати: ${extra.join(", ")}`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
