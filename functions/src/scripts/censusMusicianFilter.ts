// Перепись: кого отсёк бы фильтр «только музыканты», если бы он был.
//
// Повод — пункт 6 (`docs/plan.md`): входу с главного экрана и из
// календаря нужен выбор ОДНОГО человека, и вопрос владельца был прямой —
// не отсечёт ли список «музыкантов» того, кто работу берёт, а музыкантом
// себя не отметил.
//
// ЧТО ВЫЯСНИЛОСЬ ДО ПЕРЕПИСИ, и почему она всё равно нужна:
// `musiciansProvider` и `allUsersProvider` — это ОДИН И ТОТ ЖЕ запрос,
// оба зовут `watchAllUsers()` без единого фильтра. То есть отсекать
// сегодня нечего вовсе. Перепись отвечает на другой вопрос — на тот,
// который встанет в день, когда имя `musiciansProvider` кто-нибудь
// «починит», добавив обещанный именем фильтр: СКОЛЬКО ЛЮДЕЙ ИСЧЕЗНЕТ ИЗ
// СПИСКА В ТОТ ДЕНЬ.
//
// Считаются оба возможных признака «музыкант», потому что заранее не
// известно, по какому именно стали бы фильтровать:
//   - `instrument` — плоская строка, её показывает карточка «Bacarıqlar»;
//   - `activityType`/структурированный выбор «Fəaliyyət növü» — то, что
//     заполняет отдельный экран.
// Расхождение между ними — это N86 с другой стороны, и число тут важнее
// рассуждения.
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/censusMusicianFilter.js
//
// Только чтение: скрипт ничего не пишет и ничего не удаляет.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID = "mugam-club";

function nonEmpty(v: unknown): boolean {
  return typeof v === "string" && v.trim().length > 0;
}

async function main(): Promise<void> {
  initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
  const db = getFirestore();
  const snap = await db.collection("users").get();

  let withInstrument = 0;
  let withActivity = 0;
  let withNeither = 0;
  let commaInInstrument = 0;
  const namesWithNeither: string[] = [];

  snap.docs.forEach((doc) => {
    const d = doc.data();
    const hasInstrument = nonEmpty(d.instrument) || nonEmpty(d.specialty);
    // `activityType` — КАРТА (`ActivityType.toMap()`), а не строка и не
    // массив. Первая редакция этого разбора проверяла строку и массив и
    // давала НОЛЬ по всем двенадцати — ровно тот ноль, который читается
    // как «признак никто не заполнил», а означает «разбор искал не то»
    // (I14). Поймано сверкой с `models.dart`, а не глазом на числе.
    const activity = d.activityType;
    const hasActivity =
      nonEmpty(activity) ||
      (Array.isArray(activity) && activity.length > 0) ||
      (typeof activity === "object" &&
        activity !== null &&
        Object.keys(activity as Record<string, unknown>).length > 0);

    if (hasInstrument) withInstrument += 1;
    if (hasActivity) withActivity += 1;
    if (!hasInstrument && !hasActivity) {
      withNeither += 1;
      namesWithNeither.push(
        `${doc.id} ${nonEmpty(d.name) ? String(d.name) : "(без имени)"}`
      );
    }
    if (typeof d.instrument === "string" && d.instrument.includes(",")) {
      commaInInstrument += 1;
    }
  });

  console.log(`Снято: ${new Date().toISOString()}`);
  console.log(`Всего документов в users: ${snap.size}`);
  console.log(`  с непустым instrument/specialty: ${withInstrument}`);
  console.log(`  с заполненным «Fəaliyyət növü»:  ${withActivity}`);
  console.log(`  БЕЗ обоих признаков:             ${withNeither}`);
  console.log(
    `  instrument со ЗАПЯТОЙ внутри (N86): ${commaInInstrument}`
  );
  if (namesWithNeither.length > 0) {
    console.log("\nКого отсёк бы фильтр «только музыканты»:");
    namesWithNeither.forEach((n) => console.log(`  ${n}`));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
