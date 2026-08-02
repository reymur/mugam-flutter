// Сборщик осиротевших объектов Storage.
//
// Почему он вообще нужен и почему один на все случаи — см. AUDIT_TODO.md,
// «Диагностика сирот 02.08». Коротко: файл всегда заливается раньше
// документа (Storage и Firestore не делят транзакцию), а единственная
// имеющаяся чистилка (onStatusDeleted) привязана к удалению документа —
// объект, у которого документа никогда не было, для неё недостижим
// навсегда. B11 (медиа чатов), backlog статусов и половина B19/B21
// (отменённая загрузка) — одна и та же сирота, поэтому механизм один.
//
// Определение сироты здесь ровно одно: **на объект не ссылается ни один
// документ, и он старше окна ожидания**. Никакой опоры на metadata
// (uploaderUid/statusId/chatId) — она говорит, кто и куда заливал, но не
// говорит, дошёл ли документ.
//
// Идемпотентен по построению (проверка ссылок, потом удаление), поэтому
// повторный запуск и параллельная живая загрузка ему безопасны — это
// требование к любому переносу клиент→сервер в этом проекте, см. тот же
// реестр.

import { logger } from "firebase-functions";
import type { Bucket, File } from "@google-cloud/storage";
import type { Firestore, QueryDocumentSnapshot } from "firebase-admin/firestore";

// Окно ожидания между заливкой файла и появлением документа. Реальный
// разрыв — секунды: очередь отправки роняет загрузку по таймауту через
// 60 с (pendingQueueUploadTimeout, background_queue_processor.dart), и
// документ пишется сразу после `await task`. Сутки взяты не как оценка
// разрыва, а как запас на порядки больше него: цена ошибки несимметрична
// (лишний день хранения стоит копейки, удалённое живое медиа не
// восстановить).
export const DEFAULT_MIN_AGE_MS = 24 * 60 * 60 * 1000;

// Подметаются только те префиксы, где имя объекта уникально на каждую
// загрузку, — именно они и текут:
//   statuses/{ownerUid}/{fileName}   — 35 сирот / 110 МБ на 02.08
//   chats/{chatId}/{fileName}        — 3 сироты / 2.5 МБ
// avatars/{uid}.jpg и groups/{chatId}/avatar.jpg сюда намеренно не
// входят: имя фиксировано, объект перезаписывается, накопление
// невозможно по построению — чинить там нечего, а любая ошибка сборщика
// стоила бы пользователю аватара.
const SWEPT_PREFIXES = ["chats/", "statuses/"] as const;

// Только плоская форма из трёх сегментов. Вложенные пути mugam-v2
// (chats/{chatId}/images|voice/{fileName}, четыре сегмента) не трогаются
// — то же ограничение и по той же причине, что у onChatMediaUploaded:
// это чужое приложение, его схему ссылок здесь никто не проверял.
function isSweptPath(path: string): boolean {
  if (!SWEPT_PREFIXES.some((p) => path.startsWith(p))) return false;
  return path.split("/").length === 3;
}

// Firebase Storage download URL кодирует полный путь объекта между "/o/"
// и query-строкой. Тот же разбор, что у storagePathFromDownloadUrl в
// index.ts, — но здесь он применяется не к одному известному полю, а ко
// всем строкам документа подряд (см. collectPathsFromValue).
function pathsFromString(value: string, into: Set<string>): void {
  const match = value.match(/\/o\/([^?]+)/);
  if (match) {
    try {
      into.add(decodeURIComponent(match[1]));
    } catch {
      // Битая процентная последовательность в URL — не повод падать на
      // всём проходе; такой объект просто не будет считаться
      // упомянутым... поэтому добавляем ещё и сырую форму, чтобы
      // ссылка не потерялась молча.
      into.add(match[1]);
    }
  }
  // Сырой путь без URL — так его пишут mediaOriginChatId/mediaFileName и
  // возврат copyMediaToStatus (`path`). Дёшево и снимает зависимость от
  // того, в каком виде поле сохранили.
  if (isSweptPath(value)) into.add(value);
}

