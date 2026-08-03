// Уведомления по раунду «İş təklif et» — то, что касается ВТОРОЙ стороны.
//
// До 03.08 все три уведомления сценария были адресованы инициатору
// («жду даты», «согласие»), а получатель не узнавал ни о самом
// предложении, ни о смене даты, ни об отмене. То есть человек, которому
// предлагают работу, узнавал об этом, только если сам открывал чат.
//
// Отмена отдельно: у второй стороны плашка просто ИСЧЕЗАЛА. Молчаливое
// исчезновение хуже честного отказа — человек может счесть это сбоем и
// ждать ответа, которого не будет.
//
// Чистый модуль по той же причине, что presence.ts и eventNotifications.ts:
// цена ошибки несимметрична и невидима, а проверить надо без FCM.

import { eventWallClock } from "./eventNotifications";

const AZ_MONTHS = [
  "Yanvar", "Fevral", "Mart", "Aprel", "May", "İyun",
  "İyul", "Avqust", "Sentyabr", "Oktyabr", "Noyabr", "Dekabr",
];

interface Parts {
  y: string; mo: string; d: string; hh: string; mm: string;
}

function parts(iso: string): Parts | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/
    .exec(eventWallClock(iso ?? ""));
  if (!m) return null;
  return { y: m[1], mo: m[2], d: m[3], hh: m[4] ?? "", mm: m[5] ?? "" };
}

function dayOf(p: Parts, withYear: boolean): string {
  const month = AZ_MONTHS[Number(p.mo) - 1] ?? "";
  return withYear
    ? `${Number(p.d)} ${month} ${p.y}`
    : `${Number(p.d)} ${month}`;
}

function timeOf(p: Parts): string {
  return p.hh && p.mm ? `${p.hh}:${p.mm}` : "";
}

/** «8 Avqust 2026, 17:30». */
export function fmtWhen(iso: string): string {
  const p = parts(iso);
  if (!p) return "";
  const t = timeOf(p);
  return t ? `${dayOf(p, true)}, ${t}` : dayOf(p, true);
}

/**
 * ПЕРЕХОД ДАТЫ — «было → стало».
 *
 * Только для даты и только здесь. Для места и заметок показывается одно
 * новое значение: заголовок уже сообщает сам факт смены, старое значение
 * человек помнит, а баннер на iOS обрезается — лишние символы вытесняют
 * то единственное, ради чего уведомление послано.
 *
 * У даты довод обратный: вокруг неё человек строит день, и заметить надо
 * не «что-то изменилось», а ВЕЛИЧИНУ сдвига.
 *
 * Три случая разведены, чтобы одинаковое не повторялось дважды:
 *   тот же день   → «8 Avqust, 17:30 → 20:00»
 *   то же время   → «8 Avqust → 9 Avqust, 17:30»
 *   всё разное    → «8 Avqust 17:30 → 9 Avqust 20:00»
 *
 * Год опускается, пока он один и тот же: он почти никогда не меняется, а
 * место в баннере занимает. Разошёлся — печатается у обеих половин, иначе
 * «31 Dekabr → 1 Yanvar» скрыло бы самое существенное.
 */
export function fmtDateTransition(oldIso: string, newIso: string): string {
  const a = parts(oldIso);
  const b = parts(newIso);
  if (!a || !b) return fmtWhen(newIso);

  const withYear = a.y !== b.y;
  const sameDay = a.y === b.y && a.mo === b.mo && a.d === b.d;
  const sameTime = timeOf(a) === timeOf(b) && timeOf(a) !== "";

  if (sameDay) {
    return `${dayOf(b, withYear)}, ${timeOf(a)} → ${timeOf(b)}`;
  }
  if (sameTime) {
    return `${dayOf(a, withYear)} → ${dayOf(b, withYear)}, ${timeOf(b)}`;
  }
  const at = timeOf(a) ? ` ${timeOf(a)}` : "";
  const bt = timeOf(b) ? ` ${timeOf(b)}` : "";
  return `${dayOf(a, withYear)}${at} → ${dayOf(b, withYear)}${bt}`;
}

export interface OfferSnapshot {
  jobOfferBy?: string | null;
  jobOfferAt?: string | null;
  eventDate?: string | null;
  eventType?: string | null;
  eventLocation?: string | null;
  eventNotes?: string | null;
  recipientAgreed?: boolean;
  cancelledBy?: string | null;
  roundStep?: string | null;
}

export interface OfferPush {
  uid: string;
  title: string;
  body: string;
  data: Record<string, string>;
}

function dealLine(o: OfferSnapshot): string {
  return [
    o.eventType && o.eventType.length > 0 ? o.eventType : null,
    o.eventDate ? fmtWhen(o.eventDate) : null,
  ].filter(Boolean).join(" · ");
}

function openChat(chatId: string, kind: string): Record<string, string> {
  return { type: kind, chatId };
}

/** №1. Предложение с первой секунды содержательно (пункт 3 плана), поэтому
 * в тексте сразу видно, О ЧЁМ речь: человеку не нужно открывать чат,
 * чтобы понять, стоит ли открывать чат. */
