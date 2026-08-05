// Перепись мероприятий — ТОЛЬКО ЧТЕНИЕ, ничего не пишет.
//
// Зачем. Правило I6 требует: запись-инструкция к прогону, названная по
// живым данным, обязана называть, ЧЕМ эти данные снять заново. Иначе
// датировка спасает её лишь наполовину — прогон меняет ровно те документы,
// которые в нём поимённо названы, то есть уничтожает свои данные по мере
// исполнения. Этот скрипт и есть тот «чем» для прогона N39/N40.
//
// Считает ТЕМ ЖЕ правилом, что приложение (`conflictEventsOnDay`,
// lib/shared/widgets/event_conflict_banner.dart): свои плюс те, где человек
// участник; дедуп по id; отменённые не в счёт; без даты не в счёт.
// Разойтись правилам нельзя — иначе скрипт покажет одно число, а плашка в
// приложении другое, и расхождение примут за дефект приложения.
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/censusEvents.js                 # кто есть, с числами
//     node lib/scripts/censusEvents.js <uidA> <uidB>   # разбор по дням

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

initializeApp({ credential: applicationDefault(), projectId: "mugam-club" });
const db = getFirestore();

interface EventRow {
  id: string;
  ownerUid?: string;
  date?: string;
  type?: string;
  location?: string;
  musicians?: string[];
  isAgree?: boolean;
  status?: string;
}

function dayOf(iso: string | undefined): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso ?? "");
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

function timeOf(iso: string | undefined): string {
  const m = /[T ](\d{2}):(\d{2})/.exec(iso ?? "");
  return m ? `${m[1]}:${m[2]}` : "--:--";
}

/** Ровно правило приложения — свои ИЛИ где участник, без отменённых. */
function visibleTo(all: EventRow[], uid: string): EventRow[] {
  const seen = new Set<string>();
  return all.filter((e) => {
    if (e.ownerUid !== uid && !(e.musicians ?? []).includes(uid)) return false;
    if (e.status === "cancelled") return false;
    if (!e.date) return false;
    if (seen.has(e.id)) return false;
    seen.add(e.id);
    return true;
  });
}

function byDay(rows: EventRow[]): Map<string, EventRow[]> {
  const out = new Map<string, EventRow[]>();
  for (const e of rows) {
    const day = dayOf(e.date);
    if (!day) continue;
    if (!out.has(day)) out.set(day, []);
    out.get(day)!.push(e);
  }
  return out;
}

async function main(): Promise<void> {
  const targets = process.argv.slice(2);

  const names = new Map<string, string>();
  for (const d of (await db.collection("users").get()).docs) {
    const v = d.data();
    names.set(d.id, (v.name as string) ?? (v.displayName as string) ?? d.id.slice(0, 8));
  }

  const all: EventRow[] = (await db.collection("personalEvents").get()).docs.map(
    (d) => ({ id: d.id, ...(d.data() as Omit<EventRow, "id">) }),
  );

  console.log(`\nснято ${new Date().toISOString()}`);
  console.log(`всего мероприятий в проде: ${all.length}\n`);

  if (targets.length === 0) {
    console.log("uid не переданы. Люди, у которых есть мероприятия:");
    const counts = new Map<string, number>();
    for (const e of all) {
      for (const uid of new Set([e.ownerUid, ...(e.musicians ?? [])])) {
        if (!uid) continue;
        counts.set(uid, (counts.get(uid) ?? 0) + 1);
      }
    }
    for (const [uid, n] of [...counts.entries()].sort((a, b) => b[1] - a[1])) {
      console.log(`  ${uid}  ${names.get(uid) ?? "?"}  — ${n}`);
    }
    console.log("\nдальше: node lib/scripts/censusEvents.js <uidA> <uidB>\n");
    return;
  }

  for (const uid of targets) {
    const mine = visibleTo(all, uid);
    console.log(`\n=== ${names.get(uid) ?? uid}  (${uid}) — ${mine.length} шт.`);
    const days = byDay(mine);
    for (const day of [...days.keys()].sort()) {
      const list = days
        .get(day)!
        .sort((a, b) => timeOf(a.date).localeCompare(timeOf(b.date)));
      console.log(`  ${day}  — ${list.length} шт.`);
      for (const e of list) {
        const own =
          e.ownerUid === uid ? "своё " : `чужое(${names.get(e.ownerUid ?? "") ?? e.ownerUid})`;
        const people = (e.musicians ?? [])
          .map((u) => names.get(u) ?? u.slice(0, 6))
          .join(", ");
        console.log(
          `     ${timeOf(e.date)}  ${e.id}  ${own}  ${e.type ?? "?"}  ` +
            `${e.location ?? ""}${e.isAgree ? " ДОГОВОР" : ""}  участники=[${people}]`,
        );
      }
    }
  }

  // Дни, годные под проверки #7 (переключатель) и #8 (дедуп) списка N27.
  console.log("\n--- кандидаты под #7 (переключатель) и #8 (дедуп) ---");
  for (const uid of targets) {
    const mine = visibleTo(all, uid);
    for (const [day, list] of byDay(mine)) {
      if (list.length < 2) continue;
      const times = list.map((e) => timeOf(e.date)).sort();
      console.log(
        `  ${names.get(uid) ?? uid}: ${day} — ${list.length} шт., времена ${times.join(", ")}`,
      );
    }
    // Владелец, числящийся и в собственном `musicians`, приходит ОБОИМИ
    // потоками — кандидат на двойной счёт в плашке (проверка #8).
    const doubles = mine.filter(
      (e) => e.ownerUid === uid && (e.musicians ?? []).includes(uid),
    );
    if (doubles.length > 0) {
      console.log(
        `  ${names.get(uid) ?? uid}: кандидаты на двойной счёт — ` +
          doubles.map((e) => `${dayOf(e.date)} ${timeOf(e.date)} ${e.id}`).join("; "),
      );
    }
  }
  console.log("");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
