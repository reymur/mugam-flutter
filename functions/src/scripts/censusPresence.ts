// Перепись отметок присутствия по проду: `activeChatId` и знаменатель к
// переписи `activeUsers`.
//
// Вопрос не «правильно ли написан признак», а «кто ПРЯМО СЕЙЧАС не
// получает уведомления из-за него». Решение о подавлении push принимает
// `isWatchingChatDecision` (functions/src/presence.ts), и здесь оно
// воспроизведено ровно в том же виде — иначе перепись мерила бы свою
// выдумку, а не поведение сервера.
//
// Устройство защиты, которое перепись обязана проверить, а не принять на
// веру: у `activeChatId` есть СРОК ГОДНОСТИ. Сервер подавляет push только
// если отметка указывает на этот чат И `lastSeen` свежее окна
// (`freshnessWindowMs`, двойной интервал сердцебиения). Свернул или убил
// приложение — удары прекратились, отметка протухла, push пошёл. Именно
// этим `activeChatId` отличается от прежнего `activeUsers`, у которого
// срока не было вовсе (N19).
//
// Отсюда единственное по-настоящему вредное сочетание: сердцебиение ЖИВО
// (человек в приложении), а отметка указывает на чат, который он уже
// покинул. Считается отдельной строкой.
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/censusPresence.js
//
// Только чтение: скрипт ничего не пишет и ничего не удаляет.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

// Копии констант presence.ts — держать в согласии с ним.
const PRESENCE_FRESH_MS = 2 * 60 * 1000;
const PRESENCE_FRESH_MIN_MS = 30 * 1000;

function freshnessWindowMs(userData: Record<string, unknown>): number {
  const declared = userData.presenceIntervalMs;
  if (typeof declared !== "number" || !Number.isFinite(declared)) {
    return PRESENCE_FRESH_MS;
  }
  const doubled = 2 * declared;
  if (doubled < PRESENCE_FRESH_MIN_MS) return PRESENCE_FRESH_MIN_MS;
  if (doubled > PRESENCE_FRESH_MS) return PRESENCE_FRESH_MS;
  return doubled;
}

function ageStr(ms: number | null): string {
  if (ms == null) return "lastSeen нет";
  const min = ms / 60000;
  if (min < 60) return `${min.toFixed(1)} мин назад`;
  const h = min / 60;
  if (h < 48) return `${h.toFixed(1)} ч назад`;
  return `${(h / 24).toFixed(1)} дн назад`;
}

async function main() {
  initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
  const db = getFirestore();
  const nowMs = Date.now();

  // --- ЗНАМЕНАТЕЛЬ ---
  // count() идёт по другому пути, чем постраничная выдача документов, —
  // поэтому годится как независимая проверка числа из переписи
  // activeUsers, а не как его повторение.
  const chatsCount = (await db.collection("chats").count().get()).data().count;
  const usersCount = (await db.collection("users").count().get()).data().count;
  const chatsFetched = (await db.collection("chats").select("members").get()).size;

  console.log("=== ЗНАМЕНАТЕЛЬ ===");
  console.log(`chats, count():        ${chatsCount}`);
  console.log(`chats, выдача целиком: ${chatsFetched}`);
  console.log(`users, count():        ${usersCount}`);
  if (chatsCount !== chatsFetched) {
    console.log("!! РАСХОЖДЕНИЕ: выдача не покрывает коллекцию, перепись неполна");
  } else {
    console.log("совпало — перепись activeUsers шла по всей коллекции, не по выборке");
  }
  console.log("");

  // --- ПЕРЕПИСЬ activeChatId ---
  const users = await db.collection("users").get();
  const chats = await db.collection("chats").select("members", "name", "isGroup").get();
  const chatById = new Map(chats.docs.map((d) => [d.id, d.data()]));

  const oldBuild: string[] = [];
  const idle: string[] = [];
  const suppressedNow: string[] = [];
  const staleHarmless: string[] = [];
  const pointingElsewhere: string[] = [];

  for (const doc of users.docs) {
    const d = doc.data();
    const name = (d.name as string) || "(без имени)";
    const who = `${name} (${doc.id.slice(0, 8)}…)`;

    // Ключа нет вовсе — сборка, которая его не пишет. ТОЛЬКО для неё
    // сервер до сих пор смотрит на activeUsers (presence.ts).
    if (!Object.prototype.hasOwnProperty.call(d, "activeChatId")) {
      oldBuild.push(who);
      continue;
    }

    const activeChatId = d.activeChatId as string | null;
    const lastSeenMs = d.lastSeen instanceof Timestamp ? d.lastSeen.toMillis() : null;
    const age = lastSeenMs == null ? null : nowMs - lastSeenMs;
    const win = freshnessWindowMs(d);
    const fresh = age != null && age < win;

    if (activeChatId == null) {
      idle.push(`${who} — отметки нет, ${ageStr(age)}`);
      continue;
    }

    const chat = chatById.get(activeChatId);
    const members: string[] = Array.isArray(chat?.members) ? chat!.members : [];
    const isMember = members.includes(doc.id);
    const chatName =
      chat == null ? "(ЧАТА НЕТ)" : (chat.name as string) || (chat.isGroup ? "(группа)" : "(личный)");

    // Вот оно: сердцебиение живо И отметка стоит — сервер подавляет push
    // по этому чату прямо сейчас.
    const line =
      `${who} -> ${activeChatId.slice(0, 16)}… ${chatName}, ` +
      `${ageStr(age)}, окно ${(win / 1000).toFixed(0)} с` +
      (isMember ? "" : "  <-- НЕ УЧАСТНИК ЭТОГО ЧАТА");

    if (!isMember || chat == null) pointingElsewhere.push(line);
    if (fresh) suppressedNow.push(line);
    else staleHarmless.push(line);
  }

  console.log("=== activeChatId: КТО СЕЙЧАС НЕ ПОЛУЧАЕТ PUSH ===\n");
  console.log(`Пользователей всего: ${users.size}`);
  console.log("");
  console.log(`ПОДАВЛЕН push прямо сейчас (отметка стоит И lastSeen свежее окна): ${suppressedNow.length}`);
  for (const l of suppressedNow) console.log(`    ${l}`);
  console.log("");
  console.log(`Отметка стоит, но lastSeen протух — ВРЕДА НЕТ, окно отработало: ${staleHarmless.length}`);
  for (const l of staleHarmless) console.log(`    ${l}`);
  console.log("");
  console.log(`Отметка указывает на чат, где человек НЕ участник (или чата нет): ${pointingElsewhere.length}`);
  for (const l of pointingElsewhere) console.log(`    ${l}`);
  console.log("");
  console.log(`Отметки нет вовсе (норма, вне чатов): ${idle.length}`);
  for (const l of idle) console.log(`    ${l}`);
  console.log("");
  console.log(`СТАРАЯ сборка, ключа activeChatId нет — для них жив путь activeUsers: ${oldBuild.length}`);
  for (const l of oldBuild) console.log(`    ${l}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
