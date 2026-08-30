// КОМУ И ПОЧЕМУ НЕ ДОШЛИ УВЕДОМЛЕНИЯ. ТОЛЬКО ЧТЕНИЕ.
//
// --- ЗАЧЕМ ---
//
// 30.08 на трубках: Теймур письма получает, Рафаэль при свёрнутом
// приложении — нет, несколько раз подряд. Это первый случай, когда есть чем
// ответить не догадкой: вчерашняя вторая половина N186 пишет КАЖДЫЙ отказ
// доставки в `maintenance/pushDelivery/failures` вместе с uid, путём токена,
// кодом и текстом.
//
// До неё этот вопрос отвечался чтением журнала глазами, и оба раза (27.08,
// 29.08) отказ прочитали как единичный шум.
//
// --- ЧТО РАЗЛИЧАЕТСЯ, И ПОЧЕМУ ЭТО НЕ ОДИН ВОПРОС (I47) ---
//
//   токенов у человека нет вовсе   — слать некому, отказа не будет НИ ОДНОГО,
//                                    и тишина в отказах читается как «всё
//                                    хорошо». Самый тихий из случаев;
//   токен есть, отказ есть         — дошли до отправки, FCM отверг;
//   токен есть, отказов нет        — отправка удалась, дело не в доставке.
//
// Слить их значило бы получить «не пришло» — ответ, по которому нельзя
// решить, что чинить.
//
// --- КАК ЗАПУСКАТЬ ---
//   из functions/:  npm run build && node lib/scripts/censusPushDelivery.js

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

async function main(): Promise<void> {
  console.log("=== ТОКЕНЫ ===");
  const tokens = await db.collectionGroup("pushTokens").get();
  const byUser = new Map<string, { device: string; updatedAt: string }[]>();
  for (const d of tokens.docs) {
    const uid = d.ref.parent.parent?.id ?? "(нет)";
    const list = byUser.get(uid) ?? [];
    list.push({
      device: d.id,
      updatedAt: String(d.data().updatedAt ?? "(нет поля)"),
    });
    byUser.set(uid, list);
  }
  console.log(`документов токенов: ${tokens.size}, людей: ${byUser.size}`);

  const users = await db.collection("users").get();
  const nameOf = new Map<string, string>();
  for (const u of users.docs) {
    nameOf.set(u.id, String(u.data().name ?? u.data().displayName ?? "(без имени)"));
  }
  console.log(`учёток всего: ${users.size}`);

  for (const [uid, list] of byUser) {
    console.log(`  ${nameOf.get(uid) ?? "(нет учётки)"} [${uid}] — ${list.length}`);
    for (const t of list) console.log(`      ${t.device}  updatedAt=${t.updatedAt}`);
  }

  // ЛЮДИ БЕЗ ЕДИНОГО ТОКЕНА — НАЗЫВАЮТСЯ ПОИМЁННО, А НЕ СЧИТАЮТСЯ.
  // «У троих нет токена» не говорит, у кого именно, а весь вопрос сейчас в
  // том, есть ли он у ОДНОГО КОНКРЕТНОГО человека (I13: состав, а не
  // количество).
  const without = [...nameOf.keys()].filter((u) => !byUser.has(u));
  console.log(`без единого токена: ${without.length}`);
  for (const u of without) console.log(`  ${nameOf.get(u)} [${u}]`);

  console.log("");
  console.log("=== ОТКАЗЫ ДОСТАВКИ (maintenance/pushDelivery/failures) ===");
  const fails = await db.collection("maintenance").doc("pushDelivery")
    .collection("failures").get();
  console.log(`записей всего: ${fails.size}`);

  // Канарейка к нулю: пустая коллекция значит и «всё доходит», и «вчерашняя
  // запись не работает». Различает их только то, что мы знаем срок — она
  // заведена 30.08, 00:53 UTC, и до того отказов не писалось нигде.
  if (fails.size === 0) {
    console.log("ноль. Осторожно: до 30.08 00:53 UTC отказы не писались");
    console.log("вовсе, значит ноль здесь НЕ доказывает, что всё доходит.");
  }

  const perUid = new Map<string, number>();
  for (const f of fails.docs) {
    const d = f.data();
    const uid = String(d.uid ?? "(нет)");
    perUid.set(uid, (perUid.get(uid) ?? 0) + 1);
  }
  for (const [uid, n] of perUid) {
    console.log(`  ${nameOf.get(uid) ?? "(нет учётки)"} [${uid}] — ${n}`);
  }

  console.log("");
  console.log("--- последние 15 отказов, по времени ---");
  const sorted = fails.docs
    .map((f) => f.data())
    .sort((a, b) => String(a.at?.toDate?.() ?? a.at) < String(b.at?.toDate?.() ?? b.at) ? 1 : -1)
    .slice(0, 15);
  for (const d of sorted) {
    const at = d.at?.toDate?.()?.toISOString?.() ?? String(d.at);
    console.log(`  ${at}  ${nameOf.get(String(d.uid)) ?? d.uid}`);
    console.log(`      код: ${d.code}`);
    console.log(`      мёртв ли токен: ${d.tokenDead}`);
    console.log(`      текст: ${String(d.message).slice(0, 160)}`);
  }
}

main().catch((e) => {
  console.error("перепись не доехала:", e);
  process.exit(1);
});
