// Shared between index.ts's onUserWritten trigger and
// scripts/algoliaBackfill.ts — kept in its own module (no firebase-admin
// initializeApp() call, no onCall/trigger exports) so the backfill script
// can import toAlgoliaUserRecord without pulling in index.ts's top-level
// initializeApp() (which would throw "default app already exists" once the
// script calls its own) or registering every other Cloud Function as a
// side effect of the import.

// Not a secret — meant to ship in the Flutter client too (see
// lib/core/config/algolia_config.dart) — it's just how a client identifies
// which Algolia app to query. Only the Admin API Key (see index.ts's
// algoliaAdminKey / this script's ALGOLIA_ADMIN_KEY env var) is sensitive.
export const ALGOLIA_APP_ID = "XNU1ONO1UZ";
export const ALGOLIA_USERS_INDEX = "users";

// Deliberately only the fields actually needed to render a search result or
// to filter/facet by (see FilterSheet) — bio/gigs/verified/etc. stay
// Firestore-only, fetched via the existing currentUserProvider/
// userByIdProvider once a result is tapped (see User.fromAlgoliaHit's own
// comment, lib/firebase/models.dart). `instrument` is included even though
// it's not a facet — it's the flat display string search_screen.dart's
// result tiles need for formatActivityForCard, and there's no nested
// activityType map in the index to derive it from.
//
// `lastSeen` (epoch millis, not the Firestore Timestamp itself — Algolia
// numeric filters need a plain number) is here for the same reason
// User.isActuallyOnline (lib/firebase/models.dart) cross-checks it: raw
// `online` alone goes stale (PresenceService's heartbeat pauses rather than
// clears it on backgrounding), so SearchFilters.toAlgoliaFilters
// (filter_sheet.dart) filters on `online:true AND lastSeen > <now minus
// User.onlineGracePeriod>` instead of `online:true` alone — a static index
// snapshot can't call a getter, so the same 2-minute check has to be
// re-expressed as a query-time numeric filter using this field.
//
// `emoji`/`mostRecentStatusExpiresAt`/`mostRecentStatusCreatedAt` were added
// when the same Algolia-backed search got reused for the group/event
// participant pickers (group_info_screen.dart's _AddParticipantsSheet,
// create_group_screen.dart, agreements_screen.dart's
// _ParticipantPickerDialog) — those rows render the same status ring
// (User.hasActiveStatus/hasUnviewedStatusFrom) and avatar-fallback emoji the
// Firestore-backed list they replaced did, so without these fields here
// every row would silently regress to always-muted-ring/generic-emoji.
export function toAlgoliaUserRecord(uid: string, data: FirebaseFirestore.DocumentData) {
  const lastSeen = data.lastSeen as FirebaseFirestore.Timestamp | undefined;
  const mostRecentStatusExpiresAt = data.mostRecentStatusExpiresAt as
    | FirebaseFirestore.Timestamp
    | undefined;
  const mostRecentStatusCreatedAt = data.mostRecentStatusCreatedAt as
    | FirebaseFirestore.Timestamp
    | undefined;
  return {
    objectID: uid,
    id: uid,
    // Same name/displayName fallback as User.fromFirestore (lib/firebase/
    // models.dart) and onNewMessage's senderName in index.ts.
    name: (data.name ?? data.displayName ?? "") as string,
    city: (data.city ?? "") as string,
    activityInstruments: (data.activityInstruments ?? []) as string[],
    instrument: (data.instrument ?? "") as string,
    rating: ((data.rating ?? 0) as number),
    available: (data.available ?? false) as boolean,
    online: (data.online ?? false) as boolean,
    lastSeen: lastSeen ? lastSeen.toMillis() : null,
    photoURL: (data.photoURL ?? null) as string | null,
    emoji: (data.emoji ?? "🎵") as string,
    mostRecentStatusExpiresAt: mostRecentStatusExpiresAt ? mostRecentStatusExpiresAt.toMillis() : null,
    mostRecentStatusCreatedAt: mostRecentStatusCreatedAt ? mostRecentStatusCreatedAt.toMillis() : null,
  };
}

// Поля, ради которых индекс вообще переписывается. Ровно те, что уходят в
// запись выше, МИНУС lastSeen: он тоже индексируется, но меняется сам по
// себе раз в 60 с у каждого, кто держит приложение открытым, и потому
// решать по нему «запись изменилась» — значит переписывать индекс на
// каждое сердцебиение.
const INDEXED_FIELDS = [
  "name",
  "displayName",
  "city",
  "activityInstruments",
  "instrument",
  "rating",
  "available",
  "online",
  "photoURL",
  "emoji",
  "mostRecentStatusExpiresAt",
  "mostRecentStatusCreatedAt",
] as const;

