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
  // ТРЕТЬЕ СОСТОЯНИЕ ДОГОВОРА — «под вопросом» (Часть 6а `docs/plan.md`).
  // Два ПОВОДА прийти в него, и оба названы здесь сразу, хотя писателя
  // второго ещё нет: заведи один — и он определит форму, а второй придётся
  // подгонять. Решение владельца 09.08.
  //
  //   memberLeft    — ушёл участник, работа состоялась, вопрос в составе;
  //   workCancelled — исчезла сама работа (отменён родительский договор,
  //                   под которым звали своих; писатель появится в Части 6).
  //
  // Само `status` повода не знает и знать не должно: оно отвечает на «в
  // каком состоянии договор», а не «отчего». Различать поводы НУЖНО —
  // следующий ход инициатора у них разный: искать замену против отпустить
  // всех.
  | "memberLeft"
  | "workCancelled"
  // Договор, рождённый из согласованного предложения. Уведомлений не
  // порождает вовсе: обе стороны узнают о сделке другим путём.
  | "agreed"
  // ОТМЕНА ПО СОГЛАСИЮ — четыре хода, и каждый называет себя сам.
  //
  // Называться обязаны все четыре, а не только два снятия. Причина у
  // разных ходов разная, и обе весомые:
  //   - отзыв и отказ оставляют В ДАННЫХ ОДИН И ТОТ ЖЕ след (пустые поля
  //     запроса), и различить их по before/after нечем в принципе;
  //   - запрос и подтверждение различимы по полям, но имя автора для
  //     текста берётся из `lastActionBy`, а без него оно берётся от
  //     прошлого действия либо от владельца — и врёт.
  | "cancelRequested"
  | "cancelConfirmed"
  | "cancelWithdrawn"
  | "cancelDeclined";

