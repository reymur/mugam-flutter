// СЧИТАЕТ ЛИ СЕРВЕР, ЧТО ЧЕЛОВЕК СМОТРИТ В ЧАТ. ТОЛЬКО ЧТЕНИЕ.
//
// --- ЗАЧЕМ ---
//
// 30.08 на трубках: Теймур письма получает, Рафаэль при свёрнутом
// приложении — нет. Отказов доставки при этом НОЛЬ, то есть до отправки
// дело не дошло вовсе. Остаётся глушение: сервер молчит, если считает, что
// человек смотрит в этот чат (`isWatchingChatDecision`).
//
// Ровно об этом N171: `activeChatId` при уходе в фон не стирается, и push
// от собеседника, с которым только что говорили, не приходит около минуты.
// Находка открыта и НЕ ЧИНИТСЯ по решению владельца 26.08.
//
// --- КАК ЗАПУСКАТЬ ---
//   из functions/:  npm run build && node lib/scripts/censusWatching.js

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

async function main(): Promise<void> {
  const now = Date.now();
  const users = await db.collection("users").get();
  console.log(`сейчас: ${new Date(now).toISOString()}`);
  console.log("");

  let withActive = 0;
  for (const u of users.docs) {
    const d = u.data();
    const active = d.activeChatId ?? null;
    if (!active) continue;
    withActive += 1;
    const lastSeen = d.lastSeen?.toDate?.() ?? null;
    const ageSec = lastSeen ? Math.round((now - lastSeen.getTime()) / 1000) : null;
    console.log(`${d.name ?? "(без имени)"} [${u.id}]`);
    console.log(`   activeChatId: ${active}`);
    console.log(`   lastSeen:     ${lastSeen ? lastSeen.toISOString() : "(нет)"}`);
    console.log(`   давность:     ${ageSec === null ? "(неизвестна)" : ageSec + " с"}`);
  }
  console.log("");
  console.log(`людей с непустым activeChatId: ${withActive} из ${users.size}`);

  // КАНАРЕЙКА К НУЛЮ. Пустой список значит и «никто не смотрит», и «поле
  // читается не то». Печатаем, сколько учёток вообще прочитано.
  if (withActive === 0) {
    console.log("ноль — но учёток прочитано " + users.size +
      ", значит разбор не слеп");
  }
}

main().catch((e) => {
  console.error("перепись не доехала:", e);
  process.exit(1);
});
