// Сверка: у каждого ли согласия в чате есть договор.
//
// ПОВОД И СРОЧНОСТЬ. 09.08 в 17:16 UTC остановились Cloud Functions —
// оба платёжных счёта проекта закрыты (N102). Договор из предложения
// работы создаёт СЕРВЕР: `onChatUpdated` ловит переход
// `recipientAgreed: false -> true` и пишет документ в `personalEvents`.
// Переход бывает ровно один раз за раунд, и повторить его нечем: сторож
// `before.recipientAgreed === true -> выход` не даст сработать второй раз.
// Значит согласие, случившееся за простой и не доехавшее до функции,
// оставляет чат со словом «договорились» и НИ ОДНОГО договора — навсегда
// и молча.
//
// ПОЧЕМУ СНИМАТЬ НАДО ДО ВОССТАНОВЛЕНИЯ ОПЛАТЫ, а не после. События лежат
// в очереди Pub/Sub с удержанием 86400 с; часть их доедет задним числом и
// создаст договоры сама. После этого «доехало» и «не терялось» станут
// неотличимы, и счёта потерь не снять уже ничем. Список, снятый сейчас, —
// единственное, с чем можно будет сравнить.
//
// ЧЕМ СВЕРЯЕТСЯ. Пара `agreementChatId` + `jobOfferAt`, а не один
// `agreementChatId`. Отметка раунда обязательна: в одном чате раундов
// бывает несколько, прошлый договор лежит там всегда, и сверка по одному
// лишь чату сказала бы «договор есть» про раунд, которого нет (тот же
// довод, по которому отметка заведена в самом триггере — N29).
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/censusLostAgreements.js
//
// Только чтение: скрипт ничего не пишет и ничего не удаляет.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

/** Час, с которого функции перестали выполняться (N102). */
const OUTAGE_START_ISO = "2026-08-09T17:16:00Z";

/**
 * Отметка времени в этом проекте живёт в трёх формах (N26/N4): строка ISO
 * с `Z`, строка ISO без смещения и Timestamp. Разбор, знающий одну,
 * ответил бы «не совпало» на паре одинаковых моментов, записанных
 * по-разному, — то есть насчитал бы потери там, где их нет.
 *
 * Сводится всё к миллисекундам. `null` остаётся `null` и сравнивается сам
 * с собой: договор копирует `after.jobOfferAt ?? null`, значит пустая
 * отметка — законная пара пустой.
 */
type Form = "timestamp" | "isoZ" | "isoNaive" | "null" | "иная";

function formOf(v: unknown): Form {
  if (v === null || v === undefined) return "null";
  if (typeof v === "object" && typeof (v as { toMillis?: unknown }).toMillis === "function") {
    return "timestamp";
  }
  if (typeof v === "string") {
    if (/[Zz]$|[+-]\d\d:?\d\d$/.test(v)) return "isoZ";
    if (!Number.isNaN(Date.parse(v))) return "isoNaive";
  }
  return "иная";
}

function toMillis(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  if (typeof v === "object" && typeof (v as { toMillis?: () => number }).toMillis === "function") {
    return (v as { toMillis: () => number }).toMillis();
  }
  if (typeof v === "string") {
    // Строка без смещения считается UTC — так её пишет и читает проект
    // после починки N4; расхождение в четыре часа сдвинуло бы пару в
    // «не совпало», а не наоборот.
    const withZone = /[Zz]$|[+-]\d\d:?\d\d$/.test(v) ? v : `${v}Z`;
    const ms = Date.parse(withZone);
    return Number.isNaN(ms) ? null : ms;
  }
  return null;
}

/** Совпадают ли отметки раунда, включая законную пару «обе пустые». */
function sameRound(a: unknown, b: unknown): boolean {
  const ma = toMillis(a);
  const mb = toMillis(b);
  if (ma === null && mb === null) return true;
  if (ma === null || mb === null) return false;
  return ma === mb;
}

function tally(map: Map<string, number>, key: string): void {
  map.set(key, (map.get(key) ?? 0) + 1);
}