/** Поля мероприятия, значимые для уведомления. */
export interface EventSnapshot {
  ownerUid: string;
  date: string;
  type: string;
  location: string;
  notes: string;
  musicians: string[];
  cancelRequestedBy?: string | null;
  /**
   * `cancelRequestedAt` в миллисекундах — ОТМЕТКА СОБЫТИЯ, по которой и
   * опознаётся новый запрос.
   *
   * Не `Timestamp`: этот модуль намеренно не знает про Firestore, чтобы
   * оставаться проверяемым обычным тестом. Перевод — в `toEventSnapshot`.
   *
   * Почему не «поле появилось из пустого» (класс N29): отзыв и отказ
   * возвращают `cancelRequestedBy` в `null`, значит появление из пустого
   * по одному договору происходит СКОЛЬКО УГОДНО РАЗ, и признак,
   * построенный на переходе, отвечает на вопрос «поле сейчас заполнено»,
   * а не на вопрос «просьба подана». Совпадать они перестанут в первый же
   * день, когда кто-то напишет путь, не очищающий поле.
   */
  cancelRequestedAtMs?: number | null;
  cancelConfirmedBy?: string | null;
  status?: string;
  replacedEventId?: string | null;
  lastActionBy?: string | null;
  lastActionType?: EventActionType | null;
  /**
   * Ответы состава — карта uid → `going` | `waiting` | `cant` (шаг 1 работы
   * «договоры и мероприятия — одна сущность», docs/plan.md).
   *
   * `undefined` и `{}` — РАЗНОЕ, и сводить их нельзя: отсутствие поля значит
   * «сведений нет» (так писали до шага 1, так пишет mugam-v2, так пишут
   * старые сборки), а пустая карта при непустом составе — противоречие
   * (I47). Здесь читает только `remindableOf`.
   */
  answers?: Record<string, string> | null;
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
// Договор становится «под вопросом» — правило, а не место в триггере.
//
// Вынесено чистой функцией по той же причине, что и остальные правила
// проекта: её можно испортить и увидеть падение, а ветку внутри триггера —
// нельзя.
//
// СЕГОДНЯ ПОВОД ОДИН, и это сказано вслух, чтобы не выглядело
// недоделкой: `memberLeft` пишется здесь, `workCancelled` — в Части 6
// вместе с приглашениями своих (там появится `parentEventId`, по которому
// сервер найдёт детей отменённого договора).
//
// ПОЧЕМУ ПОРОГ `status === "agreed"`: из отменённого в «под вопросом» пути
// нет — отменённый договор уже закрыт по согласию сторон. И повторно
// писать «под вопросом» поверх «под вопросом» незачем: второй ушедший
// ничего не меняет в том, что вопрос уже стоит.
//
// ВОЗВРАТ САМОГО СЕБЯ НЕ ВЫЗЫВАЕТ: после записи `lastActionType` перестаёт
// быть `"left"`, значит следующее срабатывание триггера на эту же запись
// условия не проходит. Проверять `status` для этого мало — он меняется той
// же операцией и на момент повторного входа уже `"unsettled"`.
//
// ---------------------------------------------------------------------------
// ЭТА ФУНКЦИЯ СНИМАЕТСЯ — НО НЕ ЗДЕСЬ И НЕ ШАГОМ 1 (N121). УСЛОВИЕ СНЯТИЯ, А
// НЕ ПОЖЕЛАНИЕ, — РЕШЕНИЕ ВЛАДЕЛЬЦА 28.08:
//
//   **пометка в составе («İşdən çıxdı» под именем вышедшего) обязана
//   РАБОТАТЬ к моменту, когда эта функция замолчит.**
//
// Порядок внутри клиентского шага 2 отсюда следует однозначный: СПЕРВА
// пометка, ПОТОМ снятие. Перевернуть его — значит на время между двумя
// правками отнять у владельца оба признака разом: вечер уже не встаёт «под
// вопрос», а в составе ещё ничего не написано, и уход не виден НИЧЕМ. Это
// хуже любого из двух состояний по отдельности.
//
// ПОЧЕМУ ФУНКЦИЯ ВООБЩЕ СНИМАЕТСЯ, а не чинится под новую схему: решение
// 12.08, записанное в `firestore.rules:1032-1036` — «`memberLeft` СРЕДИ
// ПОВОДОВ НЕТ, и это не забывчивость… уход участника больше не ставит вечер
// под вопрос: под вопросом один человек, а не вечер».
//
// ЧТО ЭТО ЗНАЧИТ СЕГОДНЯ, ПОСЛЕ ШАГА 1: функция ЖИВА и не тронута. Читает
// она `lastActionType` и `musicians`, то есть старый путь, — новая ветвь
// `leftViaAnswers` её не задевает вовсе, и на шаге 1 поведение «под
// вопросом» не меняется ни на йоту.
// ---------------------------------------------------------------------------
export function unsettledAfterMemberLeft(
  before: EventSnapshot,
  after: EventSnapshot,
): { status: string; lastActionType: EventActionType } | null {
  if (after.lastActionType !== "left") return null;
  if (after.status !== "agreed") return null;
  const b = new Set(before.musicians ?? []);
  const a = new Set(after.musicians ?? []);
  const removed = [...b].filter((u) => !a.has(u));
  if (removed.length === 0) return null;
  return { status: "unsettled", lastActionType: "memberLeft" };
}

// КОМУ ИДЁТ НАПОМИНАНИЕ — шаг 3 работы «договоры и мероприятия — одна
// сущность» (docs/plan.md).
//
// РАЗВЕДЕНИЕ АДРЕСАТОВ, и доводы стоят в том порядке, в каком решают:
//
//   1. Тот, кто сказал «не может», сказал это про СЕГОДНЯШНИЕ условия. Дата
//      поехала — условия другие, и молчание отняло бы у него право
//      передумать. Поэтому ИЗМЕНЕНИЯ идут всем, кто видит, и `recipientsOf`
//      ниже не трогается вовсе;
//   2. тот, кто ещё думает («ждём»), обязан получать изменения — иначе
//      решает по устаревшим сведениям.
//
// А напоминание — другое дело: оно не поддерживает никакого решения, оно про
// время. Напоминание про вечер, на который человек не идёт, — чистый шум.
// Значит фильтр стоит ТОЛЬКО здесь, и это одно место, а не два.
//
// ВЛАДЕЛЕЦ ПОЛУЧАЕТ ВСЕГДА, даже если его почему-то нет в составе: у 46
// обычных мероприятий из 48 владельца в `musicians` нет вовсе (перепись
// 10.08), и напоминание про собственный вечер он терять не должен.
//
// НА ШАГЕ 3 ЭТО НЕ МЕНЯЕТ НИЧЕГО: все ответы `going`, никто не перестаёт
// получать напоминания. Читатель встаёт инертным — ровно как встал писатель
// на шаге 1 (I48: необратимый шаг не должен нести чужую работу).
//
// ВЫШЕДШИЙ (`'left'`) ОТСЕИВАЕТСЯ НЕ ЗДЕСЬ, А В `recipientsOf` НИЖЕ, НА
// КОТОРОМ ЭТА ФУНКЦИЯ И СТОИТ (N121, шаг 1). Ссылка нужна ровно потому, что
// правило и его отсутствие лежат в одном файле через экран прокрутки — на
// самом опасном расстоянии (I42): без неё следующий увидит здесь фильтр по
// одному лишь `cant` и допишет второй, мёртвый в тот же день.
//
// ЗДЕСЬ ОСТАЁТСЯ ТОЛЬКО `cant`, и это разные вопросы, а не забывчивость:
// `cant` — «я не приду», человек в вечере, изменения ему идут, а напоминание
// нет; `'left'` — «меня в этом вечере больше нет», и ему не идёт НИЧЕГО.
export function remindableOf(e: EventSnapshot): string[] {
  const answers = e.answers;
  return recipientsOf(e, null).filter((uid) => {
    if (uid === e.ownerUid) return true;
    // Поля нет вовсе — сведений нет, человек в составе, значит идёт. Это
    // запасной путь для 75 записей прода, у которых поля не было никогда.
    if (!answers) return true;
    const a = answers[uid];
    // Ключа нет — то же самое: недостача ожидаема от старых сборок и от
    // mugam-v2 (docs/plan.md, шаг 3).
    if (typeof a !== "string") return true;
    return a !== "cant";
  });
}

/**
 * ВЫШЕЛ ЛИ ЧЕЛОВЕК ИЗ ВЕЧЕРА — по новой схеме, где уход это ОТВЕТ, а не
 * событие вечера (N121, шаг 1).
 *
 * До неё уход вычёркивал человека из `musicians`, и рассылка теряла его
 * даром: кого нет в составе, тому и не шлют. По новой схеме он **остаётся в
 * составе** с ключом `answers[uid] == 'left'` — и без этой проверки
 * продолжал бы получать «дата изменилась», «место изменилось» и напоминания
 * о вечере, из которого вышел.
 *
 * **ВЛАДЕЛЬЦА НЕ СНИМАЕТ НИКОГДА, и это не перестраховка.** У 46 обычных
 * мероприятий из 48 владельца в `musicians` нет вовсе (перепись 10.08), и
 * `recipientsOf` держит его отдельным слагаемым; правила выхода ему не дают
 * (`answersForSelf` требует `ownerUid != uid`). Значит `answers[owner] ==
 * 'left'` может появиться только от чужого писателя — Admin SDK или правки
 * руками в консоли (I49), — и это не повод отнимать у человека вести о
 * собственном вечере.
 */
function hasLeft(e: EventSnapshot, uid: string): boolean {
  if (uid === e.ownerUid) return false;
  return e.answers?.[uid] === "left";
}

/**
 * ЕДИНСТВЕННОЕ МЕСТО, ГДЕ РЕШАЕТСЯ «КТО ЕЩЁ ЖИВОЙ В ЭТОМ ВЕЧЕРЕ», И ЭТО
 * СКАЗАНО ЗДЕСЬ, ЧТОБЫ ТУ ЖЕ ПРОВЕРКУ НЕ ДОПИСАЛИ ВТОРЫМ МЕСТОМ.
 *
 * `remindableOf` получает отсев вышедших ОТСЮДА — он построен на этом
 * вызове, — и своей проверки на `'left'` не имеет намеренно. Второй такой
 * фильтр был бы мёртвым кодом в тот же день, когда написан, и разошёлся бы с
 * этим при первой же правке (N49, N74: одно решение — одно место). Проверок
 * при этом ДВЕ, и обе настоящие: тесты спрашивают `recipientsOf` и
 * `remindableOf` порознь, потому что порознь их и зовут.
 */
export function recipientsOf(
  e: EventSnapshot,
  actorUid: string | null,
): string[] {
  const all = new Set<string>([e.ownerUid, ...(e.musicians ?? [])]);
  all.delete("");
  if (actorUid) all.delete(actorUid);
  return [...all].filter((uid) => !hasLeft(e, uid));
}

/**
 * КТО ВЫШЕЛ ЭТОЙ ЗАПИСЬЮ — признак ПЕРЕХОДА, а не состояния (N121, шаг 1).
 *
 * `after.answers[uid] === 'left'` само по себе не годится: оно истинно и на
 * каждой последующей правке вечера, потому что владелец переносит знакомые
 * ответы как есть (`answersForParticipants`, `event_answers.dart:195`).
 * Уведомление уходило бы заново на каждое сохранение формы.
 *
 * **ЧЕТЫРЕ РАЗНЫХ «ДВАЖДЫ» СНИМАЮТСЯ ЗДЕСЬ ИЛИ РЯДОМ, И ТОЛЬКО ОДНО ИЗ НИХ
 * СТОИЛО КОДА:**
 *
 *   1. повторная запись того же `'left'` — снимается самим переходом:
 *      `before` уже `'left'`, условие ложно;
 *   2. правка вечера владельцем — снимается тем же переходом и **без единой
 *      добавочной проверки**. Перенёс — `before='left'`, `after='left'`;
 *      убрал из состава — ключ пропал, `after` не `'left'`; позвал заново —
 *      `before` нет, `after='waiting'`. Ни одного перехода;
 *   3. повторная доставка Cloud Functions — снята не здесь, а
 *      `claimNotificationOnce` (`index.ts`), маркером на `event.id`;
 *   4. `left → going → left` — **это не дубль**, а законный второй уход, и
 *      уведомить обязаны. Переход случается снова, и это верно.
 *
 * **ХОДИМ ПО КЛЮЧАМ `after`, А НЕ ПО ОБЪЕДИНЕНИЮ КЛЮЧЕЙ, и это не сужение:**
 * условие требует `after[uid] === 'left'`, значит ключ в `after` есть по
 * определению. Ключ, который есть только в `before`, перехода дать не может
 * никогда.
 *
 * **ОТДАЁТ СПИСОК, А НЕ ОДНОГО** (I11). Правила пропускают ровно один
 * изменённый ключ за запись (`affectedKeys().hasOnly([uid])`), то есть в
 * проде их всегда не больше одного; но писатель у документа не один (I49), и
 * сигнатура, возвращающая одного там, где их может быть несколько, прячет
 * тот же дефект, что `.first`. Порядок — по возрастанию uid, чтобы состав
 * рассылки не зависел от порядка ключей в карте.
 */
export function leftViaAnswers(
  before: EventSnapshot,
  after: EventSnapshot,
): string[] {
  const b = before.answers ?? {};
  const a = after.answers ?? {};
  return Object.keys(a)
    .filter((uid) => a[uid] === "left" && b[uid] !== "left")
    .sort();
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

/**
 * Отзыв — запросивший передумал. Идёт ВТОРОЙ СТОРОНЕ: это она сидела с
 * вопросом «подтверждать ли отмену», и ей надо знать, что вопроса больше
 * нет.
 *
 * Слова говорят и то, что стало с договором: без «qüvvədə qalır» человек
 * знает, что просьбы нет, но не знает, чем всё кончилось.
 */
export function pushCancelWithdrawn(
  uid: string,
  eventId: string,
  actorName: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "Ləğv təklifi geri götürüldü",
    body:
      `${actorName} müqavilənin ləğvi təklifini geri götürdü — müqavilə ` +
      `qüvvədə qalır` +
      `${e.date ? ` (${fmtEventWhen(e.date)})` : ""}`,
    data: openEvent(eventId, "event_cancel_withdrawn"),
  };
}

/**
 * Отказ — вторая сторона не согласна. Идёт ЗАПРОСИВШЕМУ: он ждёт ответа
 * на свою просьбу, и ответ отрицательный.
 *
 * Адресат берётся из `before`, а не из `after`: к этому моменту
 * `cancelRequestedBy` уже очищен — тем самым ходом, о котором шлём.
 */
export function pushCancelDeclined(
  uid: string,
  eventId: string,
  actorName: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "Ləğv təklifi qəbul edilmədi",
    body:
      `${actorName} müqavilənin ləğvi ilə razılaşmadı — müqavilə qüvvədə ` +
      `qalır` +
      `${e.date ? ` (${fmtEventWhen(e.date)})` : ""}`,
    data: openEvent(eventId, "event_cancel_declined"),
  };
}

