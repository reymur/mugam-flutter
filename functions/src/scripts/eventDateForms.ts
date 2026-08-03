// Разбор форм даты у мероприятий (N26) и — по флагу — миграция.
//
// Зачем. Почасовая функция напоминаний (N25) сравнивает `date` со строкой
// бакинских стенных часов. Замер N4 показал, что в проде `personalEvents`
// хранят дату в ТРЁХ несовместимых формах одновременно, и записи с `Z`
// (UTC) попадут в окно на четыре часа раньше срока.
//
// Запрет N4 остаётся в силе: приводить `date` К UTC нельзя — это не момент
// на оси, а запись в календаре, и перевод сдвинул бы показанное время.
// Здесь делается ОБРАТНОЕ: старая UTC-запись возвращается к плавающему
// гражданскому виду, то есть восстанавливается тот смысл, который в неё
// вкладывали при создании.
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/eventDateForms.js            # только показать
//     node lib/scripts/eventDateForms.js --migrate  # переписать
//
// Без --migrate не пишет ничего.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

initializeApp({ credential: applicationDefault(), projectId: "mugam-club" });
const db = getFirestore();

const BAKU_OFFSET_HOURS = 4;

type Form = "utc-z" | "floating" | "floating-micros" | "unknown";

/**
 * Форма определяется по самому значению, без догадок:
 *
 *  - `utc-z`            — оканчивается на `Z` либо несёт явное смещение
 *                         (`+04:00`): момент на оси, пояс назван прямо;
 *  - `floating`         — `YYYY-MM-DDTHH:MM:SS[.mmm]` без смещения;
 *  - `floating-micros`  — то же, но с микросекундами (шесть знаков) —
 *                         почерк Dart `DateTime.now().toIso8601String()`;
 *  - `unknown`          — всё остальное, не трогаем.
 *
 * Неоднозначных случаев НЕТ: наличие `Z`/смещения — это признак в самой
 * строке, а не догадка о происхождении. Различить `floating` и
 * `floating-micros` для миграции не нужно вовсе — обе уже плавающие; они
 * разведены только чтобы цифры в отчёте совпали с замером N4.
 */
export function classify(date: string): Form {
  if (!date) return "unknown";
  if (/Z$/.test(date) || /[+-]\d{2}:\d{2}$/.test(date)) return "utc-z";
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}$/.test(date)) {
    return "floating-micros";
  }
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d{1,3})?$/.test(date)) {
    return "floating";
  }
  return "unknown";
}

/**
 * UTC-строка → те же стенные часы Баку, плавающим видом.
 *
 * Допущение названо явно: запись создавалась в Баку (UTC+4 круглый год,
 * перевод часов отменён в 2016). Ровно то же допущение уже применялось при
 * миграции `clearedBy` 02.08, и оно ровно то, при котором значения
 * работали до сих пор: приложением пользуются два человека, оба в Баку.
 *
 * Если бы пояс создания был неизвестен, миграцию делать было бы нельзя —
 * неполное знание не даёт права переписывать.
 */
export function utcToBakuFloating(iso: string): string {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return iso;
  const shifted = new Date(ms + BAKU_OFFSET_HOURS * 60 * 60 * 1000);
  return shifted.toISOString().slice(0, 19);
}

function nowBakuIso(): string {
  return new Date(Date.now() + BAKU_OFFSET_HOURS * 60 * 60 * 1000)
    .toISOString().slice(0, 19);
}

async function main() {
  const migrate = process.argv.includes("--migrate");
  const snap = await db.collection("personalEvents").get();
  const now = nowBakuIso();

  const counts: Record<Form, number> = {
    "utc-z": 0, floating: 0, "floating-micros": 0, unknown: 0,
  };
  const futureCounts: Record<Form, number> = {
    "utc-z": 0, floating: 0, "floating-micros": 0, unknown: 0,
  };
  const candidates: { id: string; before: string; after: string;
    type: string; status: string }[] = [];

  for (const doc of snap.docs) {
    const d = doc.data();
    const date = (d.date as string) ?? "";
    const form = classify(date);
    counts[form] += 1;

    // «В будущем» считается по ТОМУ ЖЕ правилу, каким пользуется функция
    // напоминаний: сравнение строк с бакинскими стенными часами. Для
    // UTC-записи это даёт её собственную (неверную) трактовку — и это
    // намеренно: важно, промахнётся ли напоминание, а не как оно
    // выглядело бы после починки.
    const isFuture = date > now;
    if (isFuture) futureCounts[form] += 1;

    if (form === "utc-z" && isFuture) {
      candidates.push({
        id: doc.id,
        before: date,
        after: utcToBakuFloating(date),
        type: (d.type as string) ?? "",
        status: (d.status as string) ?? "",
      });
    }
  }

  console.log(`Всего мероприятий: ${snap.size}`);
  console.log("\nПо форме записи (всего / из них в будущем):");
  for (const f of Object.keys(counts) as Form[]) {
    console.log(`  ${f.padEnd(16)} ${String(counts[f]).padStart(4)} / ${futureCounts[f]}`);
  }

  console.log(`\nКандидаты на миграцию (UTC-форма И в будущем): ${candidates.length}`);
  for (const c of candidates) {
    console.log(`  ${c.id}  ${c.type || "—"}  ${c.status}`);
    console.log(`      было:  ${c.before}`);
    console.log(`      стало: ${c.after}`);
  }

  if (!migrate) {
    console.log("\nБез --migrate не записано ничего.");
    return;
  }
  if (candidates.length === 0) {
    console.log("\nМенять нечего.");
    return;
  }
  for (const c of candidates) {
    // Пишется ТОЛЬКО поле date. Признак автора здесь намеренно не
    // ставится: это не действие человека, и уведомление «tədbir dəyişdi»
    // о технической правке разбудило бы людей ни за чем.
    await db.collection("personalEvents").doc(c.id).update({ date: c.after });
    console.log(`  переписано ${c.id}`);
  }
  console.log(`\nГотово: ${candidates.length}`);
}

main().then(() => process.exit(0)).catch((e) => {
  console.error(e);
  process.exit(1);
});
