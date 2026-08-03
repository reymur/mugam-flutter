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
//
// ---------------------------------------------------------------------
// ДВА УРОКА, КОТОРЫЕ ЗДЕСЬ ЗАПРЕЩЕНО «ОПТИМИЗИРОВАТЬ» ОБРАТНО
// ---------------------------------------------------------------------
// Оба стоили бы удалённого живого медиа, оба выглядят как лишняя работа,
// и оба найдены проверкой, а не чтением кода. Если возникает желание
// сузить любой из двух обходов — сначала перечитать этот блок.
//
// 1. Множество ссылок строится ГЛОБАЛЬНО по всем чатам, а не по
//    чату-владельцу объекта. Причина: forwardMessage (firestore_service
//    .dart) переиспользует URL исходного сообщения, поэтому сообщение в
//    чате B штатно ссылается на объект под chats/A/... Сузить обход до
//    «своего» чата — значит удалить медиа у всех, кому его переслали, и
//    в чате-владельце это выглядело бы совершенно корректно.
//
// 2. Обход идёт по ВСЕЙ базе, а не по списку коллекций, где ссылки
//    «должны» лежать. Причина: список устаревает молча. Первая версия
//    смотрела messages/statuses/chats/users — 319 документов из 805,
//    которые реально есть в проде; agreements, personalEvents и invites
//    не смотрелись вовсе. То же и внутри документа: значения
//    обходятся рекурсивно, а не по списку известных полей
//    (imageURL/videoURL/replyTo.*/mediaUrl/...), потому что забытое поле
//    здесь стоит ровно столько же.
//
// Общая форма обоих: **неполное знание не даёт права удалять**. Отсюда
// же и третье правило — при пустом или прерванном обходе сборщик не
// удаляет ничего (см. HarvestResult.complete и проверку scannedDocs).

import { logger } from "firebase-functions";
import type { Bucket, File } from "@google-cloud/storage";
import type { Firestore, QueryDocumentSnapshot } from "firebase-admin/firestore";

// Окно ожидания между заливкой файла и появлением документа.
//
// СУЖАТЬ НЕЛЬЗЯ. Прежняя редакция этого комментария сама напрашивалась на
// сужение: «реальный разрыв — секунды, сутки взяты запасом на порядки
// больше». Первая половина верна только для удачной отправки, и на ней
// одной кто-нибудь однажды поставит час — ведь это всё ещё в десятки раз
// больше «секунд». Разбор 03.08 (AUDIT_TODO.md, «Цена дыры B11-source»)
// показал, что разрыв не ограничен секундами вовсе:
//
//   attemptSendPendingMessage (background_queue_processor.dart) при
//   повторе НЕ перезаливает файл — он сохраняет uploadedUrl и переиспользует
//   его. После pendingQueueMaxAttempts = 8 неудач запись паркуется со
//   статусом 'failed', с сохранённым URL, и ждёт РУЧНОГО повтора. Он может
//   прийти через сутки, через неделю, вообще никогда.
//
// То есть между заливкой и появлением документа законно проходит столько
// времени, сколько человек не открывал приложение. При окне в час сборщик
// снёс бы файл припаркованной отправки, а отложенный повтор записал бы
// сообщение со ссылкой на удалённый объект: битое медиа, молча и
// невосстановимо — локальная копия видео удаляется сразу после заливки
// (см. `finally` там же), а iOS чистит temp.
//
// Сутки — не запас поверх секунд, а граница, за которой ручной повтор уже
// маловероятен. И экономить тут нечего: замер 03.08 дал ~5 сирот за двое
// суток плотного тестирования медиа, а на масштабе тысячи пользователей
// лишние сутки хранения стоят порядка $0.00005 в день. Цена ошибки
// несимметрична до абсурда.
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
  // false — обход не дошёл до конца (кончился бюджет времени). Тогда
  // удалять нельзя ВООБЩЕ ничего: недосчитанная ссылка неотличима от
  // отсутствующей, а «половина знания» здесь означает удаление живого
  // медиа, ссылка на которое лежала в непросмотренном хвосте. Не то же
  // самое, что прерваться на середине УДАЛЕНИЯ: там каждое решение уже
  // принято по полному множеству ссылок и остаток спокойно уходит в
  // следующий прогон.
  complete: boolean;
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
// Масштаб — по замеру, а не по ощущению. Обход стоит одно чтение на
// документ плюс один listCollections на документ. Прод, 805 документов:
// 90 с последовательно, 17 с пачками по 20 с ноутбука (см.
// LIST_CONCURRENCY ниже) и 4.3 с из функции в том же регионе — то есть
// около 190 документов в секунду там, где он и работает.
//
// При бюджете 480 с это порядка 90 000 документов на прогон. Порог
// предупреждения поставлен сильно ниже, чтобы оно успело появиться в
// логах задолго до того, как прогоны начнут упираться в бюджет и
// переставать удалять (упереться безопасно — сборщик тогда просто
// ничего не удаляет, — но узнать об этом лучше заранее). Дальше схему
// надо менять на обратный индекс путей: складывать ссылку при записи
// документа, а не искать её потом по всей базе.
const HARVEST_SCALE_WARN_DOCS = 15000;