function printTally(title: string, map: Map<string, number>): void {
  console.log(title);
  if (map.size === 0) {
    console.log("    (пусто)");
    return;
  }
  Array.from(map.entries())
    .sort((x, y) => y[1] - x[1])
    .forEach(([k, n]) => console.log(`    ${String(n).padStart(4)}  ${k}`));
}

async function main(): Promise<void> {
  initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
  const db = getFirestore();

  const outageMs = Date.parse(OUTAGE_START_ISO);

  const [chatsSnap, eventsSnap] = await Promise.all([
    db.collection("chats").get(),
    db.collection("personalEvents").get(),
  ]);

  // Договоры, разложенные по чату, из которого родились.
  const byChat = new Map<string, { id: string; jobOfferAt: unknown; status: string }[]>();
  let eventsWithChatId = 0;
  const eventFormTally = new Map<string, number>();

  eventsSnap.docs.forEach((doc) => {
    const d = doc.data();
    const chatId = d.agreementChatId;
    tally(eventFormTally, formOf(d.jobOfferAt));
    if (typeof chatId !== "string" || chatId.length === 0) return;
    eventsWithChatId += 1;
    const list = byChat.get(chatId) ?? [];
    list.push({
      id: doc.id,
      jobOfferAt: d.jobOfferAt ?? null,
      status: typeof d.status === "string" ? d.status : "(без status)",
    });
    byChat.set(chatId, list);
  });

  let agreedChats = 0;
  let found = 0;
  const missing: {
    chatId: string;
    jobOfferAt: unknown;
    agreedAt: unknown;
    agreedAfterOutage: boolean | null;
    otherRounds: number;
  }[] = [];
  const chatFormTally = new Map<string, number>();
  const agreedAtFormTally = new Map<string, number>();

  // КАНАРЕЙКА ГЛАВНОГО ЧИСЛА. «Согласившихся чатов ноль» — утверждение
  // отсутствия, и ослепший разбор подтверждает его молча (I31): поле
  // могло быть переименовано, лежать строкой `"true"` или отсутствовать
  // вовсе, и счёт был бы тем же нулём. Поэтому считается РАСКЛАДКА поля
  // по всем чатам, а не только совпадения.
  const agreedValueTally = new Map<string, number>();
  chatsSnap.docs.forEach((doc) => {
    const v = doc.data().recipientAgreed;
    const kind = v === undefined
      ? "поля нет"
      : v === null
        ? "null"
        : `${typeof v}: ${JSON.stringify(v)}`;
    tally(agreedValueTally, kind);
  });

  chatsSnap.docs.forEach((doc) => {
    const d = doc.data();
    if (d.recipientAgreed !== true) return;
    agreedChats += 1;
    tally(chatFormTally, formOf(d.jobOfferAt));
    tally(agreedAtFormTally, formOf(d.recipientAgreedAt));

    const candidates = byChat.get(doc.id) ?? [];
    const hit = candidates.find((e) => sameRound(e.jobOfferAt, d.jobOfferAt));
    if (hit) {
      found += 1;
      return;
    }
    const agreedMs = toMillis(d.recipientAgreedAt);
    missing.push({
      chatId: doc.id,
      jobOfferAt: d.jobOfferAt ?? null,
      agreedAt: d.recipientAgreedAt ?? null,
      agreedAfterOutage: agreedMs === null ? null : agreedMs >= outageMs,
      otherRounds: candidates.length,
    });
  });

  const afterOutage = missing.filter((m) => m.agreedAfterOutage === true).length;
  const beforeOutage = missing.filter((m) => m.agreedAfterOutage === false).length;
  const undated = missing.filter((m) => m.agreedAfterOutage === null).length;

  console.log(`Снято: ${new Date().toISOString()}`);
  console.log(`Простой считается с: ${OUTAGE_START_ISO} (N102)`);
  console.log("");
  console.log(`Чатов всего:                       ${chatsSnap.size}`);
  console.log(`Договоров (personalEvents) всего:   ${eventsSnap.size}`);
  console.log("");
  console.log(`Чатов с recipientAgreed == true:    ${agreedChats}`);
  console.log(`  договор ЕСТЬ (чат + раунд):       ${found}`);
  console.log(`  договора НЕТ:                     ${missing.length}`);
  console.log(`     из них согласие ПОСЛЕ ${OUTAGE_START_ISO}: ${afterOutage}`);
  console.log(`     из них согласие ДО простоя:                ${beforeOutage}`);
  console.log(`     из них без отметки времени согласия:       ${undated}`);

  // КАНАРЕЙКИ. Каждое из трёх чисел выше — утверждение об ОТСУТСТВИИ, а
  // такое утверждение ослепший разбор подтверждает молча (I31). Ниже —
  // то, что обязано быть НЕпустым, если разбор вообще видит данные.
  console.log("");
  console.log("--- канарейки: разбор видит данные? ---");
  console.log(`  договоров с непустым agreementChatId: ${eventsWithChatId}`);
  console.log(`  чатов, к которым привязан хоть один:  ${byChat.size}`);
  printTally("  recipientAgreed по ВСЕМ чатам:", agreedValueTally);
  printTally("  формы jobOfferAt на ДОГОВОРАХ:", eventFormTally);
  printTally("  формы jobOfferAt на согласившихся ЧАТАХ:", chatFormTally);
  printTally("  формы recipientAgreedAt:", agreedAtFormTally);
  if (eventsWithChatId === 0 || byChat.size === 0) {
    console.log("");
    console.log("  ВНИМАНИЕ: канарейка пуста. Ноль потерь выше ничего не значит —");
    console.log("  разбор не нашёл ни одной связи чат→договор вовсе.");
  }

  if (missing.length > 0) {
    console.log("");
    console.log("--- ЧАТЫ БЕЗ ДОГОВОРА, поимённо ---");
    missing.forEach((m) => {
      const when = m.agreedAfterOutage === null
        ? "время согласия неизвестно"
        : m.agreedAfterOutage
          ? "ПОСЛЕ начала простоя"
          : "до простоя";
      console.log(
        `  ${m.chatId}  раунд=${JSON.stringify(m.jobOfferAt)}  ` +
        `согласие=${JSON.stringify(m.agreedAt)}  [${when}]  ` +
        `прочих договоров в этом чате: ${m.otherRounds}`
      );
    });
  }

  // ЧЕГО ЭТА СВЕРКА НЕ ВИДИТ — пишется рядом со сверкой, а не выясняется
  // потом (I21, «границы сторожа записываются вместе со сторожем»):
  //
  // 1. Договор, созданный триггером и ПОТОМ УДАЛЁННЫЙ владельцем, здесь
  //    неотличим от несозданного. Оба выглядят как пропажа.
  // 2. Согласие, случившееся до 09.08, но потерянное по другой причине,
  //    попадёт в счёт «до простоя» — это не находка этого простоя, а
  //    отдельный долг, и разбирать его надо отдельно.
  // 3. Отметка `recipientAgreedAt` пишется КЛИЕНТОМ по часам устройства.
  //    Съехавшие часы сдвигают строку в чужую половину счёта; сам факт
  //    пропажи от этого не меняется, меняется только приписка «после/до».
  // 4. САМОЕ ВАЖНОЕ: сверка видит пропажу, только пока признак согласия
  //    ещё стоит. `setJobOffer` (новое предложение в том же чате) и конец
  //    раунда пишут `recipientAgreed: false` — и потерянный договор
  //    становится невидим НАВСЕГДА, вместе со следом. То есть ноль здесь
  //    означает «на эту минуту не потеряно», а не «не потеряется»: чем
  //    позже снят счёт, тем больше он мог не досчитать. Отсюда и правило
  //    снимать его ДО восстановления оплаты, а не после.
  console.log("");
  console.log("Чего сверка не видит: удалённый вручную договор выглядит как");
  console.log("пропавший; отметка согласия идёт по часам устройства.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