// Шаг, с которым отметка присутствия доезжает до индекса. Решение
// владельца 07.08 — 10 минут, и цена названа вслух: «сейчас в сети» В
// ПОИСКЕ отстаёт на этот срок. Поэтому окно запроса «Onlayn indi»
// (User.onlineQueryWindow, lib/firebase/models.dart) обязано быть ШИРЕ
// шага — иначе фильтр перестанет находить кого бы то ни было, и починка
// триггера тихо сломает слой над ним (N57). Связь держится тестом.
//
// Зелёной точки в приложении это не касается вовсе: она считается по
// живому документу Firestore (User.isPresenceFresh), а не по индексу.
export const ALGOLIA_LAST_SEEN_THROTTLE_MS = 10 * 60 * 1000;

function toMillis(v: unknown): number | null {
  if (v == null) return null;
  const t = v as { toMillis?: () => number };
  return typeof t.toMillis === "function" ? t.toMillis() : null;
}

function sameValue(a: unknown, b: unknown): boolean {
  if (Array.isArray(a) || Array.isArray(b)) {
    return JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
  }
  const am = toMillis(a);
  const bm = toMillis(b);
  if (am !== null || bm !== null) return am === bm;
  return (a ?? null) === (b ?? null);
}

// ПОЧЕМУ ЭТО ЗДЕСЬ, А НЕ ВНУТРИ ТРИГГЕРА (N43).
//
// `onUserWritten` слал запись в Algolia на КАЖДУЮ запись в users/{uid}, а
// присутствие пишет туда `online` + `lastSeen` + `activeChatId` раз в 60 с
// на каждого, у кого открыто приложение. То есть счёт за поиск платился за
// сердцебиение, а не за изменение того, что ищут.
//
// Наивная починка «сравнить индексируемые поля» не сработала бы: `online`
// и `lastSeen` — сами индексируемые, и присутствие пишет ровно их.
//
// СЧИТАТЬ РАЗНОСТЬ before/after ТОЖЕ НЕЛЬЗЯ, и это стоило одной правки:
// триггер видит не «последнее, что дошло до индекса», а предыдущую запись
// в документ. Между двумя соседними сердцебиениями всегда 60 с, то есть
// «уехал больше чем на 10 минут» не наступило бы НИКОГДА, и отметка в
// индексе застыла бы навсегда — дефект хуже исходного.
//
// Поэтому шаг считается по общей шкале: индекс переписывается на первом
// сердцебиении каждого десятиминутного отрезка. Состояния это не требует,
// сравниваются номера отрезков, а не разность.
// ПРИЧИНА, А НЕ ТОЛЬКО ОТВЕТ «ДА/НЕТ» — заведено 08.08 перед выкладкой.
//
// Экономию N43 нечем было измерить: `onUserWritten` срабатывает на каждое
// сердцебиение и ДО правки, и ПОСЛЕ — экономится не вызов, а обращение к
// Algolia, а путь отказа не оставлял в журнале ничего. Счёт по вызовам
// показал бы «экономии нет» там, где она есть, и выяснилось бы это уже на
// живых данных (I15).
//
// Причина возвращается словами, а не флагом, чтобы журнал отвечал на два
// вопроса сразу: СКОЛЬКО переиндексаций и ПОЧЕМУ именно эти. Второе важнее
// первого: если в журнале одни «online», а «изменилось поле» не появляется
// никогда — значит порог работает, но выбор причин надо смотреть заново.
export function reindexReason(
  before: FirebaseFirestore.DocumentData | undefined,
  after: FirebaseFirestore.DocumentData | undefined,
): string | null {
  // Появление и исчезновение документа — всегда: иначе новый человек не
  // попадёт в поиск, а удалённый останется там навсегда.
  if (!before) return "документ появился";
  if (!after) return "документ исчез";

  for (const f of INDEXED_FIELDS) {
    if (!sameValue(before[f], after[f])) return `изменилось поле ${f}`;
  }

  const beforeSeen = toMillis(before.lastSeen);
  const afterSeen = toMillis(after.lastSeen);
  if (beforeSeen === null || afterSeen === null) {
    return beforeSeen === afterSeen ? null : "lastSeen появился или исчез";
  }
  const step = ALGOLIA_LAST_SEEN_THROTTLE_MS;
  if (Math.floor(beforeSeen / step) !== Math.floor(afterSeen / step)) {
    return "lastSeen перешагнул десятиминутный отрезок";
  }
  return null;
}

export function shouldReindexUser(
  before: FirebaseFirestore.DocumentData | undefined,
  after: FirebaseFirestore.DocumentData | undefined,
): boolean {
  return reindexReason(before, after) !== null;
}
