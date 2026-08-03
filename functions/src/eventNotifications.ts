// Уведомления об изменениях мероприятия, затрагивающих ДРУГИХ людей.
//
// Вынесено из index.ts отдельным чистым модулем по той же причине, что и
// presence.ts (N19): цена ошибки здесь несимметрична и невидима.
// Уведомление, ушедшее не тому, человек заметит и пожалуется; уведомление,
// не ушедшее никому, не заметит НИКТО — ни автор изменения, ни тот, кого
// оно касалось, ни лог. Чистые функции позволяют проверить все сочетания
// разом, без эмулятора и без FCM (которого на iOS пока и нет — см. N20).
//
// ---------------------------------------------------------------------------
// ПОЧЕМУ ПРИЗНАК АВТОРА ЛЕЖИТ В ДАННЫХ, А НЕ ВЫВОДИТСЯ
// ---------------------------------------------------------------------------
// Firestore-триггер видит before/after, но не видит, КТО писал. Часть
// случаев выводится из правил (удалять и править может только владелец), но
// один — нет: «владелец убрал участника» и «участник вышел сам» дают
// одинаковый diff, из `musicians` пропал один uid. Поэтому клиент пишет
// `lastActionBy` + `lastActionType` той же операцией, а правила не дают
// подделать первое (`stampsSelf`).
//
// Это ровно тот приём, который в реестре записан как проверочный признак
// всего класса «визит вместо события»: отметка и вопрос должны относиться
// к ОДНОМУ событию, а не выводиться одна из другой.

export type EventActionType =
  | "created"
  | "edited"
  | "replaced"
  | "deleted"
  | "left"
  // Договор, рождённый из согласованного предложения. Уведомлений не
  // порождает вовсе: обе стороны узнают о сделке другим путём.
  | "agreed";

/** Поля мероприятия, значимые для уведомления. */
export interface EventSnapshot {
  ownerUid: string;
  date: string;
  type: string;
  location: string;
  notes: string;
  musicians: string[];
  cancelRequestedBy?: string | null;
  cancelConfirmedBy?: string | null;
  status?: string;
  replacedEventId?: string | null;
  lastActionBy?: string | null;
  lastActionType?: EventActionType | null;
}

export interface EventPush {
  /** Кому. */
  uid: string;
  title: string;
  body: string;
  /** Полезная нагрузка: по ней клиент решает, что открыть. */
  data: Record<string, string>;
}

// ---------------------------------------------------------------------------
// ФОРМАТИРОВАНИЕ
// ---------------------------------------------------------------------------
// Даты мероприятий — «плавающее гражданское время» (N4): `2026-08-08T17:30`
// без смещения означает 17:30 ТАМ, где мероприятие проходит. Приводить их к
// UTC запрещено отдельной строкой в реестре, поэтому и здесь разбираем
// строку как есть, без Date-арифметики по часовым поясам.
const AZ_MONTHS = [
  "Yanvar", "Fevral", "Mart", "Aprel", "May", "İyun",
  "İyul", "Avqust", "Sentyabr", "Oktyabr", "Noyabr", "Dekabr",
];

/**
 * Дата мероприятия в бакинских стенных часах, что бы в ней ни лежало.
 *
 * В проде `date` хранится в ТРЁХ формах одновременно (замер N4): плавающая
 * `2026-08-08T17:30:00.000`, плавающая с микросекундами и старая
 * UTC-строка `2026-07-01T15:50:02.000Z`. Первые две уже стенные часы;
 * третья — момент на оси, и без перевода она попала бы в окно напоминания
 * на четыре часа раньше срока.
 *
 * Чинится ЗДЕСЬ, на чтении, а не миграцией данных. Причина названа
 * прямо: перевод UTC-записи в стенные часы опирается на допущение «она
 * создавалась в Баку», а трактовка на чтении ничего не разрушает и
 * снимается удалением трёх строк. Пока можно выбирать, честнее исправлять
 * трактовку, чем переписывать данные — тем более что на 03.08 будущих
 * UTC-записей в проде НОЛЬ (13 таких, все старше месяца).
 *
 * Запрет N4 при этом не нарушен: он запрещает приводить `date` К UTC —
 * это сдвинуло бы показанное человеку время. Здесь обратное действие, и
 * оно восстанавливает исходный смысл, а не меняет его.
 */