async function harvestReferencedPaths(
  db: Firestore,
  isOutOfTime: () => boolean,
): Promise<HarvestResult> {
  const paths = new Set<string>();
  let scannedDocs = 0;
  let complete = true;

  // Обход стоит одного listCollections на документ — узнать, есть ли у
  // него подколлекции, дешевле неоткуда. Замер по проду: 805 документов
  // подряд — 90 с, при том что чтение самих страниц заняло секунды.
  // То есть время съедали не данные, а 805 последовательных
  // round-trip'ов. Отсюда пачки: полнота обхода та же (посещаются ровно
  // те же документы), меняется только то, что ожидание ответа идёт
  // параллельно. 20 — не подобранный оптимум, а осознанно скромное
  // число: Firestore такую конкурентность не замечает, а рост дальше
  // упирается уже в пропускную способность, а не в задержку.
  const LIST_CONCURRENCY = 20;

  // Очередь вместо рекурсии: глубина вложенности заранее неизвестна, а
  // стек — единственное, что здесь могло бы кончиться незаметно.
  const queue: FirebaseFirestore.CollectionReference[] = [];

  // Документы читаются страницами по 500, а не одним .get(): память
  // ограничена страницей независимо от размера коллекции. Бюджет
  // проверяется на границе страницы — прерваться посреди страницы
  // смысла нет, она уже прочитана.
  const scanCollection = async (ref: FirebaseFirestore.CollectionReference): Promise<void> => {
    if (NOT_A_REFERENCE_COLLECTIONS.has(ref.id)) return;
    const PAGE_SIZE = 500;
    let lastDoc: QueryDocumentSnapshot | undefined;
    for (;;) {
      if (isOutOfTime()) {
        complete = false;
        return;
      }
      let query: FirebaseFirestore.Query = ref.orderBy("__name__").limit(PAGE_SIZE);
      if (lastDoc) query = query.startAfter(lastDoc);
      const snap = await query.get();
      if (snap.empty) break;

      for (const doc of snap.docs) {
        const data = doc.data();
        collectPathsFromValue(data, paths);
        collectSplitMediaRef(data, paths);
        scannedDocs++;
      }

      for (let i = 0; i < snap.docs.length; i += LIST_CONCURRENCY) {
        const chunk = snap.docs.slice(i, i + LIST_CONCURRENCY);
        const subs = await Promise.all(chunk.map((doc) => doc.ref.listCollections()));
        for (const sub of subs.flat()) queue.push(sub);
      }

      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.docs.length < PAGE_SIZE) break;
    }
  };

  queue.push(...(await db.listCollections()));
  while (queue.length > 0) {
    const next = queue.shift();
    if (!next) break;
    await scanCollection(next);
    if (!complete) break;
  }

  if (scannedDocs > HARVEST_SCALE_WARN_DOCS) {
    logger.warn(
      "orphanSweep: full-database harvest is outgrowing its design — " +
        "replace it with a reverse index of storage paths before it gets slower",
      { scannedDocs },
    );
  }
  logger.info(
    `orphanSweep: scanned ${scannedDocs} docs across the whole database` +
      (complete ? "" : " (INCOMPLETE — ran out of time budget)"),
  );

  return { paths, scannedDocs, complete };
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
  // Прогон закончился не потому, что работа кончилась. Это НЕ ошибка:
  // сборщик идемпотентен, остаток уходит в следующий прогон. Ошибкой
  // было бы молча выдать неполный проход за полный — поэтому причина
  // здесь и попадает в лог с отчётом.
  stoppedEarly: boolean;
  stopReason: string | null;
  // Сколько сирот осталось необработанными на момент остановки (при
  // остановке по лимиту/бюджету); 0 при нормальном завершении.
  remainingCandidates: number;
  // Разбивка времени. Нужна не для красоты: обход ссылок — единственная
  // часть, которая растёт вместе с базой и упирается в бюджет, а по
  // одной общей длительности не видно, к чему подходит предел. Попадает
  // и в лог, и в запись прогона, поэтому запас можно смотреть постфактум.
  harvestMs: number;
  listMs: number;
  deleteMs: number;
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
  // Абсолютный момент (epoch ms), после которого прогон обязан свернуться
  // сам. Существует, чтобы функция не падала по таймауту рантайма: убитый
  // по таймауту прогон не оставил бы ни отчёта, ни записи о том, что
  // успел удалить.
  deadlineMs?: number;
  // Потолок удалений за один прогон. Ограничивает не корректность, а
  // размер ущерба от ошибки: даже если бы сборщик считал сиротами всё
  // подряд, за прогон он снёс бы не больше этого числа, а следующий
  // прогон — уже после того, как это стало видно в отчёте.
  maxDeletions?: number;
  // Размер страницы листинга Storage. Вынесен только ради тестов: при
  // маленьком значении проверяется сама постраничность.
  listPageSize?: number;
}

