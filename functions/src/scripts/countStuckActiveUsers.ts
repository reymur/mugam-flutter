// Перепись застрявших отметок `activeUsers` по всем чатам прода.
//
// Зачем: `activeUsers` — прежний признак присутствия. uid добавлялся при
// входе на экран чата и снимался только в `dispose`; свернул приложение,
// убил его или потерял сеть — отметка оставалась навсегда (N19). Уборка на
// логауте (`clearActiveUserFromAllChats`, firestore_service.dart) должна
// была это подчищать, но её запрос отклоняется правилами и ошибка уходит в
// тихий catch — то есть не подчищала ни разу.
//
// Скрипт отвечает на три разных вопроса, которые легко перепутать:
//   1. Сколько отметок застряло вообще.
//   2. Сколько из них принадлежит НЕ участнику чата (вышел из группы или
//      был удалён — `leaveGroup` чистит только members/admins). Это тот
//      набор, которому дизъюнкт `uid in activeUsers` в правиле чтения
//      выдал бы доступ к чужому чату, поэтому он считается отдельно.
//   3. Скольким людям отметка РЕАЛЬНО стоит уведомлений. Сервер смотрит на
//      `activeUsers` только для сборок без ключа `activeChatId`
//      (presence.ts). У сборки с этим ключом застрявшая отметка не значит
//      ничего — вред нулевой, и валить это в общую кучу нельзя.
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/countStuckActiveUsers.js
//
// Только чтение: скрипт ничего не пишет и ничего не удаляет.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

// То же окно, что у сервера (presence.ts PRESENCE_FRESH_MS): отметка
// свежее двух минут — человек, возможно, прямо сейчас в чате, и это не
// «застряло», а нормальная работа признака.
const FRESH_MS = 2 * 60 * 1000;

interface Pair {
  chatId: string;
  chatName: string;
  uid: string;
  isMember: boolean;
  watchingNow: boolean;
  oldBuild: boolean;
  lastSeenDays: number | null;
}

function daysSince(ts: unknown, nowMs: number): number | null {
  if (!(ts instanceof Timestamp)) return null;
  return (nowMs - ts.toMillis()) / 86400000;
}

async function main() {
  initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
  const db = getFirestore();
  const nowMs = Date.now();

  // .select() — читаем только нужные поля, а не тела чатов целиком.
  const chats = await db
    .collection("chats")
    .select("members", "activeUsers", "name", "isGroup")
    .get();

  const pairs: Pair[] = [];
  const uids = new Set<string>();

  for (const doc of chats.docs) {
    const d = doc.data();
    const active: string[] = Array.isArray(d.activeUsers) ? d.activeUsers : [];
    if (active.length === 0) continue;
    const members: string[] = Array.isArray(d.members) ? d.members : [];
    for (const uid of active) {
      uids.add(uid);
      pairs.push({
        chatId: doc.id,
        chatName: (d.name as string) || (d.isGroup ? "(группа без имени)" : "(личный чат)"),
        uid,
        isMember: members.includes(uid),
        watchingNow: false,
        oldBuild: false,
        lastSeenDays: null,
      });
    }
  }

  if (pairs.length === 0) {
    console.log("Застрявших отметок нет вовсе: ни в одном чате activeUsers не заполнен.");
    return;
  }

  // Документы участников — одним пакетом, а не по одному на отметку.
  const uidList = [...uids];
  const userRefs = uidList.map((u) => db.collection("users").doc(u));
  const userSnaps = await db.getAll(...userRefs);
  const userById = new Map(userSnaps.map((s) => [s.id, s]));
  const names = new Map<string, string>();

  for (const p of pairs) {
    const snap = userById.get(p.uid);
    const data = snap?.data();
    names.set(p.uid, (data?.name as string) || (snap?.exists ? "(без имени)" : "(нет документа)"));
    if (!data) {
      p.oldBuild = false;
      continue;
    }
    // Ключа activeChatId нет вовсе — сборка старая, и ТОЛЬКО для неё
    // сервер до сих пор смотрит на activeUsers.
    p.oldBuild = !Object.prototype.hasOwnProperty.call(data, "activeChatId");
    p.lastSeenDays = daysSince(data.lastSeen, nowMs);
    const lastSeenMs = data.lastSeen instanceof Timestamp ? data.lastSeen.toMillis() : null;
    p.watchingNow =
      data.activeChatId === p.chatId &&
      lastSeenMs != null &&
      nowMs - lastSeenMs < FRESH_MS;
  }

  const stuck = pairs.filter((p) => !p.watchingNow);
  const exMember = stuck.filter((p) => !p.isMember);
  const costingPush = stuck.filter((p) => p.oldBuild && p.isMember);
  const chatsAffected = new Set(stuck.map((p) => p.chatId));
  const peopleAffected = new Set(stuck.map((p) => p.uid));

  console.log("=== ЗАСТРЯВШИЕ ОТМЕТКИ activeUsers (прод) ===\n");
  console.log(`Чатов просмотрено:            ${chats.size}`);
  console.log(`Чатов с непустым activeUsers: ${new Set(pairs.map((p) => p.chatId)).size}`);
  console.log(`Отметок всего:                ${pairs.length}`);
  console.log(`  из них смотрят прямо сейчас: ${pairs.length - stuck.length} (не застряли)`);
  console.log("");
  console.log(`ЗАСТРЯЛО отметок:             ${stuck.length}`);
  console.log(`  людей затронуто:            ${peopleAffected.size}`);
  console.log(`  чатов затронуто:            ${chatsAffected.size}`);
  console.log("");
  console.log(`Из застрявших — НЕ участник чата: ${exMember.length}`);
  console.log("  (тот самый набор, которому дизъюнкт в правиле открыл бы чужой чат)");
  console.log(`Из застрявших — реально стоит уведомлений: ${costingPush.length}`);
  console.log("  (участник + сборка без activeChatId; у остальных вред нулевой)");
  console.log("");

  console.log("--- по людям ---");
  const byUid = new Map<string, Pair[]>();
  for (const p of stuck) {
    const list = byUid.get(p.uid) ?? [];
    list.push(p);
    byUid.set(p.uid, list);
  }
  const sorted = [...byUid.entries()].sort((a, b) => b[1].length - a[1].length);
  for (const [uid, list] of sorted) {
    const seen = list[0].lastSeenDays;
    const seenStr = seen == null ? "lastSeen нет" : `был ${seen.toFixed(1)} дн. назад`;
    const build = list[0].oldBuild ? "СТАРАЯ сборка" : "новая сборка";
    console.log(`${names.get(uid)} (${uid}) — ${list.length} чат(ов), ${seenStr}, ${build}`);
    for (const p of list) {
      const flag = p.isMember ? "" : "  <-- УЖЕ НЕ УЧАСТНИК";
      console.log(`    ${p.chatId}  ${p.chatName}${flag}`);
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