export const BAKU_OFFSET_MS = 4 * 60 * 60 * 1000;

export function eventWallClock(date: string): string {
  if (!date) return "";
  const hasZone = /Z$/.test(date) || /[+-]\d{2}:\d{2}$/.test(date);
  if (!hasZone) return date;
  const ms = Date.parse(date);
  if (Number.isNaN(ms)) return date;
  return new Date(ms + BAKU_OFFSET_MS).toISOString().slice(0, 19);
}

/** «8 Avqust 2026, 17:30» — из того, что в строке вообще есть. */
export function fmtEventWhen(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/
    .exec(eventWallClock(iso ?? ""));
  if (!m) return "";
  const [, y, mo, d, hh, mm] = m;
  const month = AZ_MONTHS[Number(mo) - 1] ?? "";
  const day = `${Number(d)} ${month} ${y}`;
  return hh && mm ? `${day}, ${hh}:${mm}` : day;
}

/** «Toy» в кавычках, либо «tədbir», если тип не заполнен. */
function eventTitleOf(e: EventSnapshot): string {
  return e.type && e.type.trim().length > 0 ? `«${e.type}»` : "tədbir";
}

// ---------------------------------------------------------------------------
// КОМУ СЛАТЬ
// ---------------------------------------------------------------------------

/**
 * Все, кого изменение касается: владелец и участники, БЕЗ автора действия
 * и без повторов.
 *
 * Дедуп обязателен: владелец числится и в собственном массиве участников,
 * поэтому без него он получил бы по два уведомления на каждое изменение.
 * Тот же дубль, что 03.08 показывал «6 tədbiriniz var» вместо «3».
 */
export function recipientsOf(
  e: EventSnapshot,
  actorUid: string | null,
): string[] {
  const all = new Set<string>([e.ownerUid, ...(e.musicians ?? [])]);
  all.delete("");
  if (actorUid) all.delete(actorUid);
  return [...all];
}

// ---------------------------------------------------------------------------
// ЧТО ИМЕННО ИЗМЕНИЛОСЬ
// ---------------------------------------------------------------------------

export interface EventDiff {
  dateChanged: boolean;
  locationChanged: boolean;
  notesChanged: boolean;
  added: string[];
  removed: string[];
}

export function diffEvents(
  before: EventSnapshot,
  after: EventSnapshot,
): EventDiff {
  const b = new Set(before.musicians ?? []);
  const a = new Set(after.musicians ?? []);
  return {
    dateChanged: (before.date ?? "") !== (after.date ?? ""),
    locationChanged: (before.location ?? "") !== (after.location ?? ""),
    // Форма одежды и свободный текст лежат в базе одной строкой через
    // `', '` (общий виджет event_notes_picker.dart), поэтому здесь они
    // одно поле и одно уведомление. Разбирать строку ради «изменилась
    // именно форма одежды» значило бы завести второй разбор рядом с тем,
    // что уже есть в клиенте, и они разошлись бы (B16).
    notesChanged: (before.notes ?? "") !== (after.notes ?? ""),
    added: [...a].filter((u) => !b.has(u)),
    removed: [...b].filter((u) => !a.has(u)),
  };
}

// ---------------------------------------------------------------------------
// ТЕКСТЫ
// ---------------------------------------------------------------------------
// Стиль тот же, что у существующих уведомлений приложения
// (onFriendRequestCreated, onChatUpdated): заголовок — что случилось,
// тело — «Имя + глагол». Азербайджанский.
//
// `openList: "1"` в нагрузке означает «открыть список Müqavilələr, а не
// карточку». Это не косметика: правила дают читать мероприятие только
// владельцу и участникам, поэтому у того, кого убрали, и у того, чьё
// мероприятие удалили, карточка вернула бы отказ по правам. Уведомление,
// ведущее в ошибку, хуже уведомления без перехода.

