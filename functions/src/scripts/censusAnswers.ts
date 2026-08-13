// Перепись расхождений `answers` с составом — шаг 2 работы «договоры и
// мероприятия — одна сущность» (docs/plan.md). ТОЛЬКО ЧТЕНИЕ.
//
// --- ЗАЧЕМ ---
//
// Шаг 1 завёл поле `answers` (карта uid → ответ) рядом с `musicians`. Шаг 2
// доказывает, что запись и чтение понимают старые записи ОДИНАКОВО. Первое
// доказательство — круговой тест в test/event_answers_test.dart; второе —
// эта перепись, на живых данных.
//
// --- ГЛАВНОЕ ПРО НОЛЬ (I37) ---
//
// «Расхождений ноль» САМО ПО СЕБЕ не доказывает ничего: у нуля нет
// отличительного значения, и он одинаково выглядит при исправной проверке и
// при проверке, которая ничего не разобрала. Поэтому рядом с нулём ВСЕГДА
// печатается число с личностью — сколько документов прочитано и сколько из
// них вообще несут поле.
//
//   «расхождений 0 при 75 документах» — проверяемо;
//   «расхождений 0»                   — нет.
//
// Сегодняшняя база, снятая 10.08 до выкладки: документов 75, из них с полем
// `answers` — 0. То есть перепись обязана напечатать «с полем: 0», и это НЕ
// зелёный вердикт, а исходная точка: пока клиент не выложен, расходиться
// нечему.
//
// --- ТРИ ВИДА РАСХОЖДЕНИЯ, И ОНИ РАЗНОЙ ЦЕНЫ ---
//
//   НЕДОСТАЧА (в составе есть, в карте нет) — ОЖИДАЕМА. Так пишут старые
//   сборки клиента и mugam-v2: они правят `musicians`, не зная про поле.
//   Считается и печатается, но тревогой не является.
//
//   ИЗБЫТОК (ключ вне состава) — ОЖИДАЕМ. Правило leavesEvent() разрешает
//   трогать только `musicians`, и ключ ушедшего в карте остаётся.
//
//   ПУСТАЯ КАРТА ПРИ НЕПУСТОМ СОСТАВЕ — НЕ ОЖИДАЕМА НИ ОТ КОГО. И клиент, и
//   сервер пишут карту целиком по составу. Это единственный по-настоящему
//   тревожный вид, и его число обязано быть нулём.
//
// Правило разбора здесь повторено с Dart (core/agreements/event_answers.dart)
// — импортировать через границу нечего. Цена названа вслух: это ВТОРОЙ
// читатель того же правила, и разойтись они могут молча.
//
// --- КАК ЗАПУСКАТЬ ---
//   gcloud auth application-default login   (один раз)
//   из functions/:  npm run build && node lib/scripts/censusAnswers.js

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

type Mismatch = {
  missing: string[];
  extra: string[];
  emptyWithPeople: boolean;
};

/** Поле есть, но это НЕ карта — мусор, а не сведения. Считается отдельно. */
export function isNotAMap(answers: unknown): boolean {
  return (
    answers !== undefined &&
    answers !== null &&
    (typeof answers !== "object" || Array.isArray(answers))
  );
}

function answersMismatch(
  participantUids: unknown,
  answers: unknown,
): Mismatch | null {
  // Поля НЕТ — не расхождение, а отсутствие сведений. Свести его с пустой
  // картой значило бы потерять возможность отличить поломку от нормы (I47).
  if (answers === undefined || answers === null) return null;
  // Не карта — считается своей графой выше по вызову, здесь разбирать нечего.
  if (isNotAMap(answers)) return null;
  const people = new Set(
    (Array.isArray(participantUids) ? participantUids : []).filter(
      (u): u is string => typeof u === "string" && u.length > 0,
    ),
  );
  const keys = new Set(Object.keys(answers as Record<string, unknown>));
  return {
    missing: [...people].filter((u) => !keys.has(u)).sort(),
    extra: [...keys].filter((u) => !people.has(u)).sort(),
    emptyWithPeople: keys.size === 0 && people.size > 0,
  };
}