// Ссылки собираются обходом ВСЕХ строковых значений документа, а не
// перечислением известных полей. Полей много и они разъезжаются:
// imageURL/audioURL/videoURL/fileURL/locationImageURL, replyTo*, mediaUrl
// у статуса, mediaFileName + mediaOriginChatId парой. Забытое поле здесь
// означает удаление живого медиа, поэтому список полей — неподходящий
// инструмент: обход по значениям не может устареть вслед за схемой.
function collectPathsFromValue(value: unknown, into: Set<string>): void {
  if (typeof value === "string") {
    pathsFromString(value, into);
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectPathsFromValue(item, into);
    return;
  }
  if (value && typeof value === "object") {
    for (const item of Object.values(value as Record<string, unknown>)) {
      collectPathsFromValue(item, into);
    }
  }
}

// Пара (mediaOriginChatId, mediaFileName) — единственная ссылка, которая
// не является строкой пути целиком: её половинки лежат в разных полях, и
// пересланное сообщение несёт их через все чаты (forwardMessage,
// firestore_service.dart). Собирается явно поверх общего обхода.
function collectSplitMediaRef(data: Record<string, unknown>, into: Set<string>): void {
  const chatId = data.mediaOriginChatId;
  const fileName = data.mediaFileName;
  if (typeof chatId === "string" && typeof fileName === "string" && chatId && fileName) {
    into.add(`chats/${chatId}/${fileName}`);
  }
}

interface HarvestResult {
  paths: Set<string>;
  scannedDocs: number;
}

// validatedUploads — это отметка о ЗАЛИВКЕ, а не ссылка на объект
// (onChatMediaUploaded пишет её на finalize, до и независимо от того,
// появится ли документ сообщения). Считать её ссылкой значило бы
// объявить каждый залитый объект вечно нужным и превратить сборщик в
// no-op ровно на тех сиротах, ради которых он написан. Пути в её полях
// не лежат, имя файла — в id документа, а id здесь не разбираются, так
// что пропуск ещё и экономит чтения.
const NOT_A_REFERENCE_COLLECTIONS = new Set(["validatedUploads"]);

// Множество ссылок строится ГЛОБАЛЬНО — по всей базе, а не по владельцу
// объекта и не по списку коллекций, где ссылки «должны» лежать.
//
// Глобально по чатам — обязательное условие, а не запас прочности:
// forwardMessage переиспользует URL исходного сообщения, то есть
// сообщение в чате B штатно ссылается на объект под chats/A/...; разбор
// по чатам удалил бы медиа у всех, кому переслали.
//
// По всей базе — по итогу проверки 02.08: в проде 805 документов в 8
// корневых коллекциях, а список «где ссылки бывают» (messages, statuses,
// chats, users) покрывал 319 из них. agreements, personalEvents, invites
// не смотрелись вовсе. Список коллекций устаревает ровно так же, как
// список полей (см. collectPathsFromValue), и цена та же — удалённое
// живое медиа, поэтому здесь тоже обход, а не перечисление.
//
// Масштаб: обход стоит одно чтение на документ плюс один listCollections
// на документ. На нынешних ~800 документах это секунды и доли цента, на
// сотне тысяч — уже нет. Порог, за которым эту схему надо менять на
// обратный индекс путей, отмечен предупреждением в логе ниже.
const HARVEST_SCALE_WARN_DOCS = 20000;

async function harvestReferencedPaths(db: Firestore): Promise<HarvestResult> {
  const paths = new Set<string>();
  let scannedDocs = 0;

  const scanCollection = async (ref: FirebaseFirestore.CollectionReference): Promise<void> => {
    if (NOT_A_REFERENCE_COLLECTIONS.has(ref.id)) return;
    const PAGE_SIZE = 500;
    let lastDoc: QueryDocumentSnapshot | undefined;
    for (;;) {
      let query: FirebaseFirestore.Query = ref.orderBy("__name__").limit(PAGE_SIZE);
      if (lastDoc) query = query.startAfter(lastDoc);
      const snap = await query.get();
      if (snap.empty) break;
      for (const doc of snap.docs) {
        const data = doc.data();
        collectPathsFromValue(data, paths);
        collectSplitMediaRef(data, paths);
        scannedDocs++;
        for (const sub of await doc.ref.listCollections()) {
          await scanCollection(sub);
        }
      }
      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.docs.length < PAGE_SIZE) break;
    }
  };

  for (const root of await db.listCollections()) {
    await scanCollection(root);
  }

  if (scannedDocs > HARVEST_SCALE_WARN_DOCS) {
    logger.warn(
      "orphanSweep: full-database harvest is outgrowing its design — " +
        "replace it with a reverse index of storage paths before it gets slower",
      { scannedDocs },
    );
  }
  logger.info(`orphanSweep: scanned ${scannedDocs} docs across the whole database`);

  return { paths, scannedDocs };
}

