// Разовый прогон сборщика сирот по боевому проекту.
//
// В git есть, в деплой не попадает: файл не импортируется из index.ts,
// поэтому `firebase deploy --only functions` его не видит — тот же
// приём, что у algoliaBackfill.ts рядом. Регулярный прогон делает
// sweepOrphanMediaDaily (index.ts) через ту же точку входа; этот скрипт
// нужен для разовой чистки и для сверки «глазами» до/после.
//
// --- Как запускать ---
// 1. Аутентификация Admin SDK для разового скрипта (в рантайме функций
//    сервисный аккаунт есть сам по себе, здесь его нет):
//      gcloud auth application-default login
// 2. Из functions/:
//      npm run build
//      node lib/scripts/orphanSweep.js                        # только отчёт
//      node lib/scripts/orphanSweep.js --manifest ../docs/x.md # отчёт + файл со списком
//      node lib/scripts/orphanSweep.js --delete                # удаление, после сверки
//
// Без --delete не удаляет ничего. Повторный запуск безопасен: сборщик
// идемпотентен по построению (проверка ссылок, потом удаление).

import { writeFileSync } from "fs";
import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import type { Bucket } from "@google-cloud/storage";
import { runOrphanSweepAndRecord, DEFAULT_MIN_AGE_MS, type SweepResult } from "../orphanSweep";

const PROJECT_ID = "mugam-club"; // как "default" в .firebaserc
const BUCKET = "mugam-club.firebasestorage.app";

function formatMb(bytes: number): string {
  return `${(bytes / 1024 / 1024).toFixed(1)} МБ`;
}

function argValue(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

// Полный объём бакета, включая неподметаемые префиксы (avatars/,
// groups/) — чтобы «стало меньше на столько-то» можно было проверить
// снаружи, а не поверить отчёту сборщика на слово.
async function bucketTotals(bucket: Bucket): Promise<{ count: number; bytes: number }> {
  const [files] = await bucket.getFiles();
  let bytes = 0;
  for (const file of files) bytes += Number(file.metadata.size ?? 0);
  return { count: files.length, bytes };
}

function manifestMarkdown(result: SweepResult, mode: string, totals: { count: number; bytes: number }): string {
  // Сортировка по пути, а не по порядку листинга: файл кладётся в git, и
  // осмысленный diff между двумя прогонами важнее исходного порядка.
  const sorted = [...result.orphans].sort((a, b) => a.path.localeCompare(b.path));
  const lines: string[] = [];
  lines.push("# Сироты в Storage — список к удалению");
  lines.push("");
  lines.push(`Режим прогона: **${mode}**`);
  lines.push("");
  lines.push("Сохранено до удаления, чтобы через месяц было с чем сверяться, если");
  lines.push("окажется, что что-то пропало. Сирота здесь — объект, на который не");
  lines.push("ссылается ни один документ во всей базе и который старше окна");
  lines.push(`ожидания (${DEFAULT_MIN_AGE_MS / 3600000} ч). Как это считается — см. functions/src/orphanSweep.ts.`);
  lines.push("");
  lines.push("| Показатель | Значение |");
  lines.push("|---|---|");
  lines.push(`| Объектов в подметаемых префиксах | ${result.scannedObjects} |`);
  lines.push(`| Документов просмотрено (вся база) | ${result.scannedDocs} |`);
  lines.push(`| Ссылок на объекты найдено | ${result.referencedPaths} |`);
  lines.push(`| Пропущено как моложе окна | ${result.skippedTooYoung} |`);
  lines.push(`| Сирот | ${result.orphans.length} на ${formatMb(result.orphanBytes)} |`);
  lines.push(`| Всего в бакете на момент прогона | ${totals.count} объектов, ${formatMb(totals.bytes)} |`);
  lines.push("");
  lines.push("| Создан | Размер | Путь |");
  lines.push("|---|---|---|");
  for (const orphan of sorted) {
    lines.push(`| ${orphan.createdAt} | ${formatMb(orphan.sizeBytes)} | \`${orphan.path}\` |`);
  }
  lines.push("");
  return lines.join("\n");
}

async function main() {
  const dryRun = !process.argv.includes("--delete");
  const manifestPath = argValue("--manifest");

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

  const bucket = getStorage().bucket(BUCKET);
  const before = await bucketTotals(bucket);

  const result = await runOrphanSweepAndRecord({
    db: getFirestore(),
    bucket,
    dryRun,
    trigger: "script",
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

  if (result.stoppedEarly) {
    console.log(
      `\nПрогон свернулся досрочно: ${result.stopReason}; ` +
        `необработанных кандидатов — ${result.remainingCandidates}.`,
    );
  }

  if (result.orphans.length > 0) {
    console.log("\nСписок:");
    for (const orphan of result.orphans) {
      console.log(
        `  ${orphan.createdAt}  ${formatMb(orphan.sizeBytes).padStart(9)}  ${orphan.path}`,
      );
    }
  }

  if (manifestPath) {
    const mode = dryRun ? "только отчёт, до удаления" : "удаление";
    writeFileSync(manifestPath, manifestMarkdown(result, mode, before), "utf8");
    console.log(`\nСписок сохранён: ${manifestPath}`);
  }

  console.log(
    `\nБакет до прогона:  ${before.count} объектов, ${formatMb(before.bytes)}`,
  );
  if (!dryRun) {
    console.log(`Удалено: ${result.deleted}, ошибок удаления: ${result.deleteFailures}`);
    const after = await bucketTotals(bucket);
    console.log(`Бакет после:       ${after.count} объектов, ${formatMb(after.bytes)}`);
    console.log(
      `Освобождено:       ${before.count - after.count} объектов, ` +
        `${formatMb(before.bytes - after.bytes)}`,
    );
  }
}

main().catch((e) => {
  console.error("Прогон сборщика упал:", e);
  process.exit(1);
});
