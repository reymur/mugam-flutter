// Сколько цитат в проде несут ИСПОРЧЕННОЕ имя автора. ТОЛЬКО ЧТЕНИЕ.
//
// --- ЗАЧЕМ ---
//
// N141: имя собеседника бралось с документа чата, а поле `name` там пишет
// mugam-v2 с точки зрения того, кто чат создал, и больше не трогает. Вторая
// сторона читает там СВОЁ имя, в новых чатах — пустоту. В карточке
// предложения это починено 19.08; в цитатах (`_replySenderName`) — нет.
//
// Опаснее экрана то, что имя цитаты **записывается в документ сообщения**
// (`replyTo.senderName`) и остаётся в данных навсегда. Правка кода новых
// цитат не испортит, а старые не вылечит — поэтому нужно число: оно решает,
// нужна ли правка задним числом.
//
// --- ЧЕТЫРЕ ИСХОДА, А НЕ ДВА (I47) ---
//
//   ИМЯ СОВПАЛО      — записано верно, чинить нечего;
//   ИМЯ ПУСТОЕ       — записана пустота;
//   ИМЯ РАЗОШЛОСЬ    — записано ЧУЖОЕ имя. Хуже пустого: пустое видно, а
//                      чужое читается как правда;
//   ПРОВЕРИТЬ НЕЧЕМ  — цитируемого сообщения больше нет либо автора нет в
//                      `users`. Это НЕ «всё хорошо» и НЕ «испорчено»;
//                      слить его с любым из трёх значило бы соврать в ту
//                      или другую сторону.
//
// --- ПРО НОЛЬ (I37) ---
//
// «Испорченных ноль» само по себе не проверяемо. Рядом ВСЕГДА печатается
// знаменатель — сколько цитат просмотрено — и канарейка: сколько сообщений
// прочитано всего и сколько имён загружено из `users`. Ноль по канарейке
// означает «разбор ничего не видит», и тогда прочие числа мусор.
//
// --- КАК ЗАПУСКАТЬ ---
//   из functions/:  npm run build && node lib/scripts/censusReplyNames.js

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

type Verdict = "совпало" | "пустое" | "разошлось" | "проверить нечем";

async function main(): Promise<void> {
  // Имена людей — из `users`, это единственный источник, которому здесь
  // верят. Он же тот, откуда их берёт заголовок экрана.
  const users = await db.collection("users").get();
  const nameByUid = new Map<string, string>();
  for (const u of users.docs) {
    const n = u.data().name;
    if (typeof n === "string") nameByUid.set(u.id, n);
  }

  const chats = await db.collection("chats").get();

  let messagesTotal = 0;
  let quotesTotal = 0;
  const byVerdict: Record<Verdict, number> = {
    "совпало": 0,
    "пустое": 0,
    "разошлось": 0,
    "проверить нечем": 0,
  };
  // Испорченные — поимённо, а не числом: по этим адресам и решается,
  // нужна ли правка задним числом (I57).
  const named: string[] = [];

  for (const chat of chats.docs) {
    const messages = await chat.ref.collection("messages").get();
    messagesTotal += messages.size;

    const senderById = new Map<string, string>();
    for (const m of messages.docs) {
      const s = m.data().senderId;
      if (typeof s === "string") senderById.set(m.id, s);
    }

    for (const m of messages.docs) {
      const replyTo = m.data().replyTo;
      if (!replyTo || typeof replyTo !== "object") continue;
      quotesTotal += 1;

      const stored = replyTo.senderName;
      const quotedId = replyTo.id;

      if (typeof stored !== "string" || stored.trim() === "") {
        byVerdict["пустое"] += 1;
        named.push(`пустое      chats/${chat.id}/messages/${m.id}`);
        continue;
      }

      const authorUid =
        typeof quotedId === "string" ? senderById.get(quotedId) : undefined;
      const trueName = authorUid ? nameByUid.get(authorUid) : undefined;

      if (!trueName) {
        byVerdict["проверить нечем"] += 1;
        continue;
      }

      if (trueName.trim() === stored.trim()) {
        byVerdict["совпало"] += 1;
      } else {
        byVerdict["разошлось"] += 1;
        named.push(
          `разошлось   chats/${chat.id}/messages/${m.id}` +
            `  записано «${stored}», на деле «${trueName}»`,
        );
      }
    }
  }

  console.log("=== ПЕРЕПИСЬ ИМЁН В ЦИТАТАХ (только чтение) ===");
  console.log(`чатов просмотрено:            ${chats.size}`);
  console.log(
    `КАНАРЕЙКА, имён в users:      ${nameByUid.size} из ${users.size}` +
      (nameByUid.size === 0 ? "   <-- РАЗБОР СЛЕП, числа ниже мусор" : ""),
  );
  console.log(
    `КАНАРЕЙКА, сообщений всего:   ${messagesTotal}` +
      (messagesTotal === 0 ? "   <-- РАЗБОР СЛЕП" : ""),
  );
  console.log("---");
  console.log(`ЦИТАТ ВСЕГО (знаменатель):    ${quotesTotal}`);
  console.log(`  имя совпало:                ${byVerdict["совпало"]}`);
  console.log(`  имя ПУСТОЕ:                 ${byVerdict["пустое"]}`);
  console.log(`  имя РАЗОШЛОСЬ (чужое):      ${byVerdict["разошлось"]}`);
  console.log(`  проверить нечем:            ${byVerdict["проверить нечем"]}`);

  const sum =
    byVerdict["совпало"] +
    byVerdict["пустое"] +
    byVerdict["разошлось"] +
    byVerdict["проверить нечем"];
  console.log(
    `сумма по исходам:             ${sum}` +
      (sum === quotesTotal ? "  (сходится)" : "  <-- НЕ СХОДИТСЯ С ЦЕЛЫМ"),
  );

  const broken = byVerdict["пустое"] + byVerdict["разошлось"];
  console.log("---");
  console.log(`ИСПОРЧЕНО: ${broken} из ${quotesTotal} цитат`);

  if (named.length > 0) {
    console.log("поимённо:");
    for (const line of named) console.log(`  ${line}`);
  }
}

main().catch((e) => {
  console.error("перепись не доехала:", e);
  process.exit(1);
});
