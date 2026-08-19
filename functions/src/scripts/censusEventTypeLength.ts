// Какой длины бывает `eventType` у предложений работы. ТОЛЬКО ЧТЕНИЕ.
//
// --- ЗАЧЕМ ---
//
// Строка предложения в ленте задумана как «N gün · <тип> · <состояние>».
// `eventType` пишется свободным текстом: при выборе «Digər» человек
// вписывает своё, а в правилах создания ограничения длины НЕТ — `hasOnly`
// ограничивает ключи, размер значения не проверяется. Значит строка в ленте
// не ограничена ничем.
//
// Вопрос автору: обрезать в строке или ограничить в правилах. Число решает,
// насколько вопрос велик: если все значения из списка (Toy, Konsert, Məclis,
// Digər), он мельче, чем кажется.
//
// --- ПРО ЗНАМЕНАТЕЛЬ (I40) ---
//
// «Самое длинное — 3 знака» само по себе не проверяемо: неизвестно, из
// скольких. Печатается: сколько предложений просмотрено, сколько несут
// `eventType` строкой, и РАСПРЕДЕЛЕНИЕ значений поимённо — список врёт
// заметно, он называет, кого назвал.
//
// --- КАК ЗАПУСКАТЬ ---
//   из functions/:  npm run build && node lib/scripts/censusEventTypeLength.js

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

/// Список, который предлагает лист составления. Значение вне его — это
/// свободный текст, и именно он делает строку неограниченной.
const KNOWN = ["Toy", "Konsert", "Məclis", "Digər"];

async function main(): Promise<void> {
  const chats = await db.collection("chats").get();

  let offersTotal = 0;
  let withStringType = 0;
  let longest = "";
  const counts = new Map<string, number>();
  const outsideList: string[] = [];

  for (const chat of chats.docs) {
    const offers = await chat.ref.collection("offers").get();
    for (const o of offers.docs) {
      offersTotal += 1;
      const t = o.data().eventType;
      if (typeof t !== "string") continue;
      withStringType += 1;
      counts.set(t, (counts.get(t) ?? 0) + 1);
      if (t.length > longest.length) longest = t;
      if (!KNOWN.includes(t)) {
        outsideList.push(`chats/${chat.id}/offers/${o.id}  «${t}»`);
      }
    }
  }

  console.log("=== ДЛИНА eventType (только чтение) ===");
  console.log(`предложений просмотрено:      ${offersTotal}`);
  console.log(
    `КАНАРЕЙКА, eventType строкой:  ${withStringType} из ${offersTotal}` +
      (withStringType === 0 ? "   <-- РАЗБОР СЛЕП" : ""),
  );
  console.log("---");
  console.log(`самое длинное значение:       «${longest}» (${longest.length} знаков)`);
  console.log("распределение поимённо:");
  for (const [value, n] of [...counts.entries()].sort((a, b) => b[1] - a[1])) {
    const mark = KNOWN.includes(value) ? "из списка" : "СВОБОДНЫЙ ТЕКСТ";
    console.log(`  «${value}» — ${n}  (${value.length} знаков, ${mark})`);
  }
  const sum = [...counts.values()].reduce((a, b) => a + b, 0);
  console.log(
    `сумма по значениям:           ${sum}` +
      (sum === withStringType ? "  (сходится)" : "  <-- НЕ СХОДИТСЯ"),
  );
  console.log("---");
  console.log(`ВНЕ СПИСКА: ${outsideList.length} из ${withStringType}`);
  for (const line of outsideList) console.log(`  ${line}`);
}

main().catch((e) => {
  console.error("перепись не доехала:", e);
  process.exit(1);
});
