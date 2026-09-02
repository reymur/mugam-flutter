import { createSign } from "node:crypto";
import http2 from "node:http2";

// ОТПРАВКА VoIP-PUSH'А НАПРЯМУЮ В APNs — мимо FCM, и это не выбор, а
// необходимость: FCM не умеет `apns-push-type: voip` вовсе (N172).
//
// БЕЗ НОВЫХ ЗАВИСИМОСТЕЙ: `node:http2` и `node:crypto` — оба из стандартной
// поставки. Довод не про вес, а про то, что у отправки звонка не должно
// быть чужого кода в пути: ошибка здесь не роняет ничего и не пишет отказа,
// она даёт тишину (см. ниже про N186).
//
// ЧИСТЫЕ ЧАСТИ ВЫНЕСЕНЫ НАВЕРХ ФАЙЛА НАРОЧНО — по той же причине, что и в
// `pushDelivery.ts`: правило, живущее веткой внутри сетевого вызова, нельзя
// испортить и увидеть падение (I9). Здесь это важнее обычного, потому что
// проверить доставку делом можно только на живой трубке, а выбор среды и
// состав заголовков — каждый день.

/** Ключ APNs выдан 01.09; «Mugam APNs», Team Scoped, Sandbox & Production. */
export const APNS_KEY_ID = "VU77A6RG22";
/** Team ID учётной записи Apple Developer. */
export const APNS_TEAM_ID = "9X7JFR6HXR";

/**
 * Тема VoIP-push'а — ЭТО НЕ bundle id, а bundle id С СУФФИКСОМ `.voip`.
 *
 * Отдельная строка с отдельным комментарием потому, что перепутать их легко
 * и наказание за это молчаливое: APNs на чужую тему отвечает
 * `DeviceTokenNotForTopic`, а увидеть этот ответ можно только если его
 * читать — что мы и делаем ниже, но следующий читатель, «упростив» тему до
 * bundle id, получит ровно тишину.
 */
export const APNS_VOIP_TOPIC = "com.mugam.mugamFlutter.voip";

/**
 * Куда слать — РЕШАЕТСЯ ПО ПОЛЮ `environment` ДОКУМЕНТА АДРЕСА, а не
 * константой и не по тому, отладочная ли сборка сервера.
 *
 * ПОЧЕМУ ИМЕННО ТАК, А НЕ НАСТРОЙКОЙ ФУНКЦИИ. Среда — свойство ТРУБКИ, а не
 * сервера: в один и тот же момент у одного человека телефон с кабельной
 * сборкой (sandbox), у другого — из TestFlight (production). Настройка на
 * сервере — это одно значение на всех, то есть заведомо неверное для
 * половины. Клиент снимает среду с права `aps-environment` своего профиля и
 * кладёт её рядом с адресом (см. ios/Runner/VoipPushPlugin.swift).
 *
 * НЕИЗВЕСТНАЯ СРЕДА ДАЁТ `null`, А НЕ ПРАВДОПОДОБНОЕ (I50). Взять
 * production «потому что обычно так» значило бы отправить в никуда: APNs на
 * промах по среде отвечает `BadDeviceToken`, но письма всё равно нет, а
 * догадка выглядела бы как работающий код. Пусть лучше отправки не будет и
 * об этом скажет журнал.
 */
export function apnsHostFor(environment: unknown): string | null {
  if (environment === "sandbox") return "api.sandbox.push.apple.com";
  if (environment === "production") return "api.push.apple.com";
  return null;
}

/**
 * ПРИЧИНЫ ОТКАЗА, ОЗНАЧАЮЩИЕ «ЭТОГО АДРЕСА БОЛЬШЕ НЕТ».
 *
 * СПИСОК СВОЙ, А НЕ ОБЩИЙ С FCM, И ЭТО РАЗДЕЛЕНИЕ ПО ЗАДАЧЕ (I58). У FCM
 * словарь отказов свой (`messaging/registration-token-not-registered` и
 * прочие коды с текстом), у APNs — свой, из одного слова в поле `reason`.
 * Свести их в один список значило бы завести функцию, которой пришлось бы
 * спрашивать «а это чей отказ» — переключатель, то есть склейка двух дел.
 *
 * `BadDeviceToken` ЗДЕСЬ НАРОЧНО ОТСУТСТВУЕТ, и это главное решение всего
 * списка. Он приходит В ДВУХ РАЗНЫХ СЛУЧАЯХ: адрес действительно мёртв ИЛИ
 * мы промахнулись средой (боевой адрес постучался в sandbox). Второй случай
 * — наша ошибка, и удалять по ней чужой живой адрес значило бы чинить
 * исправное (I14: ложная тревога дешевле пропуска ровно до дня, когда по
 * ней начнут чинить работающее). Отличить эти два случая по ответу APNs
 * НЕЛЬЗЯ — ответ буквально один и тот же.
 */