function openEvent(eventId: string, kind: string): Record<string, string> {
  return { type: kind, eventId };
}

function openList(eventId: string, kind: string): Record<string, string> {
  return { type: kind, eventId, openList: "1" };
}

/** Один текст на одно изменение полей — №1–4 плана. */
export function editedBody(
  actorName: string,
  after: EventSnapshot,
  diff: EventDiff,
): string {
  const changed =
    (diff.dateChanged ? 1 : 0) +
    (diff.locationChanged ? 1 : 0) +
    (diff.notesChanged ? 1 : 0);
  if (changed > 1) return `${actorName} tədbir məlumatlarını dəyişdi`;
  if (diff.dateChanged) {
    return `${actorName} tarixi dəyişdi: ${fmtEventWhen(after.date)}`;
  }
  if (diff.locationChanged) {
    const where = after.location?.trim();
    return where && where.length > 0
      ? `${actorName} məkanı dəyişdi: ${where}`
      : `${actorName} məkanı sildi`;
  }
  return `${actorName} qeydləri dəyişdi`;
}

export function pushEdited(
  uid: string,
  eventId: string,
  actorName: string,
  after: EventSnapshot,
  diff: EventDiff,
): EventPush {
  return {
    uid,
    title: "Tədbir dəyişdi",
    body: editedBody(actorName, after, diff),
    data: openEvent(eventId, "event_edited"),
  };
}

export function pushAdded(
  uid: string,
  eventId: string,
  actorName: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "Tədbirə əlavə olundunuz",
    body:
      `${actorName} sizi ${eventTitleOf(e)} tədbirinə əlavə etdi` +
      `${e.date ? ` — ${fmtEventWhen(e.date)}` : ""}`,
    data: openEvent(eventId, "event_participant_added"),
  };
}

export function pushRemoved(
  uid: string,
  eventId: string,
  actorName: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "Tədbirdən çıxarıldınız",
    body:
      `${actorName} sizi ${eventTitleOf(e)} tədbirindən çıxardı` +
      `${e.date ? ` — ${fmtEventWhen(e.date)}` : ""}`,
    // Карточка ему больше не читается — правила пускают только участников.
    data: openList(eventId, "event_participant_removed"),
  };
}

/**
 * №7. Текст намеренно ЗАКОНЧЕННЫЙ, а не тревожный.
 *
 * Проверка, которую просил владелец: читается ли он как факт, а не как
 * задача. «Tədbir silindi» + «{Ad} … sildi» описывает произошедшее целиком
 * и не оставляет вопроса «а мне-то что делать»: делать нечего, мероприятия
 * больше нет. Поэтому здесь нет ни «yoxlayın» («проверьте»), ни вопроса, ни
 * призыва — они бы создали обязанность там, где её не существует.
 *
 * Дата в тексте не украшение: у человека может стоять несколько
 * мероприятий, и без неё он не поймёт, какое именно исчезло.
 */
export function pushDeleted(
  uid: string,
  eventId: string,
  actorName: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "Tədbir silindi",
    body:
      `${actorName} ${eventTitleOf(e)} tədbirini sildi` +
      `${e.date ? ` — ${fmtEventWhen(e.date)}` : ""}`,
    data: openList(eventId, "event_deleted"),
  };
}

export function pushLeft(
  uid: string,
  eventId: string,
  actorName: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "İştirakçı ayrıldı",
    body:
      `${actorName} ${eventTitleOf(e)} tədbirindən ayrıldı` +
      `${e.date ? ` — ${fmtEventWhen(e.date)}` : ""}`,
    data: openEvent(eventId, "event_participant_left"),
  };
}

