// Разовый прогон сборщика сирот по боевому проекту.
//
// В git есть, в деплой не попадает: файл не импортируется из index.ts,
// поэтому `firebase deploy --only functions` его не видит — тот же
// приём, что у algoliaBackfill.ts рядом.
//
// --- Как запускать ---
// 1. Аутентификация Admin SDK для разового скрипта (в рантайме функций
//    сервисный аккаунт есть сам по себе, здесь его нет):
//      gcloud auth application-default login
// 2. Из functions/:
//      npm run build
//      node lib/scripts/orphanSweep.js            # только отчёт, ничего не удаляет
//      node lib/scripts/orphanSweep.js --delete   # удаление, после сверки отчёта
//
// Без --delete не удаляет ничего. Повторный запуск безопасен: сборщик
// идемпотентен по построению (проверка ссылок, потом удаление).

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { sweepOrphanMedia, DEFAULT_MIN_AGE_MS } from "../orphanSweep";

const PROJECT_ID = "mugam-club"; // как "default" в .firebaserc
const BUCKET = "mugam-club.firebasestorage.app";

function formatMb(bytes: number): string {
  return `${(bytes / 1024 / 1024).toFixed(1)} МБ`;
}

async function main() {
  const dryRun = !process.argv.includes("--delete");

  initializeApp({
    credential: applicationDefault(),
    projectId: PROJECT_ID,
    storageBucket: BUCKET,
  });

  console.log(
    dryRun
      ? "Режим: только отчёт (ничего не удаляется). Для удаления — флаг --delete."
      : "Режим: УДАЛЕНИЕ. Объекты будут снесены безвозвратно.",
  );
  console.log(`Окно ожидания: ${DEFAULT_MIN_AGE_MS / 3600000} ч\n`);

  const result = await sweepOrphanMedia({
    db: getFirestore(),
    bucket: getStorage().bucket(BUCKET),
    dryRun,
  });

  // Разбивка по префиксу — в отчёте она и есть главное: реестр ожидал
  // сирот только в медиа чатов, а 69% Storage оказалось в статусах.
  const byPrefix = new Map<string, { count: number; bytes: number }>();
  for (const orphan of result.orphans) {
    const prefix = orphan.path.split("/")[0];
    const entry = byPrefix.get(prefix) ?? { count: 0, bytes: 0 };
    entry.count++;
    entry.bytes += orphan.sizeBytes;
    byPrefix.set(prefix, entry);
  }

  console.log(`Объектов в подметаемых префиксах: ${result.scannedObjects}`);
  console.log(`Документов просмотрено:           ${result.scannedDocs}`);
  console.log(`Ссылок на объекты найдено:        ${result.referencedPaths}`);
  console.log(`Пропущено (моложе окна):          ${result.skippedTooYoung}`);
  console.log(`Пропущено (не наша форма пути):   ${result.skippedNotSwept}`);
  console.log(`\nСирот: ${result.orphans.length} на ${formatMb(result.orphanBytes)}`);
  for (const [prefix, entry] of byPrefix) {
    console.log(`  ${prefix}/ — ${entry.count} шт, ${formatMb(entry.bytes)}`);
  }

  if (result.orphans.length > 0) {
    console.log("\nСписок:");
    for (const orphan of result.orphans) {
      console.log(
        `  ${orphan.createdAt}  ${formatMb(orphan.sizeBytes).padStart(9)}  ${orphan.path}`,
      );
    }
  }

  if (!dryRun) {
    console.log(`\nУдалено: ${result.deleted}, ошибок удаления: ${result.deleteFailures}`);
  }
}

main().catch((e) => {
  console.error("Прогон сборщика упал:", e);
  process.exit(1);
});