export const DEAD_APNS_REASONS = [
  "Unregistered",
  "DeviceTokenNotForTopic",
  "TopicDisallowed",
];

export function isDeadApnsReason(reason: unknown): boolean {
  return typeof reason === "string" && DEAD_APNS_REASONS.includes(reason);
}

/**
 * Нагрузка VoIP-push'а.
 *
 * `aps` ЗДЕСЬ НЕТ, И ЭТО ВЕРНО: у VoIP-push'а нет ни звука, ни текста, ни
 * значка — он не показывается человеку вовсе, он будит процесс. Всё
 * содержимое читает `pushRegistry(_:didReceiveIncomingPushWith:...)` в
 * ios/Runner/AppDelegate.swift, и состав полей обязан совпадать с тем, что
 * он оттуда достаёт, — сторож на это стоит в
 * functions/test/voip-push.test.ts.
 *
 * `callerId` ЗДЕСЬ БЫЛ И СНЯТ СТОРОЖЕМ, а не рассуждением: он лежал в
 * нагрузке по образцу пути FCM, и вердикт «каждое поле нагрузки нативная
 * сторона достаёт из push'а» покраснел на нём в первый же прогон — читателя
 * у поля нет ни на нативной стороне, ни в Dart. Оставленное, оно было бы не
 * просто лишним: нагрузка VoIP-push'а ограничена по размеру, а поле,
 * которое никто не читает, читается следующим как «значит, где-то нужно».
 *
 * ПОЧЕМУ ВСЁ НУЖНОЕ ЛЕЖИТ ПРЯМО ЗДЕСЬ, А НЕ ДОБИРАЕТСЯ НА ТРУБКЕ: у
 * нативной стороны на отчёт в CallKit доли секунды, и ни одного чтения из
 * Firestore она сделать не успеет. Не успела — iOS снимает приложение, а
 * при повторах перестаёт доставлять VoIP-push вовсе.
 */
export function voipPayloadFor(args: {
  callkitUuid: string;
  callId: string;
  callerName: string;
  callType: "audio" | "video";
}): Record<string, string> {
  return {
    id: args.callkitUuid,
    callId: args.callId,
    nameCaller: args.callerName,
    callType: args.callType,
  };
}

/**
 * Подписанный ключ доступа к APNs (JWT, ES256).
 *
 * ДВЕ ТОНКОСТИ, КАЖДАЯ ИЗ КОТОРЫХ МОЛЧА ЛОМАЕТ ОТПРАВКУ:
 *
 * 1. ПОДПИСЬ ОБЯЗАНА БЫТЬ В ФОРМЕ `ieee-p1363` (голые r‖s), а не DER.
 *    `crypto` по умолчанию даёт DER, APNs такую подпись не принимает и
 *    отвечает `InvalidProviderToken` — то есть отказом, похожим на «ключ не
 *    тот», а не на «формат не тот».
 * 2. КЛЮЧ ПЕРЕИСПОЛЬЗУЕТСЯ, а не выписывается на каждую отправку. Apple
 *    отвечает `TooManyProviderTokenUpdates`, если выписывать чаще примерно
 *    раза в 20 минут, и этот отказ приходит НЕ на первый звонок, а на
 *    десятый — то есть в проде и не там, где его будут искать.
 */
export function buildApnsJwt(p8: string, now = Math.floor(Date.now() / 1000)): string {
  const header = { alg: "ES256", kid: APNS_KEY_ID };
  const claims = { iss: APNS_TEAM_ID, iat: now };
  const b64 = (o: unknown) =>
    Buffer.from(JSON.stringify(o)).toString("base64url");
  const signingInput = `${b64(header)}.${b64(claims)}`;
  const signature = createSign("SHA256")
    .update(signingInput)
    .sign({ key: p8, dsaEncoding: "ieee-p1363" }, "base64url");
  return `${signingInput}.${signature}`;
}