/**
 * №9. Замена — ОДНО уведомление вместо двух.
 *
 * «Əvəz et» технически это удаление старого плюс создание нового, то есть
 * участник получил бы подряд «silindi» и «əlavə olundunuz» — две штуки об
 * одном действии, причём первая пугает зря. Новое мероприятие несёт
 * `replacedEventId`, по нему сервер узнаёт пару и шлёт одно точное.
 */
export function pushReplaced(
  uid: string,
  newEventId: string,
  actorName: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "Tədbir əvəz edildi",
    body:
      `${actorName} tədbiri yenisi ilə əvəz etdi` +
      `${e.date ? ` — ${fmtEventWhen(e.date)}` : ""}`,
    data: openEvent(newEventId, "event_replaced"),
  };
}

export function pushCancelRequested(
  uid: string,
  eventId: string,
  actorName: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "Ləğv təklifi",
    body:
      `${actorName} müqavilənin ləğvini təklif etdi` +
      `${e.date ? ` — ${fmtEventWhen(e.date)}` : ""}`,
    data: openEvent(eventId, "event_cancel_requested"),
  };
}

export function pushCancelConfirmed(
  uid: string,
  eventId: string,
  actorName: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "Müqavilə ləğv edildi",
    body:
      `${actorName} ləğvi təsdiqlədi` +
      `${e.date ? ` — ${fmtEventWhen(e.date)}` : ""}`,
    data: openEvent(eventId, "event_cancel_confirmed"),
  };
}

export type ReminderKind = "24h" | "3h";

/**
 * Напоминание. Два срока, и они не равнозначны:
 *
 * - за 24 часа — единственный срок, когда ещё можно ДЕЙСТВОВАТЬ: достать
 *   костюм, спланировать дорогу, договориться о замене, отменить;
 * - за 3 часа — последний момент, когда напоминание меняет поведение, а не
 *   просто сообщает.
 *
 * Часа намеренно нет: за час человек уже либо в пути, либо не успеет, и
 * уведомление становится укором вместо помощи.
 */
export function pushReminder(
  uid: string,
  eventId: string,
  e: EventSnapshot,
  kind: ReminderKind,
  hoursLeft: number,
): EventPush {
  const where = e.location?.trim();
  const tail = [fmtEventWhen(e.date), where && where.length > 0 ? where : null]
    .filter(Boolean)
    .join(", ");
  return {
    uid,
    title: reminderTitle(hoursLeft),
    body: `${eventTitleOf(e)} — ${tail}`,
    data: openEvent(eventId, `event_reminder_${kind}`),
  };
}

/**
 * Заголовок считается от ФАКТИЧЕСКОГО остатка, а не от названия окна.
 *
 * Это не мелочь. Догнанное напоминание с текстом «осталось 3 часа», когда
 * на деле осталось два, — ровно тот класс, который в проекте выпалывается
 * весь: отметка утверждает то, чего не проверяла. Поэтому число берётся из
 * данных в момент отправки.
 *
 * «Sabah» (завтра) остаётся только там, где это правда по существу —
 * больше двадцати часов; иначе слово обещало бы запас, которого нет.
 */
export function reminderTitle(hoursLeft: number): string {
  if (hoursLeft >= 20) return "Sabah tədbiriniz var";
  if (hoursLeft < 1) return "Tədbirə az qaldı";
  return `Tədbirə ${Math.round(hoursLeft)} saat qaldı`;
}

/**
 * Ключ отметки «напоминание отправлено».
 *
 * В ключ входит СТЕННОЕ ВРЕМЯ мероприятия, а не только его id. Причина
 * найдена разбором 03.08: мероприятие переносят уже после отправки
 * напоминания, и ключ по одному id запер бы новое — человек получил бы
 * напоминание о старом времени и ни одного о новом.
 *
 * Со временем в ключе перенос сам открывает новое окно, а правка места
 * или заметок (время не менялось) второго напоминания не порождает.
 * Старая отметка остаётся сиротой и никому не мешает.
 */
export function reminderKey(
  eventId: string,
  kind: ReminderKind,
  wallClock: string,
): string {
  return `reminder_${eventId}_${kind}_${wallClock}`;
}

