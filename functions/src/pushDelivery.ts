// РАЗБОР ОТКАЗА FCM — вынесен из `index.ts` чистыми функциями (N186, 30.08).
//
// Вынесено ровно по той же причине, что `planUpdatePushes` и
// `unsettledAfterMemberLeft`: правило, живущее веткой внутри триггера,
// нельзя испортить и увидеть падение. Здесь это особенно важно — обе
// половины N186 про то, ЧЕГО НЕ ВИДНО, и проверять их глазами бесполезно.

/** Что удалось вытащить из исключения FCM. */
export interface PushError {
  code: string;
  message: string;
}

/**
 * Код и текст отказа — из двух разных мест, потому что SDK кладёт их
 * по-разному.
 *
 * `errorInfo.code` — то, что кладёт `FirebaseMessagingError`; голый `code`
 * — то, что приходит от нижнего слоя. Раньше разбирался только код; текст
 * не читался вовсе, и потому N186 и стала возможной.
 */
export function pushErrorOf(e: unknown): PushError {
  const err = e as {
    errorInfo?: { code?: string; message?: string };
    code?: string;
    message?: string;
  };
  return {
    code: err?.errorInfo?.code ?? err?.code ?? "",
    message: err?.errorInfo?.message ?? err?.message ?? "",
  };
}

/**
 * Коды, которые САМИ ПО СЕБЕ означают «этого получателя больше нет».
 *
 * Замер 02.08: 673 неудачных отправки за 30 дней, из них 64 за один день, и
 * все — `registration-token-not-registered`.
 */
export const DEAD_TOKEN_CODES = [
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
];

/**
 * ОБЩИЙ КОД, КОТОРЫЙ РАЗБИРАЕТСЯ ПО ТЕКСТУ, — И ВОТ ПОЧЕМУ НЕ ПО КОДУ.
 *
 * **ЭТА ОГОВОРКА ОБЯЗАТЕЛЬНА, А НЕ ПОЯСНИТЕЛЬНА** (требование владельца
 * 29.08). Ниже стоит разбор строки сообщения — приём, который следующий
 * читатель по справедливости сочтёт неряшливостью и захочет «убрать»,
 * дописав `messaging/invalid-argument` в `DEAD_TOKEN_CODES` строкой выше.
 * Делать этого НЕЛЬЗЯ, и цена названа числом:
 *
 * `messaging/invalid-argument` — код ОБЩИЙ. Им же FCM отвечает на кривую
 * полезную нагрузку: слишком длинное тело, неверное поле `apns`, не-строку
 * в `data`. То есть он приходит и когда виноват ПОЛУЧАТЕЛЬ (токен мёртв), и
 * когда виноваты МЫ (испортили письмо). Внеси его в список смертей — и
 * первая же наша ошибка в формате письма снесёт **живые токены всех
 * адресатов разом**, молча и необратимо: сообщение уйдёт всем, всем
 * вернётся `invalid-argument`, и все токены будут удалены как мёртвые.
 * Восстановить их нечем — токен рождается только на телефоне.
 *
 * Отсюда и знаменатель, ради которого разбор строки того стоит: токенов в
 * проде **5 у 4 человек** (замер 29.08, `collectionGroup('pushTokens')`).
 * Одна ошибка в формате письма стоила бы всех пятерых.
 *
 * **ТЕКСТ НАЗЫВАЕТ ВИНОВАТОГО, А КОД — НЕТ.** Поэтому здесь перечислены
 * обороты, каждый из которых говорит именно про ТОКЕН. Сообщения про
 * полезную нагрузку («Invalid JSON payload», «data must only contain string
 * values») ни одному из них не отвечают — и не должны.
 *
 * ЧЕГО ЭТОТ СПИСОК НЕ ЛОВИТ, сказано прямо: FCM свои тексты не обещает и
 * может их поменять — тогда токен снова перестанет удаляться, и увидим мы
 * это НЕ отсюда, а по второй половине починки (счётчик недоставки ниже по
 * коду). Именно поэтому вторая половина не «заодно», а обязательна: она
 * ловит отказ, о котором первая не догадалась.
 */
export const DEAD_TOKEN_MESSAGES = [
  // Наблюдён в проде 29.08, 03:52:26.865 UTC (Рафаэль) и 27.08, 12:08:06.
  "apns device token is invalid",
  // Тот же смысл в формулировке FCM для Android/веба.
  "registration token is not a valid fcm registration token",
  "not a valid fcm registration token",
];

/**
 * Мёртв ли получатель — по коду ЛИБО по тексту.
 *
 * Порядок «сперва код, потом текст» намеренный: код надёжнее, текст —
 * запасная дорога для общего кода.
 */
export function isDeadTokenError(e: unknown): boolean {
  const { code, message } = pushErrorOf(e);
  if (code && DEAD_TOKEN_CODES.includes(code)) return true;
  if (code !== "messaging/invalid-argument") return false;
  const lower = message.toLowerCase();
  return DEAD_TOKEN_MESSAGES.some((m) => lower.includes(m));
}

/** Исход одной отправки — «ушло» или «не ушло, вот почему». */
export type PushOutcome =
  | { ok: true }
  | { ok: false; code: string; message: string; tokenDead: boolean };

/**
 * Свод по пачке отправок — то, что вызывающий обязан УВИДЕТЬ.
 *
 * Вторая половина N186: `sendFcmPush` ловил исключение, писал `logger.warn`
 * и возвращал управление как при успехе. Вызывающий не различал «ушло» и
 * «не ушло» — и не мог различить, потому что тип возврата был `void`.
 * Теперь различает по типу, а не по внимательности.
 */
export function summarize(outcomes: PushOutcome[]): {
  sent: number;
  failed: number;
  dead: number;
} {
  let sent = 0;
  let failed = 0;
  let dead = 0;
  for (const o of outcomes) {
    if (o.ok) {
      sent++;
      continue;
    }
    failed++;
    if (o.tokenDead) dead++;
  }
  return { sent, failed, dead };
}
