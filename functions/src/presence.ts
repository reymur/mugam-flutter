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

// Двойной интервал сердцебиения присутствия (60 с) — ровно как окно
// User.isActuallyOnline на клиенте.
export const PRESENCE_FRESH_MS = 2 * 60 * 1000;

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

  // И давно ли приложение давало о себе знать. Свёрнуто, убито или без
  // сети — сердцебиение прекращается, отметка протухает сама.
  if (lastSeenMs == null) return false;
  return nowMs - lastSeenMs < PRESENCE_FRESH_MS;
}