const DEFAULT_MAX_DELETIONS = 500;
const DEFAULT_LIST_PAGE_SIZE = 1000;

export async function sweepOrphanMedia(opts: SweepOptions): Promise<SweepResult> {
  const { db, bucket } = opts;
  const dryRun = opts.dryRun ?? true;
  const minAgeMs = opts.minAgeMs ?? DEFAULT_MIN_AGE_MS;
  const nowMs = opts.nowMs ?? Date.now();
  const maxDeletions = opts.maxDeletions ?? DEFAULT_MAX_DELETIONS;
  const listPageSize = opts.listPageSize ?? DEFAULT_LIST_PAGE_SIZE;
  const deadlineMs = opts.deadlineMs;
  const isOutOfTime = () => deadlineMs !== undefined && Date.now() >= deadlineMs;

  const result: SweepResult = {
    scannedObjects: 0,
    scannedDocs: 0,
    referencedPaths: 0,
    skippedTooYoung: 0,
    skippedNotSwept: 0,
    orphans: [],
    orphanBytes: 0,
    deleted: 0,
    deleteFailures: 0,
    stoppedEarly: false,
    stopReason: null,
    remainingCandidates: 0,
    harvestMs: 0,
    listMs: 0,
    deleteMs: 0,
  };

  const harvestStartedMs = Date.now();
  const {
    paths: referenced,
    scannedDocs,
    complete,
  } = await harvestReferencedPaths(db, isOutOfTime);
  result.harvestMs = Date.now() - harvestStartedMs;
  result.scannedDocs = scannedDocs;
  result.referencedPaths = referenced.size;

  // Неполный обход — не «мало ссылок», а «неизвестно, какие есть».
  // Удалять при нём нельзя ничего: ссылка на живое медиа могла лежать
  // ровно в непрочитанном хвосте. Возвращаемся с флагом; следующий
  // прогон начнёт заново, сборщик к этому и приспособлен.
  if (!complete) {
    result.stoppedEarly = true;
    result.stopReason = "harvest-incomplete";
    logger.error(
      "orphanSweep: aborting — reference harvest did not finish within the time budget; " +
        "a partial harvest is 'unknown', never 'nothing is referenced'",
      { scannedDocs },
    );
    return result;
  }

  // Объекты перебираются страницами (autoPaginate: false), а не одним
  // массивом на весь бакет: при десятках тысяч объектов полный список
  // File-объектов в памяти — и есть тот самый отказ по памяти, которого
  // здесь быть не должно.
  const candidates: OrphanObject[] = [];
  const listStartedMs = Date.now();
  for (const prefix of SWEPT_PREFIXES) {
    let pageToken: string | undefined;
    for (;;) {
      // getFiles отдаёт [файлы, запрос-за-следующей-страницей, ответ API];
      // при autoPaginate: false вторая позиция и есть курсор — null на
      // последней странице.
      const response = await bucket.getFiles({
        prefix,
        maxResults: listPageSize,
        pageToken,
        autoPaginate: false,
      });
      const files = response[0] as File[];
      const nextQuery = response[1] as { pageToken?: string } | null | undefined;

      for (const file of files) {
        result.scannedObjects++;
        if (!isSweptPath(file.name)) {
          result.skippedNotSwept++;
          continue;
        }
        if (referenced.has(file.name)) continue;

        const created = file.metadata.timeCreated;
        const createdMs = created ? Date.parse(created) : NaN;
        // Объект без разбираемой даты создания считается свежим:
        // неизвестный возраст — не повод удалять.
        if (!Number.isFinite(createdMs) || nowMs - createdMs < minAgeMs) {
          result.skippedTooYoung++;
          continue;
        }

        candidates.push({
          path: file.name,
          sizeBytes: Number(file.metadata.size ?? 0),
          createdAt: created ?? "unknown",
        });
      }

      pageToken = nextQuery?.pageToken;
      if (!pageToken) break;
    }
  }
  result.listMs = Date.now() - listStartedMs;

  // Пустой результат обхода — это «не знаю», а не «ничего не
  // ссылается». Тот же класс ошибки, по которому в этом проекте уже
  // прошлись отдельно (AUDIT_TODO.md, «пустой снимок принят за
  // содержательный ответ»), только здесь цена — весь бакет разом:
  // упавший на середине или обрезанный правами обход выглядит ровно как
  // «ссылок нет». Поэтому ноль прочитанных документов при непустом
  // бакете — отказ работать, а не разрешение всё удалить.
  if (scannedDocs === 0 && result.scannedObjects > 0) {
    result.stoppedEarly = true;
    result.stopReason = "empty-harvest";
    result.remainingCandidates = candidates.length;
    logger.error(
      "orphanSweep: aborting — 0 documents scanned while the bucket is not empty; " +
        "an empty scan is 'unknown', never 'nothing is referenced'",
      { scannedObjects: result.scannedObjects },
    );
    return result;
  }

  const deleteStartedMs = Date.now();
  for (let i = 0; i < candidates.length; i++) {
    const candidate = candidates[i];

    if (!dryRun && result.deleted >= maxDeletions) {
      result.stoppedEarly = true;
      result.stopReason = "max-deletions";
      result.remainingCandidates = candidates.length - i;
      break;
    }
    // Прерваться здесь безопасно, в отличие от обхода ссылок: решение по
    // каждому объекту уже принято по полному их множеству, и остаток
    // просто достанется следующему прогону.
    if (!dryRun && isOutOfTime()) {
      result.stoppedEarly = true;
      result.stopReason = "deadline";
      result.remainingCandidates = candidates.length - i;
      break;
    }

    result.orphans.push(candidate);
    result.orphanBytes += candidate.sizeBytes;

    if (!dryRun) {
      try {
        await bucket.file(candidate.path).delete();
        result.deleted++;
        // Построчная запись в лог именно на удалении: отчёт агрегатом
        // отвечает «сколько», а на вопрос «что именно пропало» через
        // месяц отвечает только эта строка (и запись прогона рядом).
        logger.info("orphanSweep: deleted", {
          path: candidate.path,
          sizeBytes: candidate.sizeBytes,
          createdAt: candidate.createdAt,
        });
      } catch (e) {
        result.deleteFailures++;
        logger.warn("orphanSweep: delete failed", { path: candidate.path, error: e });
      }
    }
  }

  result.deleteMs = Date.now() - deleteStartedMs;

  logger.info("orphanSweep: done", {
    dryRun,
    scannedObjects: result.scannedObjects,
    scannedDocs: result.scannedDocs,
    referencedPaths: result.referencedPaths,
    orphans: result.orphans.length,
    orphanBytes: result.orphanBytes,
    deleted: result.deleted,
    deleteFailures: result.deleteFailures,
    stoppedEarly: result.stoppedEarly,
    stopReason: result.stopReason,
    remainingCandidates: result.remainingCandidates,
    harvestMs: result.harvestMs,
    listMs: result.listMs,
    deleteMs: result.deleteMs,
  });

  return result;
}

