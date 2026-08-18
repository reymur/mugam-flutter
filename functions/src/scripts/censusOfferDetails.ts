// Перепись формы документов `chats/{chatId}/offers/{offerId}` — сколько из
// них написаны СТАРОЙ формой (три плоских поля) и сколько новой (`details`).
// ТОЛЬКО ЧТЕНИЕ.
//
// --- ЗАЧЕМ ---
//
// N139: писатель ушёл вперёд без читателя. 14.08 (`71d2ae9`) создание
// предложения перестало писать `eventTime`/`eventLocation`/`eventNotes` и
// начало писать карту `details` по дням; читатель `JobOffer.fromMap`
// остался на трёх старых полях и починен только 19.08.
//
// Вопрос, на который отвечает эта перепись: **есть ли в проде документы
// СТАРОЙ формы**, то есть созданные между заведением подколлекции (13.08,
// набор правил `6fceb8b2`) и сменой формы (14.08, набор `2a8410bb`). У
// таких документов новый читатель не найдёт деталей — он спрашивает
// `details`, а там три плоских поля.
//
// **Чинить по итогу ЗАПРЕЩЕНО этим заходом** (указание владельца 19.08):
// перепись приносит число, решение принимается отдельно. Скрипт ничего не
// пишет и не может — ни одного вызова записи в нём нет.
//
// --- ГЛАВНОЕ ПРО НОЛЬ (I37) ---
//
// «Старых ноль» само по себе не доказывает ничего: у нуля нет
// отличительного значения, и он одинаково выглядит при исправной проверке
// и при проверке, которая ничего не разобрала. Поэтому рядом с нулём
// ВСЕГДА печатается знаменатель:
//
//   «старых 0 при 7 предложениях в 12 чатах» — проверяемо;
//   «старых 0»                               — нет.
//
// **И отдельная канарейка**: сколько документов несут `createdBy`. Это
// поле обязано быть у КАЖДОГО предложения — правило создания без него не
// пропустит. Ноль по нему означает не «предложений нет», а «разбор не
// видит документов» (I31), и тогда все прочие числа — мусор.
//
// --- ЧЕТЫРЕ ФОРМЫ, А НЕ ДВЕ, И РАЗЛИЧАТЬ ИХ ОБЯЗАТЕЛЬНО (I47) ---
//
//   НОВАЯ    — есть `details`, трёх старых полей нет. Ожидаемое.
//   СТАРАЯ   — есть хоть одно из трёх старых, `details` нет. То, что ищем.
//   ОБЕ      — есть и то и другое. Не должно существовать: правило
//              `hasOnly` такого не пропустит ни в одной из двух редакций.
//              Появится — значит писал не наш клиент.
//   НИ ОДНОЙ — нет ни `details`, ни трёх старых. Законно: предложение, где
//              работодатель не вписал ни одной подробности, `details` не
//              получает вовсе (дни без подробностей в карту не попадают).
//
// Свести «СТАРАЯ» и «НИ ОДНОЙ» в один ответ значило бы потерять разницу
// между поломкой и нормой — ровно то, от чего предостерегает I47.
//
// --- КАК ЗАПУСКАТЬ ---
//   gcloud auth application-default login   (один раз)
//   из functions/:  npm run build && node lib/scripts/censusOfferDetails.js

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

const OLD_FIELDS = ["eventTime", "eventLocation", "eventNotes"] as const;

type Form = "новая" | "СТАРАЯ" | "ОБЕ" | "ни одной";

function formOf(data: FirebaseFirestore.DocumentData): Form {
  const hasNew = data.details !== undefined;
  const hasOld = OLD_FIELDS.some((f) => data[f] !== undefined);
  if (hasNew && hasOld) return "ОБЕ";
  if (hasNew) return "новая";
  if (hasOld) return "СТАРАЯ";
  return "ни одной";
}

async function main(): Promise<void> {
  const chats = await db.collection("chats").get();

  let offersTotal = 0;
  let chatsWithOffers = 0;
  let withCreatedBy = 0;
  const byForm: Record<Form, number> = {
    "новая": 0,
    "СТАРАЯ": 0,
    "ОБЕ": 0,
    "ни одной": 0,
  };
  // Старые и «обе» — поимённо, а не числом: список врёт заметно, он
  // называет, кого назвал (I57). По этим адресам решение и принимается.
  const named: string[] = [];

  for (const chat of chats.docs) {
    const offers = await chat.ref.collection("offers").get();
    if (offers.empty) continue;
    chatsWithOffers += 1;

    for (const offer of offers.docs) {
      offersTotal += 1;
      const data = offer.data();
      if (typeof data.createdBy === "string") withCreatedBy += 1;

      const form = formOf(data);
      byForm[form] += 1;
      if (form === "СТАРАЯ" || form === "ОБЕ") {
        named.push(`${form}  chats/${chat.id}/offers/${offer.id}`);
      }
    }
  }

  console.log("=== ПЕРЕПИСЬ ФОРМЫ ПРЕДЛОЖЕНИЙ (только чтение) ===");
  console.log(`чатов просмотрено:            ${chats.size}`);
  console.log(`из них с предложениями:       ${chatsWithOffers}`);
  console.log(`предложений всего:            ${offersTotal}`);
  console.log(
    `КАНАРЕЙКА, createdBy есть у:  ${withCreatedBy} из ${offersTotal}` +
      (offersTotal > 0 && withCreatedBy === 0
        ? "   <-- РАЗБОР НЕ ВИДИТ ДОКУМЕНТОВ, числа ниже читать нельзя"
        : ""),
  );
  console.log("---");
  console.log(`новая форма (details):        ${byForm["новая"]}`);
  console.log(`СТАРАЯ форма (три поля):      ${byForm["СТАРАЯ"]}`);
  console.log(`ОБЕ сразу (не должно быть):   ${byForm["ОБЕ"]}`);
  console.log(`ни одной (подробностей нет):  ${byForm["ни одной"]}`);

  const sum =
    byForm["новая"] + byForm["СТАРАЯ"] + byForm["ОБЕ"] + byForm["ни одной"];
  // Разбиение обязано сходиться с целым — два правдоподобных числа
  // ловятся только сложением между ними и третьим местом (I13).
  console.log(
    `сумма по формам:              ${sum}` +
      (sum === offersTotal ? "  (сходится)" : "  <-- НЕ СХОДИТСЯ С ЦЕЛЫМ"),
  );

  if (named.length > 0) {
    console.log("---");
    console.log("поимённо:");
    for (const line of named) console.log(`  ${line}`);
  }
}

main().catch((e) => {
  console.error("перепись не доехала:", e);
  process.exit(1);
});
