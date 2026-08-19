// Несут ли сообщения-якоря ссылку `offerId` — и сходятся ли они с
// `anchorMessageId` на самих предложениях. ТОЛЬКО ЧТЕНИЕ.
//
// --- ЗАЧЕМ ---
//
// 19.08 шаг 1 (карточка в ленте) не показал ни одной карточки на трубке:
// предложения рисуются обычным текстом. Лента отличает якорь от обычного
// сообщения ПО НАЛИЧИЮ `offerId` на сообщении (`models.dart`), а не по
// документу предложения.
//
// Перепись `censusOfferDetails` считала ДОКУМЕНТЫ предложений (14 штук) и
// про сообщения не спрашивала вовсе — то есть отвечала на соседний вопрос
// (I13). Этот проход закрывает дырку: он смотрит с другой стороны, со
// стороны ленты.
//
// --- ЧТО РАЗЛИЧАЕТСЯ, И ПОЧЕМУ ЭТО НЕ ОДИН ВОПРОС (I47) ---
//
//   сообщений с `offerId`        — сколько ленте вообще есть что рисовать;
//   из них ссылка ведёт в живой  — карточка построится;
//     документ `offers`
//   из них ссылка «висит»        — документа нет: карточка не построится,
//                                  и это НЕ поломка ленты;
//   предложений без якоря вовсе  — документ есть, сообщения нет.
//
// Слить их в одно число значило бы получить ответ, по которому нельзя
// отличить «лента не умеет» от «рисовать нечего».
//
// --- КАК ЗАПУСКАТЬ ---
//   из functions/:  npm run build && node lib/scripts/censusOfferAnchors.js

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

async function main(): Promise<void> {
  const chats = await db.collection("chats").get();

  let chatsWithOffers = 0;
  let offersTotal = 0;
  let offersWithAnchorField = 0;
  let messagesTotal = 0;
  let messagesWithOfferId = 0;
  let linksResolving = 0;
  let linksDangling = 0;
  let offersWhoseAnchorMessageExists = 0;

  for (const chat of chats.docs) {
    const offers = await chat.ref.collection("offers").get();
    if (offers.empty) continue;
    chatsWithOffers += 1;
    offersTotal += offers.size;

    const offerIds = new Set(offers.docs.map((d) => d.id));

    const messages = await chat.ref.collection("messages").get();
    messagesTotal += messages.size;

    const messageIds = new Set(messages.docs.map((d) => d.id));

    for (const m of messages.docs) {
      const offerId = m.data().offerId;
      if (typeof offerId !== "string") continue;
      messagesWithOfferId += 1;
      if (offerIds.has(offerId)) linksResolving += 1;
      else linksDangling += 1;
    }

    for (const o of offers.docs) {
      const anchor = o.data().anchorMessageId;
      if (typeof anchor === "string") {
        offersWithAnchorField += 1;
        if (messageIds.has(anchor)) offersWhoseAnchorMessageExists += 1;
      }
    }

    console.log(`--- чат ${chat.id} ---`);
    console.log(`  предложений:              ${offers.size}`);
    console.log(`  сообщений:                ${messages.size}`);
  }

  console.log("=== СО СТОРОНЫ ЛЕНТЫ (это и решает, будет ли карточка) ===");
  console.log(`чатов с предложениями:        ${chatsWithOffers}`);
  console.log(`сообщений всего:              ${messagesTotal}`);
  console.log(
    `сообщений с offerId:          ${messagesWithOfferId}` +
      (messagesWithOfferId === 0
        ? "   <-- РИСОВАТЬ НЕЧЕГО: лента не виновата"
        : ""),
  );
  console.log(`  из них ссылка живая:        ${linksResolving}`);
  console.log(`  из них ссылка висит:        ${linksDangling}`);
  console.log("=== СО СТОРОНЫ ПРЕДЛОЖЕНИЙ ===");
  console.log(`предложений всего:            ${offersTotal}`);
  console.log(`  с полем anchorMessageId:    ${offersWithAnchorField}`);
  console.log(`  чей якорь реально есть:     ${offersWhoseAnchorMessageExists}`);

  // Разбиение обязано сходиться (I13, третий шаг).
  const sum = linksResolving + linksDangling;
  console.log(
    `сумма живых и висящих:        ${sum}` +
      (sum === messagesWithOfferId ? "  (сходится)" : "  <-- НЕ СХОДИТСЯ"),
  );
}

main().catch((e) => {
  console.error("перепись не доехала:", e);
  process.exit(1);
});
