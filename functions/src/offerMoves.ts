// ХОДЫ ПРЕДЛОЖЕНИЯ РАБОТЫ — уведомления по документу
// `chats/{chatId}/offers/{offerId}` (N130, шаг 4).
//
// --- ЗАЧЕМ ОТДЕЛЬНЫЙ МОДУЛЬ, ЕСЛИ ЕСТЬ jobOfferNotifications.ts ---
//
// Тот разбирает СТАРУЮ схему — четырнадцать полей на самом документе чата
// (`jobOfferBy`, `recipientAgreed`, `cancelledBy` и прочие), и висит на
// `chats/{chatId}`. Здесь другая схема, другой документ и другие ходы;
// общего у них ровно имя предметной области. Свести их в один разбор
// значило бы объединить два дела по совпадению названия — то самое, от чего
// предостерегает I58.
//
// Старый модуль НЕ ТРОГАЕТСЯ: он держит предложения, созданные прежним
// путём, и продолжает работать для них.
//
// --- ПОЧЕМУ МАШИНА БЫЛА НАПИСАНА И НЕ РАБОТАЛА НИ РАЗУ ---
//
// `onJobOfferRoundChanged` + `planOfferPushes` написаны и выложены, но
// висят на документе чата и разбирают старую схему раунда. Все три новых
// хода пишут ТОЛЬКО в подколлекцию `offers`
// (`job_offer_repository.dart:106, 147, 158` — ни один не трогает документ
// чата), а триггеров на подколлекцию не было ни одного: полный список путей
// — `chats/{chatId}`, `chats/{chatId}/messages/{messageId}`,
// `personalEvents/{eventId}`, `users/{uid}`, `users/{uid}/pushTokens/…`,
// `users/{uid}/statuses/…`. Отсюда и наблюдаемое: ходы делаются, экран
// меняется, уведомление не уходит никому и никогда.

/** Документ предложения в том виде, в каком его читает разбор. */
export interface OfferDoc {
  createdBy?: string | null;
  dates?: string[] | null;
  eventType?: string | null;
  answers?: Record<string, string[]> | null;
  acceptedBy?: string | null;
  withdrawnBy?: string | null;
}

export interface OfferPush {
  uid: string;
  title: string;
  body: string;
  data: Record<string, string>;
}

function openChat(chatId: string, kind: string): Record<string, string> {
  return { type: kind, chatId };
}

/**
 * «3/5» либо «3» — ДРОБЬ ПРОПАДАЕТ, КОГДА ЧИСЛА СОВПАЛИ.
 *
 * Правило взято не из головы: ровно так считает `offerFeedLine` в
 * `lib/core/job_offer/job_offer.dart`, и довод там же (25.08, по виду на
 * трубке): «1/1 gün» сообщает то же, что «1 gün», но выглядит как поломка —
 * читатель ищет, что за второе число, и не находит различия.
 *
 * **ЭТО ВТОРАЯ РЕАЛИЗАЦИЯ ОДНОГО ПРАВИЛА, И ЭТО СКАЗАНО ПРЯМО, А НЕ
 * ОБОЙДЕНО.** Первая на Dart, эта на TypeScript; сторожа через границу
 * поставить нечем — тем же нечем, чем не сторожатся имена типов push
 * (`push_route.dart`, и там это уже стоило дефекта). Разойдутся они молча:
 * в ленте будет «3 gün», в уведомлении «3/3 gün», и заметит это только
 * человек. Сведение в один источник — отдельная работа, здесь не делается.
 */
export function daysCount(picked: number, total: number): string {
  return picked === total ? `${picked}` : `${picked}/${total}`;
}

/** №1. Музыкант ответил, назвав дни. Узнаёт инициатор. */
export function pushOfferAnswered(
  uid: string, chatId: string, actorName: string,
  picked: number, total: number,
): OfferPush {
  return {
    uid,
    title: "Cavab gəldi",
    body: `${actorName} ${daysCount(picked, total)} gün seçdi`,
    data: openChat(chatId, "job_offer_answered"),
  };
}

