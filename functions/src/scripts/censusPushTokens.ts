// Перепись адресов доставки push — кто, сколько, когда обновлён.
//
// Заведена 01.09 перед проверкой хвоста N186: прежде чем будить телефон
// отправкой, надо назвать ЗНАМЕНАТЕЛЬ и выбрать адресата глазами, а не по
// памяти. Замер 29.08 говорил «5 токенов у 4 человек, доказанно мёртв
// один»; с тех пор трубки пересобраны дважды, значит число заведомо
// другое, и брать старое было бы числом без прохода (I57).
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/censusPushTokens.js
//
// Только чтение: скрипт ничего не пишет и ничего не удаляет.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

function day(v: unknown): string {
  if (v && typeof v === "object" && "toDate" in (v as object)) {
    return (v as { toDate(): Date }).toDate().toISOString().replace("T", " ").slice(0, 19);
  }
  return String(v ?? "—");
}

async function main(): Promise<void> {
  const snap = await db.collectionGroup("pushTokens").get();

  const names = new Map<string, string>();
  const owners = new Set<string>();
  for (const d of snap.docs) {
    const uid = d.ref.parent.parent?.id ?? "?";
    owners.add(uid);
  }
  for (const uid of owners) {
    const u = await db.collection("users").doc(uid).get();
    names.set(uid, (u.data()?.name as string | undefined) ?? "(без имени)");
  }

  console.log(`=== АДРЕСА ДОСТАВКИ: ${snap.size} токенов у ${owners.size} человек ===\n`);

  const rows = snap.docs
    .map((d) => {
      const data = d.data();
      return {
        uid: d.ref.parent.parent?.id ?? "?",
        docId: d.id,
        path: d.ref.path,
        token: (data.token as string | undefined) ?? "",
        platform: (data.clientPlatform as string | undefined) ?? (data.platform as string | undefined) ?? "—",
        updatedAt: day(data.updatedAt),
      };
    })
    .sort((a, b) => a.updatedAt.localeCompare(b.updatedAt));

  for (const r of rows) {
    console.log(`${r.updatedAt}  ${names.get(r.uid)}  (${r.uid})`);
    console.log(`   документ: ${r.docId}`);
    console.log(`   площадка: ${r.platform}`);
    console.log(`   адрес:    ${r.token.slice(0, 24)}…${r.token.slice(-8)}  (длина ${r.token.length})`);
    console.log("");
  }

  // I13: сторож, который считает, обязан один раз показать своё число.
  console.log(`итого строк напечатано: ${rows.length}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