// Живёт между вызовами в тёплом экземпляре функции; холодный старт выпишет
// заново, и это нормально — ограничение Apple про частоту, а не про число.
let cachedJwt: { token: string; issuedAt: number } | null = null;
/** Apple допускает время жизни до часа; берём с запасом. */
const JWT_MAX_AGE_SECONDS = 50 * 60;

export function apnsJwt(p8: string, now = Math.floor(Date.now() / 1000)): string {
  if (cachedJwt && now - cachedJwt.issuedAt < JWT_MAX_AGE_SECONDS) {
    return cachedJwt.token;
  }
  const token = buildApnsJwt(p8, now);
  cachedJwt = { token, issuedAt: now };
  return token;
}

/** Только для сторожа: сбросить накопленный ключ. */
export function resetApnsJwtCache(): void {
  cachedJwt = null;
}

/** Чем кончилась одна отправка. Возврат, а не только журнал — вторая половина N186. */
export interface VoipSendResult {
  ok: boolean;
  status?: number;
  reason?: string;
  /** Почему не отправляли вовсе (среда неизвестна, адрес пуст). */
  skipped?: string;
}

/**
 * Одна отправка на один адрес.
 *
 * ВОЗВРАЩАЕТ ИСХОД, А НЕ `void`, И ЭТО ПРЯМОЕ ПРИМЕНЕНИЕ N186. Там уже было
 * ровно это: отправка «проходила», письма не было, и вызывающий не мог
 * различить — потому что различать было нечем, у `void` нет двух значений.
 * У звонка цена той же ошибки выше: звонящий видит «идёт вызов», вызываемый
 * не видит ничего, и пропажу не замечает НИ ОДНА из сторон.
 */
export async function sendVoipPush(args: {
  token: string;
  environment: unknown;
  payload: Record<string, string>;
  p8: string;
  now?: number;
}): Promise<VoipSendResult> {
  const host = apnsHostFor(args.environment);
  if (host === null) {
    return { ok: false, skipped: `неизвестная среда: ${String(args.environment)}` };
  }
  if (!args.token) {
    return { ok: false, skipped: "пустой адрес" };
  }

  const jwt = apnsJwt(args.p8, args.now);
  const body = JSON.stringify(args.payload);

  return await new Promise<VoipSendResult>((resolve) => {
    const client = http2.connect(`https://${host}`);
    let settled = false;
    const finish = (r: VoipSendResult) => {
      if (settled) return;
      settled = true;
      client.close();
      resolve(r);
    };

    client.on("error", (e) => finish({ ok: false, reason: `соединение: ${e.message}` }));

    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${args.token}`,
      "authorization": `bearer ${jwt}`,
      "apns-topic": APNS_VOIP_TOPIC,
      "apns-push-type": "voip",
      // 10 — «доставить немедленно». Для VoIP это разрешено и обязательно;
      // 5 (как у нашего content-available через FCM) означало бы «можно
      // придержать ради батареи», то есть ровно ту задержку до минуты,
      // ради избавления от которой всё это и делается.
      "apns-priority": "10",
      // 0 — «не хранить и не пересылать позже». Звонок, доставленный через
      // пять минут, хуже недоставленного: телефон зазвонит по разговору,
      // которого давно нет.
      "apns-expiration": "0",
      "content-type": "application/json",
      "content-length": Buffer.byteLength(body),
    });
    req.setTimeout(10_000, () => finish({ ok: false, reason: "истекло время ожидания" }));

    let status = 0;
    let raw = "";
    req.on("response", (headers) => {
      status = Number(headers[":status"] ?? 0);
    });
    req.on("data", (chunk) => {
      raw += chunk;
    });
    req.on("error", (e) => finish({ ok: false, reason: `запрос: ${e.message}` }));
    req.on("end", () => {
      if (status === 200) {
        finish({ ok: true, status });
        return;
      }
      let reason = "";
      try {
        reason = (JSON.parse(raw) as { reason?: string }).reason ?? "";
      } catch {
        reason = raw.slice(0, 200);
      }
      finish({ ok: false, status, reason });
    });

    req.end(body);
  });
}