export interface OrphanObject {
  path: string;
  sizeBytes: number;
  createdAt: string;
}

export interface SweepResult {
  scannedObjects: number;
  scannedDocs: number;
  referencedPaths: number;
  skippedTooYoung: number;
  skippedNotSwept: number;
  orphans: OrphanObject[];
  orphanBytes: number;
  deleted: number;
  deleteFailures: number;
}

export interface SweepOptions {
  db: Firestore;
  bucket: Bucket;
  // false — реальное удаление. По умолчанию сборщик ничего не удаляет:
  // право снести файл включается явным аргументом на месте вызова, а не
  // достаётся ему по умолчанию.
  dryRun?: boolean;
  minAgeMs?: number;
  nowMs?: number;
}

export async function sweepOrphanMedia(opts: SweepOptions): Promise<SweepResult> {
  const { db, bucket } = opts;
  const dryRun = opts.dryRun ?? true;
  const minAgeMs = opts.minAgeMs ?? DEFAULT_MIN_AGE_MS;
  const nowMs = opts.nowMs ?? Date.now();

  const { paths: referenced, scannedDocs } = await harvestReferencedPaths(db);

  const files: File[] = [];
  for (const prefix of SWEPT_PREFIXES) {
    const [found] = await bucket.getFiles({ prefix });
    files.push(...found);
  }

  const result: SweepResult = {
    scannedObjects: files.length,
    scannedDocs,
    referencedPaths: referenced.size,
    skippedTooYoung: 0,
    skippedNotSwept: 0,
    orphans: [],
    orphanBytes: 0,
    deleted: 0,
    deleteFailures: 0,
  };

  // Пустой результат обхода — это «не знаю», а не «ничего не
  // ссылается». Тот же класс ошибки, по которому в этом проекте уже
  // прошлись отдельно (AUDIT_TODO.md, «пустой снимок принят за
  // содержательный ответ»), только здесь цена — весь бакет разом:
  // упавший на середине или обрезанный правами обход выглядит ровно как
  // «ссылок нет». Поэтому ноль прочитанных документов при непустом
  // бакете — отказ работать, а не разрешение всё удалить.
  if (scannedDocs === 0 && files.length > 0) {
    logger.error(
      "orphanSweep: aborting — 0 documents scanned while the bucket is not empty; " +
        "an empty scan is 'unknown', never 'nothing is referenced'",
      { scannedObjects: files.length },
    );
    return result;
  }

  for (const file of files) {
    if (!isSweptPath(file.name)) {
      result.skippedNotSwept++;
      continue;
    }
    if (referenced.has(file.name)) continue;

    const created = file.metadata.timeCreated;
    const createdMs = created ? Date.parse(created) : NaN;
    // Объект без разбираемой даты создания считается свежим: неизвестный
    // возраст не повод удалять.
    if (!Number.isFinite(createdMs) || nowMs - createdMs < minAgeMs) {
      result.skippedTooYoung++;
      continue;
    }

    const sizeBytes = Number(file.metadata.size ?? 0);
    result.orphans.push({
      path: file.name,
      sizeBytes,
      createdAt: created ?? "unknown",
    });
    result.orphanBytes += sizeBytes;

    if (!dryRun) {
      try {
        await file.delete();
        result.deleted++;
      } catch (e) {
        result.deleteFailures++;
        logger.warn("orphanSweep: delete failed", { path: file.name, error: e });
      }
    }
  }

  logger.info("orphanSweep: done", {
    dryRun,
    scannedObjects: result.scannedObjects,
    scannedDocs: result.scannedDocs,
    referencedPaths: result.referencedPaths,
    orphans: result.orphans.length,
    orphanBytes: result.orphanBytes,
    deleted: result.deleted,
    deleteFailures: result.deleteFailures,
  });

  return result;
}