/**
 * Догонять ли окно, которое уже прошло.
 *
 * Догон существует ради ПРОПУЩЕННЫХ ПРОГОНОВ — сбой, деплой, задержка
 * планировщика. Он не должен срабатывать для окна, которого не было вовсе:
 * если мероприятие создали позже, чем окно прошло, напоминать не о чем —
 * человек только что получил «Tədbirə əlavə olundunuz» и знает о нём
 * ровно то же самое.
 *
 * `createdAtMs === null` (поле не проставилось) трактуется как «событие
 * было» — направление выбрано так, чтобы сомнение приводило к лишнему
 * напоминанию, а не к потерянному: первое заметно и поправимо, второе не
 * замечает никто.
 */
export function shouldCatchUp(
  eventWallMs: number,
  aheadMs: number,
  createdAtMs: number | null,
): boolean {
  if (createdAtMs === null) return true;
  return createdAtMs <= eventWallMs - aheadMs;
}

// ---------------------------------------------------------------------------
// СБОРКА ВСЕГО ИЗМЕНЕНИЯ В НАБОР УВЕДОМЛЕНИЙ
// ---------------------------------------------------------------------------

export interface PlanUpdateInput {
  eventId: string;
  before: EventSnapshot;
  after: EventSnapshot;
  /** Имя автора действия — для текста. */
  actorName: string;
}

/**
 * Что разослать на одно обновление документа.
 *
 * Порядок случаев не произволен: сначала то, что относится к конкретному
 * человеку (его добавили, его убрали), потом общее изменение полей. Один
 * человек не должен получить две штуки об одном обновлении — например
 * «вас добавили» и следом «дата изменилась»: он этой даты и не видел
 * раньше, для него всё мероприятие новое.
 */
export function planUpdatePushes(input: PlanUpdateInput): EventPush[] {
  const { eventId, before, after, actorName } = input;
  const actor = after.lastActionBy ?? null;
  const diff = diffEvents(before, after);
  const out: EventPush[] = [];

  // Отмена по согласию. Поля заложены в модель заранее (пункт 2 плана), а
  // сам сценарий отмены ещё не сделан — до тех пор эти ветки просто не
  // срабатывают, и это нормально: писать их вторым заходом в тот же файл
  // дороже, чем завести сейчас.
  const cancelRequestedNow =
    !before.cancelRequestedBy && !!after.cancelRequestedBy;
  const cancelConfirmedNow =
    !before.cancelConfirmedBy && !!after.cancelConfirmedBy;
  if (cancelRequestedNow) {
    for (const uid of recipientsOf(after, after.cancelRequestedBy ?? null)) {
      out.push(pushCancelRequested(uid, eventId, actorName, after));
    }
    return out;
  }
  if (cancelConfirmedNow) {
    for (const uid of recipientsOf(after, after.cancelConfirmedBy ?? null)) {
      out.push(pushCancelConfirmed(uid, eventId, actorName, after));
    }
    return out;
  }

  // Участник вышел сам — уведомляется владелец, и только он.
  if (after.lastActionType === "left" && diff.removed.length > 0) {
    if (after.ownerUid && after.ownerUid !== actor) {
      out.push(pushLeft(after.ownerUid, eventId, actorName, after));
    }
    return out;
  }

  const touchedByActor = new Set<string>();
  for (const uid of diff.added) {
    if (uid === actor) continue;
    touchedByActor.add(uid);
    out.push(pushAdded(uid, eventId, actorName, after));
  }
  for (const uid of diff.removed) {
    if (uid === actor) continue;
    touchedByActor.add(uid);
    out.push(pushRemoved(uid, eventId, actorName, before));
  }

  const fieldsChanged =
    diff.dateChanged || diff.locationChanged || diff.notesChanged;
  if (fieldsChanged) {
    for (const uid of recipientsOf(after, actor)) {
      if (touchedByActor.has(uid)) continue;
      out.push(pushEdited(uid, eventId, actorName, after, diff));
    }
  }
  return out;
}
