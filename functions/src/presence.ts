// Решение «молчать или слать push» — вынесено из index.ts отдельно и
// нарочно сделано чистым (N19).
//
// Причина: цена ошибки здесь несимметрична и невидима. Лишний push
// человек замечает и раздражается, потерянный не замечает НИКТО — ни
// отправитель, ни получатель, ни лог. Прежняя версия этого решения
// (`activeUsers.includes(uid)`) молча лишала людей уведомлений месяцами,
// и поймать это можно было только сверкой данных, а не глазами.
//
// Чистая функция позволяет проверить все сочетания старой и новой сборки
// разом, без эмулятора и без FCM.

// Окно свежести по умолчанию — для сборок, которые свой интервал
// сердцебиения не объявляют. Двойной интервал в 60 с, ровно как окно
// User.isActuallyOnline на клиенте.
export const PRESENCE_FRESH_MS = 2 * 60 * 1000;

// Нижняя граница окна. Меньше 30 с делать нельзя: одно потерянное
// сердцебиение не должно выталкивать человека, который смотрит в экран, —
// лишний push раздражает сильнее пропущенного.
export const PRESENCE_FRESH_MIN_MS = 30 * 1000;

// Сборка объявляет свой интервал сердцебиения сама, а окно — всегда
// двойное от объявленного.
//
// Почему не константой на сервере: интервал живёт в клиенте, и любое его
// изменение иначе требовало бы синхронного обновления сервера И всех
// установленных сборок разом — иначе сборка с редким сердцебиением
// начала бы получать push прямо во время чтения чата. Здесь этой связки
// нет: поля нет — работает прежнее окно 120 с, поле есть — окно ровно
// под эту сборку. Тот же приём, что с ключом activeChatId выше:
// отсутствие поля само по себе является сведением о сборке.
export function freshnessWindowMs(userData: Record<string, unknown>): number {
  const declared = userData.presenceIntervalMs;
  if (typeof declared !== "number" || !Number.isFinite(declared)) {
    return PRESENCE_FRESH_MS;
  }
  const doubled = 2 * declared;
  if (doubled < PRESENCE_FRESH_MIN_MS) return PRESENCE_FRESH_MIN_MS;
  if (doubled > PRESENCE_FRESH_MS) return PRESENCE_FRESH_MS;
  return doubled;
}

// СМОТРИТ ЛИ ЧЕЛОВЕК В ЭТУ КАРТОЧКУ МЕРОПРИЯТИЯ.
//
// Отдельное поле `activeEventId`, а не переиспользование `activeChatId`.
// Механизм один — та же отметка присутствия, то же окно свежести,
// `freshnessWindowMs` ниже, — а вопросов два: «смотрит в этот чат» и
// «смотрит в эту карточку». Нагрузить одно поле двумя смыслами значило бы
// повторить устройство, из которого выросли N19 (отметка визита глушила
// push), N21 (время визита выдавалось за время доставки) и N22 (расписка
// обнуляла чужой счётчик). В реестре на это стоит прямой запрет.
//
// Переходного окна, как у `activeChatId`, здесь НЕТ и не нужно: поля не
// было никогда, поэтому его отсутствие означает «сборка про карточки
// ничего не сообщает» — и решение по умолчанию «слать». Направление
// выбрано намеренно: лишний push заметен и поправим, потерянный не
// заметен никем.
export interface WatchEventDecisionInput {
  userData: Record<string, unknown> | undefined;
  eventId: string;
  uid: string;
  lastSeenMs: number | null;
  nowMs: number;
}

// true — человек прямо сейчас смотрит на карточку ЭТОГО мероприятия,
// push слать не надо.
export function isWatchingEventDecision(
  input: WatchEventDecisionInput,
): boolean {
  const { userData, eventId, lastSeenMs, nowMs } = input;
  if (!userData) return false;
  if (userData.activeEventId !== eventId) return false;
  if (lastSeenMs == null) return false;
  return nowMs - lastSeenMs < freshnessWindowMs(userData);
}

export interface WatchDecisionInput {
  // Документ пользователя. undefined — документа нет вовсе.
  userData: Record<string, unknown> | undefined;
  chatId: string;
  // Старый признак из документа чата: кто когда-то вошёл на экран и не
  // вышел через dispose.
  activeUsers: string[];
  uid: string;
  lastSeenMs: number | null;
  nowMs: number;
}

// true — человек смотрит в этот чат прямо сейчас, push слать не надо.
export function isWatchingChatDecision(input: WatchDecisionInput): boolean {
  const { userData, chatId, activeUsers, uid, lastSeenMs, nowMs } = input;

  // ПЕРЕХОДНОЕ ОКНО. Новая сборка пишет activeChatId ВСЕГДА, в том числе
  // как null, поэтому отсутствие самого ключа означает ровно одно: у
  // человека сборка, которая его не пишет. Для неё продолжает работать
  // прежнее правило — иначе она начнёт получать push, пока человек
  // сидит в чате, а это раздражает сильнее, чем пропущенное уведомление.
  if (
    !userData ||
    !Object.prototype.hasOwnProperty.call(userData, "activeChatId")
  ) {
    return activeUsers.includes(uid);
  }

  // Новая сборка: старый признак больше не смотрим вовсе — именно он и
  // застревал. Смотрит ли человек в ЭТОТ чат?
  if (userData.activeChatId !== chatId) return false;

  // И давно ли приложение давало о себе знать. Свёрнуто, убито, экран
  // погас или сети нет — сердцебиение прекращается, отметка протухает
  // сама. Замер на устройстве 02.08: удары прекратились в 20:46:09,
  // решение перевернулось в 20:48:10, то есть ровно по окну.
  if (lastSeenMs == null) return false;
  return nowMs - lastSeenMs < freshnessWindowMs(userData);
}