// ТРЕТИЙ ВИД, и заведён он не ради текста, а ради КЛЮЧА ОТМЕТКИ.
//
// Отметка «уже отправлено» складывается из `(eventId, kind, дата)`. Не
// различай она вид сообщения — напоминание «вечер под вопросом» заняло бы
// ключ обычного, и после возвращения договора в силу человек не получил бы
// напоминания о самом вечере ВОВСЕ. Устаревшее сообщение не просто уходит:
// оно съедает верное.
//
// Обратная сторона названа честно: смени состояние туда-обратно — и за
// одни сутки придут два напоминания. Это не дубль, сообщения разные.
export type ReminderKind = "24h" | "3h" | "unsettled24h";

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
// ПОВОД НАЗЫВАЕТСЯ ВЕЗДЕ, где называется состояние: и в отметке на
// карточке, и в уведомлении о переходе, и в напоминании. «Под вопросом»
// без повода оставляет человека ждать неизвестно чего, а знание повода
// даёт ему собственный ход — предложить замену, спросить, отпустить (N99).
//
// СЛОВА ВРЕМЕННЫЕ И ПОМЕЧЕНЫ: автор ещё не сказал своих. Стоят в одном
// месте, замена — одна строка.
export function unsettledReasonText(
  lastActionType: EventActionType | null | undefined,
): string {
  return lastActionType === "workCancelled"
    ? "iş ləğv olundu"
    : "iştirakçı ayrıldı";
}