/**
 * №2. Музыкант ответил НУЛЁМ дней — ОТДЕЛЬНАЯ НОВОСТЬ, а не «ответил».
 *
 * Ноль отмеченных — это ОТКАЗ, и по разбору 19.08 он не сводится к ответу с
 * количеством: «0/5 gün seçdi» было бы верно по числу и неверно по смыслу.
 * Инициатор, читающий уведомление, должен видеть разницу между «он назвал
 * три дня» и «он не может ни в один», не открывая чат.
 *
 * Это пятое состояние строки ленты («gələ bilmir»), и здесь оно ровно то же.
 */
export function pushOfferRefused(
  uid: string, chatId: string, actorName: string,
): OfferPush {
  return {
    uid,
    title: "Cavab gəldi",
    body: `${actorName} heç bir günə gələ bilmir`,
    data: openChat(chatId, "job_offer_answered"),
  };
}

/**
 * №3. Инициатор принял. Узнаёт музыкант.
 *
 * ВЕДЁТ В ЧАТ, А НЕ В КАЛЕНДАРЬ — решение владельца 30.08, и довод его:
 * вечеров создаётся несколько, уведомление привело бы к одному из них либо
 * к списку, и ни то ни другое не отвечает на «что произошло». Отвечает
 * карточка предложения.
 */
export function pushOfferAccepted(
  uid: string, chatId: string, actorName: string, days: number,
): OfferPush {
  return {
    uid,
    title: "Təklif qəbul edildi",
    body: `${actorName} təklifi qəbul etdi — ${days} gün`,
    data: openChat(chatId, "job_offer_accepted"),
  };
}

/**
 * №4. Инициатор отозвал. Узнаёт музыкант.
 *
 * **`pushOfferCancelled` СЮДА НЕ ГОДИТСЯ, И ЭТО НЕ ПРИДИРКА К СЛОВУ.** Тот
 * говорит «ləğv edildi» — отмена раунда на старом документе чата. У нового
 * отзыва слово другое и оно уже выбрано: строка ленты печатает «geri
 * götürüldü» (`offerFeedLine`). Назови один поступок двумя словами в двух
 * местах — и человек решит, что случились два разных.
 */
export function pushOfferWithdrawn(
  uid: string, chatId: string, actorName: string,
): OfferPush {
  return {
    uid,
    title: "İş təklifi geri götürüldü",
    body: `${actorName} iş təklifini geri götürdü`,
    data: openChat(chatId, "job_offer_withdrawn"),
  };
}

/** Кто ответил этой записью — uid, чей ключ в `answers` сдвинулся. */
export function answeredBy(before: OfferDoc, after: OfferDoc): string | null {
  const b = before.answers ?? {};
  const a = after.answers ?? {};
  for (const uid of Object.keys(a)) {
    const wasThere = Object.prototype.hasOwnProperty.call(b, uid);
    if (!wasThere) return uid;
    if (JSON.stringify(b[uid] ?? []) !== JSON.stringify(a[uid] ?? [])) return uid;
  }
  return null;
}