(async () => {
  const users = new Map<string, string>();
  for (const d of (await db.collection("users").get()).docs) {
    users.set(d.id, (d.data().name as string) || "(без имени)");
  }
  const nameOf = (uid: string) => users.get(uid) || uid.slice(0, 8);

  const snap = await db.collection("personalEvents").get();

  let withField = 0;
  let clean = 0;
  const missing: string[] = [];
  const extra: string[] = [];
  const emptyWithPeople: string[] = [];

  const notAMap: string[] = [];

  // --- ДОБАВЛЕНО 12.08: ТРЕТИЙ ИСХОД `answerFor` (шаг 1 работы «показ
  // приглашений в календаре») ---
  //
  // Считается ЗДЕСЬ, а не отдельной переписью, нарочно: тот же проход и тот
  // же знаменатель. Две переписи одной коллекции разошлись бы молча, и
  // сверять их было бы нечем (N74, N80).
  //
  // ВОПРОС, НА КОТОРЫЙ ОТВЕЧАЕТ ЭТОТ СЧЁТ. `answerFor` (клиент,
  // models.dart:1222 → answerOf) при отсутствии ключа смотрит на отметку
  // `answersWrittenByOwner`:
  //
  //   отметка ЕСТЬ → `notAsked` — «позвать должен владелец», приглашением
  //                   не является;
  //   отметки НЕТ  → запасной путь даёт **`going`**.
  //
  // Значит человек в составе старого документа **молча числится
  // согласившимся**, хотя его никто не спрашивал: день у него занят, а в
  // приглашениях он не появится никогда. Это и есть дыра работы, и её
  // размер до сегодня не был измерен ни разу (I57 — не «когда считали», а
  // «чем это считано»: ничем).
  //
  // Считаются ДВЕ вещи, потому что они отвечают на разные вопросы:
  //   документы без отметки — сколько записей ведут себя по-старому;
  //   пары (документ, человек) — скольким людям это молча приписало `going`.
  // Документ с пятью такими людьми и документ с одним — не одно и то же, а
  // документный счёт их не различает.
  let withOwnerFlag = 0;
  let withoutOwnerFlag = 0;
  let silentGoingPairs = 0;
  const silentGoingDocs: string[] = [];

  for (const doc of snap.docs) {
    const e = doc.data();
    // Мусор вместо карты — своя графа. Модель на клиенте приравнивает его к
    // отсутствию, чтобы не падал экран, и потому заметить его может только
    // перепись (I47: различать надо там, где решается «норма или поломка»).
    if (isNotAMap(e.answers)) {
      notAMap.push(`${doc.id} ${e.date ?? "(без даты)"} → ${typeof e.answers}`);
      continue;
    }
    // ТРЕТИЙ ИСХОД `answerFor` — СЧИТАЕТСЯ ЗДЕСЬ, ВЫШЕ `continue` ПО
    // ОТСУТСТВИЮ ПОЛЯ, и это не мелочь расположения. Документы БЕЗ поля
    // `answers` — как раз те старые записи, ради которых счёт и заводится;
    // поставь его ниже, и он посчитает всё, кроме предмета своего вопроса.
    const ownerFlag = e.answersWrittenByOwner === true;
    if (ownerFlag) {
      withOwnerFlag++;
    } else {
      withoutOwnerFlag++;
      // Кому запасной путь молча припишет `going`: человек есть в составе,
      // ключа в карте нет, отметки нет.
      //
      // ВЛАДЕЛЕЦ ИЗ СЧЁТА ИСКЛЮЧЁН, и это названо вслух, а не сделано молча:
      // `occupiesCalendarOf` отвечает за него `true` по `ownerUid` ДО чтения
      // ответа, значит на занятость его ключ не влияет никак. Считать его
      // здесь значило бы завысить число людьми, которым оно ничего не меняет.
      const keys = new Set(
        e.answers && typeof e.answers === "object" && !Array.isArray(e.answers)
          ? Object.keys(e.answers as Record<string, unknown>)
          : [],
      );
      const silent = (Array.isArray(e.musicians) ? e.musicians : [])
        .filter((u: unknown): u is string => typeof u === "string" && u.length > 0)
        .filter((u: string) => u !== e.ownerUid && !keys.has(u));
      if (silent.length) {
        silentGoingPairs += silent.length;
        silentGoingDocs.push(
          `${doc.id} ${e.date ?? "(без даты)"}: ${silent.map(nameOf).join(", ")}`,
        );
      }
    }

    const m = answersMismatch(e.musicians, e.answers);
    if (m === null) continue; // поля нет — считается отдельно, ниже
    withField++;
    if (!m.missing.length && !m.extra.length && !m.emptyWithPeople) {
      clean++;
      continue;
    }
    if (m.emptyWithPeople) {
      emptyWithPeople.push(`${doc.id} ${e.date ?? "(без даты)"}`);
    }
    if (m.missing.length) {
      missing.push(`${doc.id}: ${m.missing.map(nameOf).join(", ")}`);
    }
    if (m.extra.length) {
      extra.push(`${doc.id}: ${m.extra.map(nameOf).join(", ")}`);
    }
  }

  // ЧИСЛО С ЛИЧНОСТЬЮ ПЕРВЫМ, ноль после него — иначе ноль ничего не значит.
  console.log(`документов прочитано: ${snap.size}`);
  console.log(`  из них с полем answers: ${withField}`);
  console.log(`  без поля (норма для старых записей): ${snap.size - withField}`);
  console.log(`  с полем и БЕЗ расхождений: ${clean}`);
  console.log("");
  console.log(`ТРЕВОЖНОЕ — пустая карта при непустом составе: ${emptyWithPeople.length}`);
  for (const s of emptyWithPeople) console.log(`    ${s}`);
  console.log(`ТРЕВОЖНОЕ — поле есть, но это НЕ карта: ${notAMap.length}`);
  for (const s of notAMap) console.log(`    ${s}`);
  console.log(`ожидаемое — недостача (старые сборки, mugam-v2): ${missing.length}`);
  for (const s of missing) console.log(`    ${s}`);
  console.log(`ожидаемое — избыток (ключ ушедшего): ${extra.length}`);
  for (const s of extra) console.log(`    ${s}`);

  // --- ТРЕТИЙ ИСХОД `answerFor` — работа «показ приглашений в календаре» ---
  console.log("");
  console.log("--- ЗАПАСНОЙ ПУТЬ `going` (шаг 1 работы о приглашениях) ---");
  console.log(`с отметкой answersWrittenByOwner: ${withOwnerFlag}`);
  console.log(`БЕЗ отметки: ${withoutOwnerFlag}`);
  // СЛОЖЕНО ВСЛУХ (I13): два правдоподобных числа ловятся только третьим.
  // Слагаемых три, а не два — мусор вместо карты выходит из цикла раньше.
  const sum = withOwnerFlag + withoutOwnerFlag + notAMap.length;
  console.log(
    `  сходимость: ${withOwnerFlag} + ${withoutOwnerFlag} + ${notAMap.length} (не карта) ` +
      `= ${sum}, прочитано ${snap.size}` +
      (sum === snap.size ? " — сходится" : " — НЕ СХОДИТСЯ, счёт неверен"),
  );
  console.log("");
  console.log(
    `ПРИГЛАШЁННЫХ, кому запасной путь молча даёт going: ${silentGoingPairs} ` +
      `в ${silentGoingDocs.length} документах из ${snap.size}`,
  );
  console.log("  (владелец исключён — он занимает день по своему признаку)");
  // СОСТАВ, А НЕ ТОЛЬКО КОЛИЧЕСТВО (I13): недосчитать список незаметно
  // нельзя, он сам называет, кого не хватает.
  for (const s of silentGoingDocs) console.log(`    ${s}`);
  if (silentGoingPairs === 0) {
    console.log(
      "    ноль здесь читать ВМЕСТЕ с числами выше: при 0 документов без " +
        "отметки он означает «дыры нет», при ненулевом — «люди есть, но у " +
        "всех ключи на месте»",
    );
  }

  // Канарейка к самой переписи: пустая коллекция и сломанное чтение дают
  // одинаковые нули выше.
  if (snap.size === 0) {
    console.log("");
    console.log("ВНИМАНИЕ: прочитано НОЛЬ документов — это не ответ, а молчание");
  }
  // Сверка с числом, снятым до работы (docs/plan.md): 75 всего.
  console.log("");
  console.log(`сверка с базой 10.08: было 75 документов, сейчас ${snap.size}`);
})();