// Уведомление о САМОМ ПЕРЕХОДЕ. Без него состояние молчит: `diffEvents`
// не сравнивает `status`, а разбор уведомлений ветвится по
// `lastActionType`, где повода `memberLeft` нет. Вторая сторона узнавала
// бы о вопросе, только открыв карточку.
export function pushUnsettled(
  uid: string,
  eventId: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "Müqavilə şübhə altındadır",
    body: `${eventTitleOf(e)} — ${unsettledReasonText(e.lastActionType)}`,
    data: openEvent(eventId, "event_unsettled"),
  };
}

// Напоминание за сутки о вечере, вопрос по которому не решён.
//
// Идёт ОБЕИМ сторонам, а не только зовущему: владелец и так знает — ему
// нужен толчок; вторая сторона ДЕРЖИТ ВЕЧЕР, и ради неё правило и
// заводилось. Одно сообщение с названным поводом закрывает оба случая.
export function pushUnsettledReminder(
  uid: string,
  eventId: string,
  e: EventSnapshot,
): EventPush {
  return {
    uid,
    title: "Sabah: tədbir şübhə altında",
    body: `${eventTitleOf(e)} — ${unsettledReasonText(e.lastActionType)}`,
    data: openEvent(eventId, "event_reminder_unsettled24h"),
  };
}

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
  /**
   * Имена тех, у кого ключ `answers` перешёл в `'left'` этой записью, —
   * uid → имя, ровно по списку `leftViaAnswers(before, after)`.
   *
   * **ПОЛЕ ОБЯЗАТЕЛЬНОЕ, А НЕ НЕОБЯЗАТЕЛЬНОЕ, И ЭТО ЕДИНСТВЕННЫЙ ЗДЕШНИЙ
   * СТОРОЖ ПРОВОДКИ.** Сделай его `?`, и `index.ts` мог бы не передать
   * ничего: ветвь работала бы в тестах, которые имена подают сами, и молчала
   * бы именем в проде. Ровно тот случай, что N156 и N160 — тест подаёт то,
   * отсутствие чего проверяет. Обязательное поле ловит это компилятором, до
   * всякого прогона.
   *
   * **ПОЧЕМУ ИМЯ ПРИХОДИТ ГОТОВЫМ, А НЕ БЕРЁТСЯ ЗДЕСЬ.** Имя лежит в
   * `users/{uid}`, за чтением; этот модуль намеренно не знает про Firestore
   * и потому проверяется обычным тестом. Ту же границу держат
   * `cancelRequestedAtMs` и `actorName`.
   */
  leftNames: Record<string, string>;
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
/**
 * Сдвинулась ли отметка `cancelRequestedAt` — то есть подана ли НОВАЯ
 * просьба, а не переписана ли старая тем же значением.
 *
 * Отсутствие отметки считается сдвигом: старая запись без неё существует
 * (поле добавлено вместе с отменой), и молчать про неё хуже, чем
 * прислать лишнее — уведомление о непонятной просьбе человек поймёт,
 * открыв договор, а отсутствие уведомления не заметит вовсе.
 */