// ---------------------------------------------------------------------
// Долговременный след прогона
// ---------------------------------------------------------------------
// Cloud Logging по умолчанию хранит записи 30 дней, а вопрос «а куда
// делся вот этот файл» возникает позже — поэтому итог каждого прогона
// ложится ещё и в Firestore, где живёт столько же, сколько проект.
//
// Клиенту коллекция недоступна: в firestore.rules нет ни одного
// wildcard-правила верхнего уровня, а значит всё неперечисленное
// запрещено по умолчанию (правило-заглушка на maintenance/** добавлено
// туда же явно, чтобы это было видно, а не выводилось).
const SWEEP_RUNS_COLLECTION = "maintenance";
const SWEEP_RUNS_DOC = "orphanSweep";
const SWEEP_RUNS_SUBCOLLECTION = "runs";

// Полный список путей в одном документе упёрся бы в лимит 1 МиБ на
// документ при большой разовой чистке, а обрезанный молча — соврал бы.
// Поэтому: первые 200 путей в документе, остальное — по счётчику плюс
// признак обрезки, и все до одного есть построчно в Cloud Logging.
const MAX_RECORDED_PATHS = 200;

export interface SweepRunMeta {
  trigger: "scheduled" | "script";
  dryRun: boolean;
  startedAtMs: number;
}