/**
 * Что разослать на одно обновление документа предложения.
 *
 * --- ПРИЗНАК ПЕРЕХОДА И ЗАМОК ЛОВЯТ РАЗНОЕ, И ЭТО НАДО ЗНАТЬ ПОРОЗНЬ ---
 *
 * Здесь живёт только ПРИЗНАК ПЕРЕХОДА — он отвечает на «произошло ли
 * событие»: `before.acceptedBy` пуст, `after.acceptedBy` нет. Без него
 * уведомление уходило бы на каждую запись в документ, включая переответ
 * музыканта, которых в открытом раунде сколько угодно.
 *
 * ЗАМОК (`claimNotificationOnce` в `index.ts`) отвечает на другое — «не
 * рассылали ли мы это уже»: Firestore-триггер доставляется НЕ МЕНЕЕ одного
 * раза, и у повтора `before`/`after` те же самые, то есть признак перехода
 * снова истинен.
 *
 * **Полный разбор этой пары — у `leftViaAnswers` (N121, шаг 1), и он здесь
 * не переписывается намеренно:** переписанный он однажды разойдётся с
 * оригиналом, и два наших файла станут говорить разное об одном приёме
 * (N80). Сказать надо ровно одно — что признак без замка даёт дубли на
 * ретраях, а замок без признака съедает первое настоящее уведомление
 * второго хода: ключ у него тот же.
 *
 * --- АВТОР БЕРЁТСЯ ИЗ ИЗМЕНЁННОГО КЛЮЧА, И `lastActionBy` СЮДА НЕ ЗАВОДИТСЯ ---
 *
 * В `personalEvents` подпись автора понадобилась потому, что из `musicians`
 * пропадает uid и триггер не может сказать, кто писал. **Здесь поступок сам
 * себя называет:** ответ — это сдвинутый ключ `answers`, принятие —
 * появившийся `acceptedBy`, отзыв — `withdrawnBy`. Подделать их нельзя,
 * правила держат каждое (`touchesOnlyOwnAnswer`, `acceptedBy ==
 * request.auth.uid`, `withdrawnBy == request.auth.uid`).
 *
 * Завести сюда `lastActionBy` значило бы повторить **I54**: отдать
 * участнику поле, по которому сервер судит о смысле произошедшего. Ход
 * «ответить» с приписанным `lastActionType: 'withdrawn'` по данным был бы
 * ответом, а по рассказу отзывом — и сервер поверил бы рассказу.
 *
 * --- ПОРЯДОК ВЕТВЕЙ ---
 *
 * Закрытие раунда (принятие, отзыв) разбирается ДО ответа: правила не дают
 * пройти двум ходам одной записью (`hasOnly` у каждого свой), но сойдись они
 * однажды от чужого писателя (Admin SDK, консоль — I49), человек получит
 * ОДНО уведомление о случившемся, а не два.
 */
export function planOfferMovePushes(input: {
  chatId: string;
  before: OfferDoc;
  after: OfferDoc;
  members: string[];
  actorName: string;
}): OfferPush[] {
  const { chatId, before, after, members, actorName } = input;
  const initiator = after.createdBy ?? before.createdBy ?? null;
  if (!initiator) return [];

  const total = (after.dates ?? []).length;

  // ПРИНЯТИЕ — переход, а не состояние: поле ПОЯВИЛОСЬ этой записью.
  if (!before.acceptedBy && !!after.acceptedBy) {
    const picked = (after.answers ?? {});
    return members
      .filter((m) => m !== initiator)
      .map((m) => pushOfferAccepted(
        m, chatId, actorName, (picked[m] ?? []).length,
      ));
  }

  // ОТЗЫВ — тем же признаком.
  if (!before.withdrawnBy && !!after.withdrawnBy) {
    return members
      .filter((m) => m !== initiator)
      .map((m) => pushOfferWithdrawn(m, chatId, actorName));
  }

  // ОТВЕТ — сдвинулся ключ в карте `answers`.
  //
  // Автор берётся отсюда, а не из состава: в чате может быть несколько
  // человек, и ответил ровно тот, чей ключ поехал.
  const actor = answeredBy(before, after);
  if (actor && actor !== initiator) {
    const picked = (after.answers?.[actor] ?? []).length;
    // Ноль отмеченных — отказ, и это другая новость (разбор у самой
    // функции). Расщепление стоит ЗДЕСЬ, а не в тексте: текст,
    // выбирающий себя сам по числу, прячет решение внутри строки.
    return picked === 0
      ? [pushOfferRefused(initiator, chatId, actorName)]
      : [pushOfferAnswered(initiator, chatId, actorName, picked, total)];
  }

  return [];
}