export function requestedAtMoved(
  before: EventSnapshot,
  after: EventSnapshot,
): boolean {
  const a = after.cancelRequestedAtMs ?? null;
  if (a === null) return true;
  return a !== (before.cancelRequestedAtMs ?? null);
}

export function planUpdatePushes(input: PlanUpdateInput): EventPush[] {
  const { eventId, before, after, actorName, leftNames } = input;
  const actor = after.lastActionBy ?? null;
  const diff = diffEvents(before, after);
  const out: EventPush[] = [];

  // ОТМЕНА ПО СОГЛАСИЮ — четыре хода, и ветвление идёт ПО ИМЕНИ ПОСТУПКА,
  // а не по разнице before/after.
  //
  // Иначе нельзя: отзыв и отказ оставляют в данных ОДИН И ТОТ ЖЕ след —
  // пустые `cancelRequestedBy`/`cancelRequestedAt`, — а извещать обязаны
  // разных людей. Никакое сравнение before с after этих двух не различит,
  // потому что различаются они не данными, а тем, КТО и ЗАЧЕМ их писал.
  // Имя приходит из самой записи и подделке не поддаётся: правила дают
  // каждое имя только тому, кто вправе совершить именно этот поступок
  // (`firestore.rules` → `withdrawsCancelRequest`/`declinesCancelRequest`
  // и `namesCancelDeed`). Поэтому здесь ему можно верить без проверок.
  switch (after.lastActionType) {
    case "cancelRequested": {
      // Признак нового запроса — СДВИГ ОТМЕТКИ ВРЕМЕНИ, а не появление
      // поля из пустого (класс N29). Отзыв и отказ возвращают поле в
      // `null`, значит «появление» по одному договору случается сколько
      // угодно раз, и признак-переход отвечал бы на вопрос «поле сейчас
      // заполнено» вместо «просьба подана». Здесь эти вопросы пока дают
      // один ответ; расходятся они в первый же день, когда появится путь,
      // не очищающий поле, — и разойдутся молча.
      if (!requestedAtMoved(before, after)) return out;
      for (const uid of recipientsOf(after, actor)) {
        out.push(pushCancelRequested(uid, eventId, actorName, after));
      }
      return out;
    }
    case "cancelConfirmed": {
      // Адресно запросившему, а не «всем кроме автора». Сегодня это одно
      // и то же — в договоре ровно двое, — но появись в мероприятии
      // третий, ему нужны другие слова: «договор отменён», а не «ваш
      // запрос подтверждён». Пусть лучше он не получит ничего, чем
      // получит неправду.
      const asked = before.cancelRequestedBy ?? null;
      if (asked && asked !== actor) {
        out.push(pushCancelConfirmed(asked, eventId, actorName, after));
      }
      return out;
    }
    case "cancelWithdrawn": {
      // Второй стороне: это она сидела с вопросом, подтверждать ли.
      for (const uid of recipientsOf(after, actor)) {
        out.push(pushCancelWithdrawn(uid, eventId, actorName, after));
      }
      return out;
    }
    case "cancelDeclined": {
      // Запросившему, и адресат берётся из `before`: в `after` поле уже
      // очищено — тем самым ходом, о котором и шлём.
      const asked = before.cancelRequestedBy ?? null;
      if (asked && asked !== actor) {
        out.push(pushCancelDeclined(asked, eventId, actorName, after));
      }
      return out;
    }
    default:
      break;
  }

  // УЧАСТНИК ВЫШЕЛ — НОВАЯ СХЕМА: переход ключа `answers` в `'left'`
  // (N121, шаг 1). Уведомляется владелец, и только он.
  //
  // --- ВЕТВЬ ВЫЛОЖЕНА ИНЕРТНОЙ, И ЭТО ЕЁ СВОЙСТВО, А НЕ НЕДОДЕЛКА ---
  //
  // Записей `answers.* == 'left'` в проде **ноль при 28 вечерах с полем
  // `answers`** (замер 27.08, `AUDIT_TODO.md` N121; канарейка к этому нулю
  // тем же проходом — `going` 18, `cant` 6, то есть разбор значение видит).
  // Писателя нет: клиент пишет уход старым путём, через `musicians`. Значит
  // выкладка этой ветви не меняет ни одного сегодняшнего уведомления, и
  // сломать она может только то, что сама же и принесла (I48 — необратимый
  // шаг идёт с одной переменной). Оживёт она на шаге 2, когда
  // `leavePersonalEvent` начнёт писать ключ, — и к тому дню будет уже в
  // проде. Перевернуть порядок нельзя: выложи клиента раньше сервера, и
  // уходы между двумя выкладками пройдут молча.
  //
  // --- ИМЯ БЕРЁТСЯ ОТ UID ПЕРЕХОДА, А НЕ ИЗ `lastActionBy` ---
  //
  // `actorName` этой ветви не годится, и это не мелочь показа. Новая запись
  // идёт правилом `answersForSelf()`, которое допускает
  // `changedKeys().hasOnly(['answers'])` — значит `lastActionBy` остаётся ОТ
  // ПРОШЛОГО ДЕЙСТВИЯ, каким бы оно ни было. «İştirakçı ayrıldı» назвал бы
  // постороннего: чаще всего владельца, потому что `index.ts` подставляет
  // `ownerUid`, когда `lastActionBy` пуст. Владелец прочитал бы, что из
  // вечера вышел он сам.
  //
  // Довод под замену написан не сегодня — он стоит в самих правилах,
  // `firestore.rules:988-995`: «ПОСТУПОК САМ СЕБЯ НАЗЫВАЕТ — изменённый
  // ключ карты и есть автор, а подделать его нельзя: `affectedKeys()
  // .hasOnly([uid])` не пустит чужое имя». Там он объясняет, почему
  // `answersForSelf` не требует подписи; здесь тот же довод даёт серверу
  // автора.
  //
  // --- ВЕТВЬ ТЕПЕРЬ ОДНА: СТАРАЯ СНЯТА 30.08 (N121, шаг 3) ---
  //
  // Здесь ниже стояла вторая, через `musicians`:
  //
  //   if (after.lastActionType === "left" && diff.removed.length > 0) {
  //     if (after.ownerUid && after.ownerUid !== actor) {
  //       out.push(pushLeft(after.ownerUid, eventId, actorName, after));
  //     }
  //     return out;
  //   }
  //
  // Она держалась ровно на одном условии, названном на шаге 1: «на трубках
  // стоят сборки, зовущие старый путь». Условие снято — обе собраны 29.08 с
  // `55ae28a`, куда шаг 2 (`7385843`) входит, — и вместе с ним снято правило
  // `leavesEvent()` в `firestore.rules`, то есть у участника больше нет
  // дороги, которую эта ветвь обслуживала.
  //
  // ПОЧЕМУ СНИМАЕТСЯ, А НЕ ОСТАЁТСЯ ЗАПАСНОЙ. Она берёт имя из `actorName`,
  // то есть из `lastActionBy`, — а после снятия правила `'left'` в этом поле
  // может оказаться только от ВЛАДЕЛЬЦА или от чужого писателя (Admin SDK,
  // консоль — I49). Оставь её, и владелец получил бы «İştirakçı ayrıldı» с
  // собственным именем на своей же правке состава. Запасная ветвь, которая
  // врёт именем, хуже её отсутствия: молчание заметно, ложное имя — нет.
  //
  // ЧТО ВСТАЁТ НА ЕЁ МЕСТО: ничего нового. Правка состава владельцем и так
  // разбирается ниже — `diff.removed` даёт «Tədbirdən çıxarıldınız», и там же
  // стоит гашение вышедшему (`before.answers?.[uid] === "left"`).
  const leftUids = leftViaAnswers(before, after);
  if (leftUids.length > 0) {
    for (const uid of leftUids) {
      if (!after.ownerUid || after.ownerUid === uid) continue;
      out.push(pushLeft(
        after.ownerUid,
        eventId,
        // Недостача имени не молчит и не печатает `undefined`: тот же
        // запасной ответ, что у `displayName` в `index.ts`, — у 7 учёток из
        // 12 поля `name` нет вовсе (N142), и «İstifadəçi ayrıldı» здесь
        // обычная жизнь, а не признак поломки.
        leftNames[uid] ?? "İstifadəçi",
        after,
      ));
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
    // Помечается ДО решения о письме, а не после: пометка отвечает на «его
    // уже трогали этой правкой», и она верна независимо от того, пишем мы
    // ему или молчим. Поставь её только в ветви с письмом — и вышедший
    // получил бы «tarixi dəyişdi» про вечер, из которого его убрали.
    touchedByActor.add(uid);
    // ВЫШЕДШЕМУ САМОМУ НЕ ПИШЕМ, ЧТО ЕГО УДАЛИЛИ (решение владельца 29.08).
    //
    // Довод его дословно: «не надо отправлять push, потому что Рафаэль
    // вышел сознательно». Удаление здесь — не поступок над человеком, а
    // уборка вслед за его собственным ходом: он ушёл, владелец подтвердил
    // это составом. Письмо «{Ad} sizi tədbirindən çıxardı» рассказало бы ему
    // о его же решении чужими словами — и прочлось бы как «меня выгнали».
    //
    // ПОЧЕМУ ЭТО ФАКТ, А НЕ ДОГАДКА, И ПОЧЕМУ ПРИЗНАК ИМЕННО ТАКОЙ.
    // Значение `'left'` в карте ответов может написать ТОЛЬКО САМ ЧЕЛОВЕК:
    // правило `answersForSelf()` требует
    // `affectedKeys().hasOnly([request.auth.uid])`, то есть чужой ключ не
    // проходит ни одной веткой. Значит `before.answers[uid] === 'left'` —
    // это подпись самого ушедшего, а не наш вывод о его намерениях. Тот же
    // довод, по которому сервер берёт отсюда имя вышедшего (N177).
    //
    // ЧИТАЕТСЯ `before`, А НЕ `after`, И ЭТО НЕ МЕЛОЧЬ: в `after` его ключа
    // уже нет — правка состава переписывает карту по составу
    // (`answersForParticipants`), и удалённый из неё выпадает. Спроси мы
    // `after`, признак был бы пуст ВСЕГДА, и гашение не сработало бы ни
    // разу — а выглядело бы это как «мы всё сделали, просто не помогло».
    //
    // ЧЕГО ЭТО НЕ ГАСИТ, и так и задумано: удаление человека, который НЕ
    // уходил, — обычный поступок владельца над участником, и о нём писать
    // обязательно. Гасится ровно случай «убрали вслед за уходом».
    if (before.answers?.[uid] === "left") continue;
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