export async function recordSweepRun(
  db: Firestore,
  result: SweepResult,
  meta: SweepRunMeta,
): Promise<void> {
  const recorded = result.orphans.slice(0, MAX_RECORDED_PATHS);
  try {
    await db
      .collection(SWEEP_RUNS_COLLECTION)
      .doc(SWEEP_RUNS_DOC)
      .collection(SWEEP_RUNS_SUBCOLLECTION)
      .add({
        trigger: meta.trigger,
        dryRun: meta.dryRun,
        startedAt: new Date(meta.startedAtMs),
        finishedAt: new Date(),
        durationMs: Date.now() - meta.startedAtMs,
        scannedObjects: result.scannedObjects,
        scannedDocs: result.scannedDocs,
        referencedPaths: result.referencedPaths,
        skippedTooYoung: result.skippedTooYoung,
        skippedNotSwept: result.skippedNotSwept,
        orphanCount: result.orphans.length,
        orphanBytes: result.orphanBytes,
        deleted: result.deleted,
        deleteFailures: result.deleteFailures,
        stoppedEarly: result.stoppedEarly,
        stopReason: result.stopReason,
        remainingCandidates: result.remainingCandidates,
        harvestMs: result.harvestMs,
        listMs: result.listMs,
        deleteMs: result.deleteMs,
        orphanPaths: recorded.map((o) => ({
          path: o.path,
          sizeBytes: o.sizeBytes,
          createdAt: o.createdAt,
        })),
        orphanPathsTruncated: result.orphans.length > recorded.length,
      });
  } catch (e) {
    // Отчёт — это след, а не часть работы: прогон уже состоялся, файлы
    // уже удалены, и падать здесь значило бы потерять ещё и лог в
    // Cloud Logging из-за необработанного исключения.
    logger.warn("orphanSweep: failed to record run", e);
  }
}

// Единая точка входа для регулярной функции и для скрипта: и след, и
// сам прогон должны быть одинаковыми независимо от того, кто нажал.
export async function runOrphanSweepAndRecord(
  opts: SweepOptions & { trigger: SweepRunMeta["trigger"] },
): Promise<SweepResult> {
  const startedAtMs = Date.now();
  const result = await sweepOrphanMedia(opts);
  await recordSweepRun(opts.db, result, {
    trigger: opts.trigger,
    dryRun: opts.dryRun ?? true,
    startedAtMs,
  });
  return result;
}