export function pushOfferCreated(
  uid: string, chatId: string, actorName: string, o: OfferSnapshot,
): OfferPush {
  const deal = dealLine(o);
  return {
    uid,
    title: "Yeni iş təklifi",
    body: `${actorName} sizə iş təklif etdi${deal ? ` — ${deal}` : ""}`,
    data: openChat(chatId, "job_offer_created"),
  };
}

/** №2. Изменение предложения. «Выбрана дата» отдельным событием больше не
 * наступает: после пункта 3 дата уходит одной записью вместе с
 * предложением, остаётся её ИЗМЕНЕНИЕ. */
export function pushOfferChanged(
  uid: string, chatId: string, actorName: string,
  before: OfferSnapshot, after: OfferSnapshot,
): OfferPush {
  const dateChanged = (before.eventDate ?? "") !== (after.eventDate ?? "");
  const placeChanged =
    (before.eventLocation ?? "") !== (after.eventLocation ?? "");
  const notesChanged = (before.eventNotes ?? "") !== (after.eventNotes ?? "");
  const changed =
    (dateChanged ? 1 : 0) + (placeChanged ? 1 : 0) + (notesChanged ? 1 : 0);

  let body: string;
  if (dateChanged && changed === 1) {
    body = `${actorName} tarixi dəyişdi: ` +
      `${fmtDateTransition(before.eventDate ?? "", after.eventDate ?? "")}`;
  } else if (placeChanged && changed === 1) {
    const where = (after.eventLocation ?? "").trim();
    body = where.length > 0
      ? `${actorName} məkanı dəyişdi: ${where}`
      : `${actorName} məkanı sildi`;
  } else if (notesChanged && changed === 1) {
    body = `${actorName} qeydləri dəyişdi`;
  } else {
    const deal = dealLine(after);
    body = `${actorName} təklifi dəyişdi${deal ? ` — ${deal}` : ""}`;
  }
  return {
    uid,
    title: "Təklif dəyişdi",
    body,
    data: openChat(chatId, "job_offer_changed"),
  };
}

/** №3. Отмена раунда. Без неё у второй стороны плашка исчезала молча. */
export function pushOfferCancelled(
  uid: string, chatId: string, actorName: string,
): OfferPush {
  return {
    uid,
    title: "İş təklifi ləğv edildi",
    body: `${actorName} iş təklifini ləğv etdi`,
    data: openChat(chatId, "job_offer_cancelled"),
  };
}

/** Что разослать на одно обновление документа чата. */
export function planOfferPushes(input: {
  chatId: string;
  before: OfferSnapshot;
  after: OfferSnapshot;
  members: string[];
  actorName: string;
}): OfferPush[] {
  const { chatId, before, after, members, actorName } = input;

  // НОВОЕ ПРЕДЛОЖЕНИЕ определяется по `jobOfferAt`, а не по появлению
  // `jobOfferBy`.
  //
  // Найдено живым прогоном 04.08: `jobOfferBy` между раундами НЕ
  // очищается — после состоявшейся сделки он остаётся стоять, и новое
  // предложение просто переписывает поля поверх. Признак «поле появилось
  // из пустого» срабатывал бы ровно один раз за всю жизнь чата, на самом
  // первом предложении; все последующие уходили бы как «Təklif dəyişdi».
  // Ровно это и наблюдалось в логе.
  //
  // `jobOfferAt` подходит потому, что его переписывает `setJobOffer` при
  // каждом новом предложении и НЕ трогает `saveChatEventDate` («Tarix
  // dəyiş») — проверено по обоим методам, а не выведено.
  const offerAppeared =
    !!after.jobOfferBy &&
    (before.jobOfferAt ?? "") !== (after.jobOfferAt ?? "");
  const cancelledNow =
    !!before.jobOfferBy && !after.jobOfferBy && !!after.cancelledBy;
  const initiator = after.jobOfferBy ?? before.jobOfferBy ?? null;

  // Отмена — раньше всего: она завершает раунд, и говорить в этот момент
  // про изменившиеся поля значило бы называть не то, что произошло.
  if (cancelledNow) {
    const actor = after.cancelledBy ?? null;
    return members
      .filter((m) => m !== actor)
      .map((m) => pushOfferCancelled(m, chatId, actorName));
  }
  if (offerAppeared) {
    return members
      .filter((m) => m !== initiator)
      .map((m) => pushOfferCreated(m, chatId, actorName, after));
  }
  // Согласие уже покрыто onChatUpdated («İş təklifi qəbul edildi»), и
  // второе уведомление о том же было бы шумом.
  if (!before.recipientAgreed && after.recipientAgreed) return [];
  if (!after.jobOfferBy || after.recipientAgreed) return [];

  const changed =
    (before.eventDate ?? "") !== (after.eventDate ?? "") ||
    (before.eventLocation ?? "") !== (after.eventLocation ?? "") ||
    (before.eventNotes ?? "") !== (after.eventNotes ?? "") ||
    (before.eventType ?? "") !== (after.eventType ?? "");
  if (!changed) return [];

  return members
    .filter((m) => m !== initiator)
    .map((m) => pushOfferChanged(m, chatId, actorName, before, after));
}
