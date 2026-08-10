import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { getStorage } from "firebase-admin/storage";
import {
  onDocumentCreated,
  onDocumentDeleted,
  onDocumentUpdated,
  onDocumentWritten,
} from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onObjectFinalized } from "firebase-functions/v2/storage";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { logger } from "firebase-functions";
import { defineSecret, defineBoolean } from "firebase-functions/params";
import { runOrphanSweepAndRecord } from "./orphanSweep";
import { isWatchingChatDecision, isWatchingEventDecision } from "./presence";
import {
  EventPush,
  EventSnapshot,
  planUpdatePushes,
  pushAdded,
  pushDeleted,
  pushReminder,
  pushReplaced,
  recipientsOf,
  remindableOf,
  reminderKey,
  ReminderKind,
  pushUnsettled,
  pushUnsettledReminder,
  shouldCatchUp,
  unsettledAfterMemberLeft,
  eventWallClock,
  BAKU_OFFSET_MS,
} from "./eventNotifications";
import { planOfferPushes } from "./jobOfferNotifications";
import { RtcRole, RtcTokenBuilder } from "agora-token";
import { algoliasearch } from "algoliasearch";
import { randomUUID } from "crypto";
import {
  ALGOLIA_APP_ID,
  ALGOLIA_USERS_INDEX,
  toAlgoliaUserRecord,
  reindexReason,
} from "./algoliaShared";

initializeApp();
const db = getFirestore();
const messaging = getMessaging();
const FUNCTIONS_REGION = "europe-west3";

// Not a secret — Agora's own App ID is meant to ship in client builds
// (it's how a client identifies which Agora project to talk to at all);
// only the App Certificate below is sensitive, since that's what lets
// this function mint a valid token.
const AGORA_APP_ID = "f475311300aa4392a2e5ee7eff0e54ef";
const agoraAppCertificate = defineSecret("AGORA_APP_CERTIFICATE");

// ALGOLIA_APP_ID/ALGOLIA_USERS_INDEX live in ./algoliaShared (shared with
// scripts/algoliaBackfill.ts) — only the Admin API Key is sensitive (it can
// write/delete index data), so only that one goes through Secret Manager,
// same pattern as agoraAppCertificate above.
const algoliaAdminKey = defineSecret("ALGOLIA_ADMIN_KEY");

// Мёртвый токен удаляется в тот же момент, когда FCM о нём сообщил.
//
// Замер 02.08: 673 неудачных отправки за 30 дней, из них 64 за один
// сегодняшний день, и все — `registration-token-not-registered`. Проверка
// вхолостую (dryRun, ничего не доставляет) показала, что из пяти
// различных токенов прода три мертвы, и держат их девять документов на
// шестерых пользователей. То есть значительная часть всей работы
// диспетчера уходила в никуда, а документы жили дальше и накапливались.
//
// Удаляются РОВНО два кода ошибки — те, что означают «этого получателя
// больше нет». `invalid-argument` намеренно не в списке: он приходит и на
// испорченную полезную нагрузку, и удаление по нему стирало бы живые
// токены из-за нашей же ошибки в теле сообщения.
const DEAD_TOKEN_CODES = [
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
];

async function pruneIfTokenDead(
  e: unknown,
  tokenRef?: FirebaseFirestore.DocumentReference,
): Promise<void> {
  if (!tokenRef) return;
  const code = (e as { errorInfo?: { code?: string }; code?: string })
    ?.errorInfo?.code ?? (e as { code?: string })?.code;
  if (!code || !DEAD_TOKEN_CODES.includes(code)) return;
  try {
    await tokenRef.delete();
    logger.info(`[push] удалён мёртвый токен ${tokenRef.path} (${code})`);
  } catch (delErr) {
    logger.warn("Не удалось удалить мёртвый токен", { path: tokenRef.path, delErr });
  }
}

async function sendFcmPush(
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
  tokenRef?: FirebaseFirestore.DocumentReference,
): Promise<void> {
  try {
    await messaging.send({
      token,
      notification: { title, body },
      data,
      apns: { payload: { aps: { sound: "default" } } },
    });
  } catch (e) {
    logger.warn("FCM push failed", e);
    await pruneIfTokenDead(e, tokenRef);
  }
}

// Calls specifically need a SILENT push (data only, no `notification`
// field) — a visible `notification` payload makes Android show its own
// system banner independently of whatever the app itself does with the
// data, which duplicated CallKit's own incoming-call UI (confirmed live:
// user had to dismiss/accept both separately). The client's background
// message handler (see main.dart) is what shows CallKit's UI from this
// data payload — this function does NOT touch sendFcmPush/sendPushToUid,
// which every other push type (new_message, friend_request) still uses
// unchanged.
async function sendCallDataPush(
  token: string,
  data: Record<string, string>,
  tokenRef?: FirebaseFirestore.DocumentReference,
): Promise<void> {
  try {
    await messaging.send({
      token,
      data,
      android: { priority: "high" },
      // content-available:1 is what lets APNs wake a backgrounded (not
      // force-quit — that still needs the PushKit/VoIP work tracked
      // separately, see CallKitService's own TODO) app to run
      // _firebaseMessagingBackgroundHandler at all for a data-only
      // message; apns-priority 5 is Apple's required priority for
      // content-available pushes (10 is silently downgraded/rejected).
      apns: {
        headers: { "apns-priority": "5" },
        payload: { aps: { "content-available": 1 } },
      },
    });
  } catch (e) {
    logger.warn("Call data push failed", e);
    await pruneIfTokenDead(e, tokenRef);
  }
}

async function sendCallPushToUid(uid: string, data: Record<string, string>): Promise<void> {
  const tokensSnap = await db.collection("users").doc(uid).collection("pushTokens").get();
  await Promise.all(
    tokensSnap.docs.map(async (tokenDoc) => {
      const token = tokenDoc.data().token as string | undefined;
      if (!token) return;
      await sendCallDataPush(token, data, tokenDoc.ref);
    }),
  );
}

// Один токен принадлежит одному аккаунту — и это приходится удерживать
// на сервере (N20).
//
// Клиент закрывает два пути из трёх: свой прежний документ он удаляет при
// смене идентификатора устройства, а при выходе через «Çıxış» — свой
// токен. Третий путь клиенту недоступен принципиально: если аккаунт
// сменился БЕЗ явного выхода (сессия отозвана сервером, токен истёк, пока
// приложение было убито, восстановление устройства из резервной копии —
// ровно те случаи, ради которых существует _reconcileLocalStoreWithSignedInUid
// в main.dart), то запись прежнего владельца удалить уже нечем: правила
// разрешают писать в users/{uid}/pushTokens только самому владельцу, а
// приложение к этому моменту авторизовано уже как другой человек.
//
// Что тогда лежит в базе: один и тот же токен под двумя аккаунтами. Push
// одному уходит на устройство, где сидит другой, вместе с именем
// отправителя и началом сообщения. Именно так, судя по данным прода
// 02.08, и появились три общих токена, один сразу у трёх человек.
//
// Операция идемпотентна по природе (проверка существования, потом
// удаление), поэтому повторный вызов и параллельная регистрация ей
// безопасны — то же свойство, на котором построен сборщик сирот.
export const onPushTokenWritten = onDocumentWritten(
  { document: "users/{uid}/pushTokens/{deviceId}", region: FUNCTIONS_REGION },
  async (event) => {
    const token = event.data?.after?.data()?.token as string | undefined;
    if (!token) return;
    const owner = event.params.uid;

    // Запрос по коллекции-группе, а не обход всех пользователей: обход
    // стоил бы одно чтение на каждого пользователя при КАЖДОЙ регистрации
    // токена, то есть рос бы квадратично. Индекс COLLECTION_GROUP_ASC на
    // pushTokens.token заведён в firestore.indexes.json — проверено
    // экспериментом, что без него запрос падает FAILED_PRECONDITION.
    const snap = await db
      .collectionGroup("pushTokens")
      .where("token", "==", token)
      .get();

    const strays = snap.docs.filter((d) => d.ref.parent.parent?.id !== owner);
    if (strays.length === 0) return;

    for (const stray of strays) {
      await stray.ref.delete();
      logger.info(
        `[push] токен переехал к ${owner}, снят с прежнего владельца: ${stray.ref.path}`,
      );
    }
  },
);

// Fans a push out to every device a single user has registered — extracted
// here (rather than inlined a third time) only because the two
// friendRequests triggers below both need the exact same "fetch
// pushTokens, send FCM" step onNewMessage already performs; onNewMessage
// itself is left untouched to avoid risking its own working behavior.
async function sendPushToUid(
  uid: string,
  title: string,
  body: string,
  data: Record<string, string>,
): Promise<void> {
  const tokensSnap = await db.collection("users").doc(uid).collection("pushTokens").get();
  await Promise.all(
    tokensSnap.docs.map(async (tokenDoc) => {
      const token = tokenDoc.data().token as string | undefined;
      if (!token) return;
      await sendFcmPush(token, title, body, data, tokenDoc.ref);
    }),
  );
}

function previewText(type: string, text: string, fileName?: string): string {
  switch (type) {
    case "image":
      return "🖼 Şəkil";
    case "audio":
      return "🎤 Səs mesajı";
    case "video":
      return "🎥 Video";
    case "file":
      return `📄 ${fileName ?? "Fayl"}`;
    case "location":
      return "📍 Məkan";
    default:
      return (text ?? "").slice(0, 100);
  }
}

// N76 — ПОЛЯ КАРТОЧКИ ПИШУТСЯ ОДНОЙ ФУНКЦИЕЙ, А НЕ ПЯТЬЮ МЕСТАМИ.
//
// Их пять: новое сообщение, две замены превью после удаления и два
// «нечего показывать» рядом с ними. Пока полей было четыре, забыть одно
// место стоило неверного превью — заметно. С добавлением автора цена
// растёт: строка группы молча покажет чужое имя или ничьё, и увидят это
// не в тесте, а на трубке.
//
// Довод тот же, что записан выше про `previewText`: две копии одного
// правила расходятся в тот день, когда трогают любую из них.
//
// `lastMessageBy` — UID, не имя. Имя стоило бы чтения `users/{uid}` на
// КАЖДОЕ сообщение, причём сейчас оно добывается ниже по коду и только
// когда есть кому слать push; поднимать это чтение выше транзакции значит
// платить за него всегда. UID уже лежит в самом сообщении.
//
// `lastMessageIsSystem` — отдельный флаг, а НЕ проверка «имя пустое».
// У системных записей отправитель настоящий: группу создал `creatorUid`,
// вышел — `uid` вышедшего, добавил/удалил/назначил админом — `adminUid`.
// Без флага строка показала бы «Rafael Dagli: Rafael Dagli qrupdan çıxdı».
type ChatPreviewFields = {
  lastMessage: string;
  lastMessageTime: unknown;
  lastMessageSeq: number;
  lastMessageDeletedFor: string[];
  lastMessageBy: string | null;
  lastMessageIsSystem: boolean;
};

function previewFieldsFrom(data: {
  type?: string;
  text?: string;
  fileName?: string;
  senderId?: string;
  isSystem?: boolean;
  timestamp?: unknown;
  seq?: number;
  deletedFor?: string[];
}): ChatPreviewFields {
  return {
    lastMessage: previewText(data.type ?? "", data.text ?? "", data.fileName),
    lastMessageTime: data.timestamp ?? null,
    lastMessageSeq: data.seq ?? 0,
    lastMessageDeletedFor: data.deletedFor ?? [],
    lastMessageBy: data.senderId ?? null,
    lastMessageIsSystem: data.isSystem === true,
  };
}

// Показывать нечего: последнее видимое сообщение удалено, замены нет.
// Автора здесь тоже надо СНЯТЬ, а не оставить прежнего — иначе карточка
// станет пустой, но с именем, и «Ali:» повиснет над пустотой.
function emptyPreviewFields(): ChatPreviewFields {
  return {
    lastMessage: "",
    lastMessageTime: null,
    lastMessageSeq: 0,
    lastMessageDeletedFor: [],
    lastMessageBy: null,
    lastMessageIsSystem: false,
  };
}

// Поиск замены для превью, когда удалено сообщение, которое карточка
// чата сейчас показывает.
//
// Раньше здесь стоял один запрос на 50 сообщений: если все 50 оказывались
// удалены «для всех», карточка молча становилась пустой, хотя история в
// чате есть — то есть редкий случай приводил не к более дорогой работе, а
// к неверному ответу (B14).
//
// Теперь страницы расширяются: 10 → 100 → 1000. Обычный случай стал
// ДЕШЕВЛЕ прежнего (первая же страница из 10 почти всегда содержит
// неудалённое сообщение — это 10 чтений вместо 50), а платит только
// патология, ради которой всё и затевалось. Потолок остаётся, но теперь
// он на порядок дальше и о упоре в него сообщается в лог, а не молчанием.
const PREVIEW_PAGE_SIZES = [10, 100, 1000];

async function findNewestVisibleMessage(
  chatRef: FirebaseFirestore.DocumentReference,
  read: (q: FirebaseFirestore.Query) => Promise<FirebaseFirestore.QuerySnapshot>,
  chatId: string,
): Promise<FirebaseFirestore.QueryDocumentSnapshot | null> {
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
  for (const size of PREVIEW_PAGE_SIZES) {
    let q = chatRef
      .collection("messages")
      .orderBy("seq", "desc")
      .limit(size);
    if (cursor) q = q.startAfter(cursor);
    const snap = await read(q);
    if (snap.empty) return null;
    // deletedForAll фильтруется здесь, а не запросом, намеренно:
    // сообщения, написанные до появления этого поля, его просто не имеют,
    // а равенство в Firestore никогда не совпадает с отсутствующим полем —
    // where("deletedForAll","==",false) пропустил бы почти всё.
    const hit = snap.docs.find((d) => d.data().deletedForAll !== true);
    if (hit) return hit;
    // Страница короче запрошенной — история кончилась, дальше нечего.
    if (snap.size < size) return null;
    cursor = snap.docs[snap.docs.length - 1];
  }
  logger.warn(
    "findNewestVisibleMessage: упёрлись в потолок, превью станет пустым",
    { chatId, scanned: PREVIEW_PAGE_SIZES.reduce((a, b) => a + b, 0) },
  );
  return null;
}

// The chat card's preview is written EXCLUSIVELY by this file — the client
// no longer formats or writes it in any scenario (see the removal of
// _previewTextFor/_refreshLastMessagePreview in firestore_service.dart).
// That's the point: the same six-way type switch previously existed both
// here (for push bodies) and there (for the card), and two copies of a
// display format in two languages drift the moment either is touched.
//
// `lastMessageSeq` is what makes every writer of this field safely ordered
// against every other one. Firestore gives no ordering guarantee between
// trigger invocations, so a slow onNewMessage for seq 100 can land after a
// fast one for seq 101; and a delete legitimately moves the preview
// BACKWARD. Hence two different guards, not one:
//   - a new message writes only if its seq is >= the stored one;
//   - a removal acts only if the removed seq IS the stored one, i.e. the
//     preview was actually pointing at it. Removing anything older is a
//     no-op that costs a single document read and no write at all.
// Missing lastMessageSeq (every chat predating this field) reads as 0, so
// the first new message in such a chat adopts it.
async function recomputeChatPreviewAfterRemoval(
  chatId: string,
  removedSeq: number | null,
): Promise<void> {
  if (removedSeq == null) return;
  const chatRef = db.collection("chats").doc(chatId);
  try {
    await db.runTransaction(async (tx) => {
      const chatSnap = await tx.get(chatRef);
      if (!chatSnap.exists) return;
      const storedSeq: number = chatSnap.data()?.lastMessageSeq ?? 0;
      // Not the message the card is showing — nothing to do.
      if (storedSeq !== removedSeq) return;

      const replacement = await findNewestVisibleMessage(
        chatRef,
        (q) => tx.get(q),
        chatId,
      );
      if (!replacement) {
        tx.update(chatRef, emptyPreviewFields());
        return;
      }
      // Перенос `deletedFor` — намеренный: он несёт тех, кто уже скрыл
      // продвигаемое сообщение у себя, вместо того чтобы воскрешать его
      // для них. Автор продвигаемого сообщения переезжает вместе с ним.
      tx.update(chatRef, previewFieldsFrom(replacement.data()));
    });
  } catch (e) {
    logger.warn("recomputeChatPreviewAfterRemoval failed", { chatId, e });
  }
}

// Cold-start cost of this trigger, measured on-device 2026-08-01 (the chat
// card's preview is written here now, so this latency is how long a sender
// can see a stale preview after backing out of a chat):
//   first invocation after idle — 2.28s
//   warm invocations            — 0.13s
// minInstances is deliberately NOT set. At the current traffic a warm
// instance would be paid for around the clock to remove a delay that lands
// once per idle period, on the one screen transition where the user is
// already moving. Revisit when enough people are active concurrently that
// cold starts stop being rare and start being what a typical user hits.
export const onNewMessage = onDocumentCreated(
  "chats/{chatId}/messages/{messageId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const message = snap.data();
    const { chatId } = event.params;

    const senderId: string = message.senderId ?? "";
    if (!senderId) return;

    const chatSnap = await db.collection("chats").doc(chatId).get();
    if (!chatSnap.exists) return;
    const chat = chatSnap.data()!;

    const members: string[] = chat.members ?? [];

    // Everything this trigger denormalises onto the chat doc, in ONE
    // transaction instead of the two separate update() calls this used to
    // make (plus a third write the client itself used to make for the
    // preview). That document is the hottest in the schema — typing,
    // lastReadAt, deliveredTo, activeUsers and the seq allocator all used
    // to contend on it — so collapsing three writes per message into one is
    // a direct reduction in that contention, not just tidiness.
    //
    //  - messageCount: how many messages currently exist (not
    //    lifetime-ever-sent), decremented by onMessageDeleted below. Source
    //    of truth for the forward picker's "frequently contacted" ranking.
    //  - unreadCount.{uid}: per-user map, reset to 0 by markChatAsReadBy
    //    when that user opens the chat. Incremented for every member except
    //    the sender, deliberately including anyone currently in activeUsers
    //    — that only means "has the chat screen open", not "has read this".
    //  - the preview trio + lastMessageSeq: see
    //    recomputeChatPreviewAfterRemoval's comment for the ordering rules.
    //
    // Must not block or fail the push notification below, so it's caught
    // and logged rather than thrown.
    try {
      await db.runTransaction(async (tx) => {
        const chatRef = db.collection("chats").doc(chatId);
        const fresh = await tx.get(chatRef);
        if (!fresh.exists) return;
        const update: Record<string, unknown> = {
          messageCount: FieldValue.increment(1),
        };
        if (members.length > 1) {
          for (const uid of members) {
            if (uid !== senderId) {
              update[`unreadCount.${uid}`] = FieldValue.increment(1);
            }
          }
        }
        // mediaImageCount is deliberately NOT touched here. The client
        // increments it in sendImageMessage's own chat write and decrements
        // it in deleteMessageForAll, and it has to stay that way until both
        // halves can be moved in one step: every build already installed
        // keeps writing it, so a server-side counterpart would double-count
        // every image for as long as any old client is in use — and moving
        // the client half first would instead under-count for that same
        // window. Either direction needs a one-off recount to land on, which
        // is its own task, not a rider on the preview change.
        // Out-of-order trigger invocations are possible and expected; only
        // a message at least as new as the one currently displayed may
        // replace the preview.
        const storedSeq: number = fresh.data()?.lastMessageSeq ?? 0;
        const thisSeq: number = message.seq ?? 0;
        if (thisSeq >= storedSeq) {
          Object.assign(update, previewFieldsFrom(message));
        }
        tx.update(chatRef, update);
      });
    } catch (e) {
      logger.warn("onNewMessage: chat denormalisation failed", e);
    }

    const activeUsers: string[] = chat.activeUsers ?? [];
    const candidates = members.filter((uid) => uid !== senderId);
    const recipients: string[] = [];
    for (const uid of candidates) {
      if (!(await isWatchingChat(uid, event.params.chatId, activeUsers))) {
        recipients.push(uid);
      }
    }
    if (recipients.length === 0) return;

    const isGroup = !!chat.isGroup;
    const chatName: string = chat.name ?? "";

    const senderSnap = await db.collection("users").doc(senderId).get();
    const senderName: string =
      senderSnap.data()?.name ?? senderSnap.data()?.displayName ?? "İstifadəçi";

    const title = isGroup ? chatName : senderName;
    const body = `${senderName}: ${previewText(message.type, message.text, message.fileName)}`;
    const data = { chatId, type: "new_message", senderId };

    await Promise.all(
      recipients.map(async (uid) => {
        const tokensSnap = await db
          .collection("users")
          .doc(uid)
          .collection("pushTokens")
          .get();
        await Promise.all(
          tokensSnap.docs.map(async (tokenDoc) => {
            const token = tokenDoc.data().token as string | undefined;
            if (!token) return;
            await sendFcmPush(token, title, body, data, tokenDoc.ref);
          }),
        );
      }),
    );
  },
);

// messageCount's decrement half — see onNewMessage's own comment above for
// the full rationale. Symmetric trigger on the same path (deliberately no
// explicit region either, matching onNewMessage exactly, unlike the
// FUNCTIONS_REGION callables below), so a message's contribution to the
// count is removed exactly when its document actually is — regardless of
// which client code path performed the deletion (the 5-minute opportunistic
// hard-delete purge in chat_screen.dart, deleteGroupChat's batch cleanup
// below, or any future one).
//
// Deliberately no floor guard: messageCount has no backfill for messages
// that already existed before this trigger shipped (unlike mediaImageCount,
// which got a one-off migration), so hard-deleting one of those pre-
// existing messages after this deploys decrements a count that never
// counted it in the first place — messageCount can legitimately go
// negative until enough new messages arrive to bring it back up. Clamping
// that would hide the real state instead of letting it self-correct.
// Deliberately does NOT touch unreadCount, unlike messageCount above.
// unreadCount is per-user, and whether this specific deleted message was
// still unread for a given recipient depends on whether they'd already
// opened the chat since it arrived — the only per-user "last read" signal
// available is lastReadAt.$uid (firestore_service.dart's markChatAsReadBy),
// written as an ISO string by mugam-flutter only; mugam-v2's own
// markChatAsRead zeroes unreadCount.$uid directly and never writes
// lastReadAt at all. So for any recipient who last read via mugam-v2 (or
// has never opened the chat from mugam-flutter), lastReadAt.$uid would be
// absent even though they've genuinely read past this message — a
// decrement keyed off it would misfire in exactly the same wrong direction
// as a flat unconditional decrement for that whole class of users. The
// unread map is already reset to 0 unconditionally the moment any user
// next opens the chat (markChatAsReadBy), so any stale +1 from a deleted-
// but-still-unread message self-corrects at that point same as
// messageCount's own uncorrected legacy gap above — it never lingers past
// the recipient's next real read.
// ---------------------------------------------------------------------
// chats/{chatId} — гарантия наличия lastMessageTime
// ---------------------------------------------------------------------
// Существует ради одной конкретной вещи: клиент mugam-flutter сортирует
// список чатов запросом `orderBy('lastMessageTime')`, а Firestore
// ИСКЛЮЧАЕТ из результата документы, у которых поля нет вовсе (не путать
// с явным null — тот в выдачу попадает). Значит любой чат без этого поля
// не просто встанет не туда, а исчезнет из списка целиком.
//
// Поля нет ровно у одного класса чатов: созданных mugam-v2 и ещё не
// получивших ни одного сообщения. Проверено по исходникам v2
// (src/firebase/firestore.ts): при создании чата оно пишет lastMessageAt,
// createdAt и другие поля, а lastMessageTime не пишет нигде — этого
// имени в его коде нет вовсе; свой список чатов v2 сортирует по
// lastMessageAt. Первое же сообщение в таком чате закрывает дыру само
// (onNewMessage выше пишет lastMessageTime), но до него чат был бы
// невидим.
//
// Триггер на создание, а не на запись: срабатывает один раз за всю жизнь
// документа, поэтому не пополняет собой список функций, поднимающихся на
// каждую запись в этот горячий документ (см. A3 в реестре).
//
// Значение берётся из lastMessageAt (его пишут оба приложения при
// создании), с откатом на createdAt и, в последнюю очередь, на время
// срабатывания. Идемпотентно по построению: поле уже есть — выходим.
export const onChatCreated = onDocumentCreated(
  "chats/{chatId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const data = snap.data();
    if ("lastMessageTime" in data) return;

    const fallback = data.lastMessageAt ?? data.createdAt ?? FieldValue.serverTimestamp();
    try {
      await snap.ref.update({ lastMessageTime: fallback });
      logger.info("onChatCreated: backfilled lastMessageTime", {
        chatId: event.params.chatId,
      });
    } catch (e) {
      logger.warn("onChatCreated: lastMessageTime backfill failed", e);
    }
  },
);

export const onMessageDeleted = onDocumentDeleted(
  "chats/{chatId}/messages/{messageId}",
  async (event) => {
    const { chatId } = event.params;
    try {
      await db.collection("chats").doc(chatId).update({
        messageCount: FieldValue.increment(-1),
      });
    } catch (e) {
      logger.warn("onMessageDeleted: messageCount decrement failed", e);
    }
    // A hard delete of the message the card is currently showing has to
    // promote whatever is now newest. In mugam-flutter's own flow this
    // normally follows a tombstone (onMessageTombstoned below already moved
    // the preview on when deletedForAll flipped, so storedSeq no longer
    // matches and this is a cheap no-op) — but deleteGroupChat's batch
    // cleanup and any direct console delete reach here without one, and
    // those must not leave a card pointing at a document that's gone.
    await recomputeChatPreviewAfterRemoval(
      chatId,
      event.data?.data()?.seq ?? null,
    );
  },
);

// "Hamıdan sil" is a soft delete — deleteMessageForAll UPDATES the message
// (deletedForAll/deletedAt/text) rather than removing it, so the delete
// trigger above never sees it, and it is by far the more common way a
// preview stops being valid. Hence this third trigger.
//
// The false→true transition guard is the first statement on purpose: this
// path fires for every message UPDATE in every chat — a voice note being
// played (listenedBy), someone hiding a message for themselves
// (deletedFor), a reaction the callable wrote — and all of those must cost
// nothing but an immediate return.
export const onMessageTombstoned = onDocumentUpdated(
  "chats/{chatId}/messages/{messageId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    if (before.deletedForAll === true || after.deletedForAll !== true) return;

    // Preview only — mediaImageCount's decrement stays in the client's
    // deleteMessageForAll for now, for the reason spelled out at
    // onNewMessage's own increment: both halves of that counter have to
    // move together, and not during a window where older builds are still
    // writing it.
    const { chatId } = event.params;
    await recomputeChatPreviewAfterRemoval(chatId, after.seq ?? null);
  },
);

// Repairs a chat card whose preview has drifted from reality — the client
// calls this when it opens a chat and finds the document's lastMessageSeq
// behind the newest message it can actually see (including the "field
// missing entirely" case, i.e. every chat predating lastMessageSeq).
//
// It exists because the client deliberately cannot fix this itself: preview
// text is formatted in exactly one place (previewText above), server-side,
// and giving the client a second copy to self-heal with would recreate the
// duplication this whole change removes.
export const refreshChatPreview = onCall(
  { region: FUNCTIONS_REGION },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign-in required");
    }
    const chatId = request.data?.chatId;
    if (typeof chatId !== "string" || !chatId) {
      throw new HttpsError("invalid-argument", "chatId is required");
    }
    const chatRef = db.collection("chats").doc(chatId);
    const chatSnap = await chatRef.get();
    if (!chatSnap.exists) {
      throw new HttpsError("not-found", "Chat not found");
    }
    // Membership is checked here, not left to rules: a callable runs with
    // Admin credentials and bypasses firestore.rules entirely, so without
    // this any signed-in user could drive a scan+write on an arbitrary
    // chatId of their choosing.
    const members: string[] = chatSnap.data()?.members ?? [];
    if (!members.includes(uid)) {
      throw new HttpsError("permission-denied", "Not a member of this chat");
    }

    // Server-side half of the anti-stampede protection (the client
    // throttles per chat as well). Recomputing costs a query plus a
    // transaction, so a client that is wrong about the drift — or a
    // deliberately-modified one calling this in a loop — gets a single
    // cheap read and nothing else.
    const storedSeq: number = chatSnap.data()?.lastMessageSeq ?? 0;
    const replacement = await findNewestVisibleMessage(
      chatRef,
      (q) => q.get(),
      chatId,
    );
    const trueSeq: number = replacement?.data().seq ?? 0;
    if (trueSeq === storedSeq) return { updated: false };

    if (!replacement) {
      await chatRef.update(emptyPreviewFields());
      return { updated: true };
    }
    await chatRef.update(previewFieldsFrom(replacement.data()));
    return { updated: true };
  },
);

// Reactions must be written server-side only — a direct client write to a
// message's `reactions` map can't be validated by Firestore rules (rules
// see the field-level diff, not "did this transaction only touch the
// caller's own uid within the map"), so a modified client could otherwise
// forge another user's reaction. This callable is the ONLY writer of
// `reactions`; firestore.rules denies clients any direct write to it.
export const toggleMessageReaction = onCall(
  { region: FUNCTIONS_REGION },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const { chatId, messageId, emoji } = (request.data ?? {}) as {
      chatId?: string;
      messageId?: string;
      emoji?: string;
    };
    if (!chatId || !messageId || !emoji) {
      throw new HttpsError(
        "invalid-argument",
        "chatId, messageId and emoji are required.",
      );
    }

    const chatSnap = await db.collection("chats").doc(chatId).get();
    if (!chatSnap.exists) {
      throw new HttpsError("not-found", "Chat not found.");
    }
    const members: string[] = chatSnap.data()?.members ?? [];
    if (!members.includes(uid)) {
      throw new HttpsError("permission-denied", "Not a member of this chat.");
    }

    const msgRef = db
      .collection("chats")
      .doc(chatId)
      .collection("messages")
      .doc(messageId);

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(msgRef);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Message not found.");
      }
      const raw = (snap.data()?.reactions ?? {}) as Record<string, string[]>;
      const reactions: Record<string, string[]> = {};
      for (const [key, uids] of Object.entries(raw)) {
        reactions[key] = Array.isArray(uids) ? [...uids] : [];
      }
      // Same toggle semantics as the old client-side transaction: a user
      // holds at most one reaction per message. Re-tapping the same emoji
      // clears it; tapping a different one moves it.
      const hadThisEmoji = reactions[emoji]?.includes(uid) ?? false;
      for (const key of Object.keys(reactions)) {
        reactions[key] = reactions[key].filter((u) => u !== uid);
        if (reactions[key].length === 0) delete reactions[key];
      }
      if (!hadThisEmoji) {
        reactions[emoji] = [...(reactions[emoji] ?? []), uid];
      }
      tx.update(msgRef, { reactions });
    });

    return { ok: true };
  },
);

// Server-side copy for "forward photo/video to status" — copies the
// already-uploaded chat media object directly within Cloud Storage (no
// client download/re-upload round trip) into the statuses/ path, then
// stamps the copy with the same uploaderUid/statusId customMetadata
// every other status media object carries, so the existing
// visibleToUids-based Storage read rule (see storage.rules'
// statuses/{ownerUid}/{fileName} block) works identically for viewers
// of this status as for any freshly-uploaded one. Authorization is
// re-verified server-side (chat membership) rather than trusting the
// client's claim it has access to the source file — Admin SDK bypasses
// Storage rules entirely, so this check is this function's own
// responsibility, not inherited from anywhere else. copy() alone would
// carry over the source object's own uploaderUid/chatId metadata (meant
// for the chats/ path's rules, meaningless and wrong under statuses/),
// so setMetadata() afterward fully overwrites it with what the
// statuses/ read rule actually checks — confirmed via Cloud Storage's
// own docs that copy() and setMetadata() are separate, sequential
// operations, not a single atomic call with a metadata option.
export const copyMediaToStatus = onCall(
  { region: FUNCTIONS_REGION },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const { sourceChatId, sourceFileName, statusId } = (request.data ?? {}) as {
      sourceChatId?: string;
      sourceFileName?: string;
      statusId?: string;
    };
    if (!sourceChatId || !sourceFileName || !statusId) {
      throw new HttpsError(
        "invalid-argument",
        "sourceChatId, sourceFileName and statusId are required.",
      );
    }

    const chatSnap = await db.collection("chats").doc(sourceChatId).get();
    if (!chatSnap.exists) {
      throw new HttpsError("not-found", "Source chat not found.");
    }
    const members: string[] = chatSnap.data()?.members ?? [];
    if (!members.includes(uid)) {
      throw new HttpsError(
        "permission-denied",
        "Not a member of the source chat.",
      );
    }

    const bucket = getStorage().bucket();
    const sourcePath = `chats/${sourceChatId}/${sourceFileName}`;
    const destFileName = `${Date.now()}_${sourceFileName}`;
    const destPath = `statuses/${uid}/${destFileName}`;
    const sourceFile = bucket.file(sourcePath);
    const destFile = bucket.file(destPath);

    const [exists] = await sourceFile.exists();
    if (!exists) {
      throw new HttpsError("not-found", "Source media no longer exists.");
    }

    await sourceFile.copy(destFile);
    await destFile.setMetadata({
      metadata: { uploaderUid: uid, statusId },
    });

    return { path: destPath };
  },
);

// Reverse direction of copyMediaToStatus above — "forward a status'
// photo/video into a chat". Same server-side-copy shape (no client
// download/re-upload round trip), but with real extra authorization this
// direction needs that the other one doesn't:
//   - copyMediaToStatus's caller already has to be a chat member to have
//     read the source message/media at all — trivially re-verified.
//   - This function's caller could otherwise claim access to ANY status
//     (including someone else's private one) just by supplying its
//     ids — so visibleToUids (or ownership) is re-checked here against
//     the real status document, exactly like firestore.rules' own
//     visibleToUids-based read rule, since Admin SDK bypasses that rule
//     entirely and this is the only place enforcing it for this flow.
// mediaUrl is a Firebase Storage download URL, not a bare object path —
// storagePathFromDownloadUrl() below extracts the real statuses/{ownerUid}/
// {fileName} path from the status document's own trusted (already
// permission-checked) field, rather than trusting anything client-supplied
// for this — the client only ever sends ids, never a path or fileName.
//
// The destination lands at chats/{targetChatId}/{fileName} — the same
// shape onChatMediaUploaded (this file, above) already watches for any
// object finalize under chats/, so eventually it fires too and does its
// own harmless redundant validatedUploads write. This function doesn't
// wait for that: it writes the SAME validatedUploads/{targetChatId}/
// files/{fileName} marker itself, synchronously, before returning — a
// message sent by the client immediately after this call resolves must
// never race that trigger's own async firing (Storage finalize triggers
// are not guaranteed to complete before this call's response reaches the
// client). Reuses the existing storagePathFromDownloadUrl helper below
// (written for onStatusDeleted's own cascade cleanup) rather than
// declaring a second function with the same job — its nullable return is
// handled inline here instead of a throwing wrapper.
export const copyStatusMediaToChat = onCall(
  { region: FUNCTIONS_REGION },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const { statusOwnerUid, statusId, targetChatId } = (request.data ?? {}) as {
      statusOwnerUid?: string;
      statusId?: string;
      targetChatId?: string;
    };
    if (!statusOwnerUid || !statusId || !targetChatId) {
      throw new HttpsError(
        "invalid-argument",
        "statusOwnerUid, statusId and targetChatId are required.",
      );
    }

    const chatSnap = await db.collection("chats").doc(targetChatId).get();
    if (!chatSnap.exists) {
      throw new HttpsError("not-found", "Target chat not found.");
    }
    const chatMembers: string[] = chatSnap.data()?.members ?? [];
    if (!chatMembers.includes(uid)) {
      throw new HttpsError(
        "permission-denied",
        "Not a member of the target chat.",
      );
    }

    const statusSnap = await db
      .collection("users")
      .doc(statusOwnerUid)
      .collection("statuses")
      .doc(statusId)
      .get();
    if (!statusSnap.exists) {
      throw new HttpsError("not-found", "Status not found.");
    }
    const statusData = statusSnap.data()!;
    // Mirrors firestore.rules' own `allow get` on statuses/{statusId}
    // exactly: isPublic (and not privacyList-excluded) OR visibleToUids —
    // checking visibleToUids alone would wrongly reject forwarding a
    // public status from someone who can legitimately view it via
    // isPublic but isn't a friend (so isn't in visibleToUids at all).
    const isPublic = statusData.isPublic === true;
    const privacyList: string[] = statusData.privacyList ?? [];
    const visibleToUids: string[] = statusData.visibleToUids ?? [];
    const canView =
      uid === statusOwnerUid ||
      (isPublic && !privacyList.includes(uid)) ||
      visibleToUids.includes(uid);
    if (!canView) {
      throw new HttpsError("permission-denied", "No access to this status.");
    }
    const mediaUrl: string | undefined = statusData.mediaUrl;
    const mediaType: string | undefined = statusData.type;
    if (!mediaUrl || (mediaType !== "image" && mediaType !== "video")) {
      throw new HttpsError(
        "invalid-argument",
        "Status has no forwardable media.",
      );
    }

    // Explicit bucket name — matches onStatusDeleted's own proven pattern
    // (this file, below) rather than copyMediaToStatus's no-argument
    // getStorage().bucket() above, which a real emulator test run just
    // confirmed does NOT resolve to the right bucket in the demo-project
    // test environment (getStorage().bucket() depends on the app's
    // configured default bucket, which this app's own bare
    // initializeApp() call at the top of this file never sets).
    const bucket = getStorage().bucket("mugam-club.firebasestorage.app");
    const sourcePath = storagePathFromDownloadUrl(mediaUrl);
    if (!sourcePath) {
      throw new HttpsError("internal", "Could not parse status media URL.");
    }
    const sourceFile = bucket.file(sourcePath);
    const [exists] = await sourceFile.exists();
    if (!exists) {
      throw new HttpsError("not-found", "Source media no longer exists.");
    }

    const originalFileName = sourcePath.split("/").pop() ?? "file";
    const destFileName = `${Date.now()}_${originalFileName}`;
    const destPath = `chats/${targetChatId}/${destFileName}`;
    const destFile = bucket.file(destPath);

    await sourceFile.copy(destFile);
    await destFile.setMetadata({
      metadata: { uploaderUid: uid, chatId: targetChatId },
    });
    // Real values from the copied object itself — matches
    // onChatMediaUploaded's own use of object.contentType/object.size
    // exactly, rather than guessing a contentType from mediaType (which
    // would be wrong for, e.g., a PNG status image) or leaving size null
    // when the real value is one metadata call away.
    const [destMetadata] = await destFile.getMetadata();

    await db
      .collection("validatedUploads")
      .doc(targetChatId)
      .collection("files")
      .doc(destFileName)
      .set({
        uploaderUid: uid,
        contentType: destMetadata.contentType ?? null,
        size: destMetadata.size ? Number(destMetadata.size) : null,
        validatedAt: FieldValue.serverTimestamp(),
      });

    return { path: destPath, fileName: destFileName, type: mediaType };
  },
);

// Closes the gap between "a file landed in Storage" and "a message doc
// claims to point at it" — Firestore rules can't inspect Storage state
// directly, so without this, a client could write an arbitrary/external
// URL (or another chat's real file) into imageURL/videoURL/audioURL and
// the message-create rule would have no way to tell. This trigger is the
// only writer of `validatedUploads/{chatId}/files/{fileName}`; the
// firestore.rules message-create rule requires that marker to exist
// (scoped to clientPlatform=='flutter' messages only — see the rules file
// for why mugam-v2 isn't and can't be covered by this).
//
// Only validates mugam-flutter's flat upload shape (chats/{chatId}/
// {fileName}) — mugam-v2's nested chats/{chatId}/images|voice/{fileName}
// paths are intentionally left alone (3 vs 4 path segments below).
// Storage triggers must run in the same region as the bucket itself
// (confirmed us-east1 via deploy-time error, not europe-west3 like the
// other functions here) — this is a hard platform constraint, not a
// preference.
export const onChatMediaUploaded = onObjectFinalized(
  { region: "us-east1", bucket: "mugam-club.firebasestorage.app" },
  async (event) => {
    const object = event.data;
    const filePath = object.name;
    if (!filePath || !filePath.startsWith("chats/")) return;

    const parts = filePath.split("/");
    if (parts.length !== 3) return;
    const [, chatId, fileName] = parts;

    const uploaderUid = object.metadata?.uploaderUid;
    const metaChatId = object.metadata?.chatId;
    if (!uploaderUid || !metaChatId || metaChatId !== chatId) {
      logger.warn("onChatMediaUploaded: missing/mismatched metadata", {
        filePath,
        metadata: object.metadata,
      });
      return;
    }

    const chatSnap = await db.collection("chats").doc(chatId).get();
    if (!chatSnap.exists) {
      logger.warn("onChatMediaUploaded: chat not found", { filePath, chatId });
      return;
    }
    const members: string[] = chatSnap.data()?.members ?? [];
    if (!members.includes(uploaderUid)) {
      logger.warn("onChatMediaUploaded: uploader not a chat member", {
        filePath,
        uploaderUid,
      });
      return;
    }

    await db
      .collection("validatedUploads")
      .doc(chatId)
      .collection("files")
      .doc(fileName)
      .set({
        uploaderUid,
        contentType: object.contentType ?? null,
        size: object.size ? Number(object.size) : null,
        validatedAt: FieldValue.serverTimestamp(),
      });
  },
);

// Client-side document deletion is denied entirely by firestore.rules
// (`allow delete: if false` on chats/{chatId}) — Cloud Functions run with
// Admin SDK privileges and bypass rules, which is exactly why deleting a
// group has to go through a callable rather than a rules change. Only the
// group's own createdBy uid may call this, verified server-side from the
// auth context (never trusted from client-supplied data). mugam-v2's own
// deleteGroup has no caller authorization at all (verified in an earlier
// investigation pass) — this closes that gap rather than reproducing it.
export const deleteGroupChat = onCall(
  { region: FUNCTIONS_REGION },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const { chatId } = (request.data ?? {}) as { chatId?: string };
    if (!chatId) {
      throw new HttpsError("invalid-argument", "chatId is required.");
    }

    const chatRef = db.collection("chats").doc(chatId);
    const chatSnap = await chatRef.get();
    if (!chatSnap.exists) {
      throw new HttpsError("not-found", "Chat not found.");
    }
    const chat = chatSnap.data()!;
    if (!chat.isGroup) {
      throw new HttpsError(
        "invalid-argument",
        "Not a group chat — this function only deletes groups.",
      );
    }
    if (chat.createdBy !== uid) {
      throw new HttpsError(
        "permission-denied",
        "Only the group creator may delete the group.",
      );
    }
    // leaveGroup() intentionally never clears createdBy (see Phase B's own
    // documented rationale) — so if the creator has since left, createdBy
    // still points at them even though they're no longer a member. This
    // function runs with Admin SDK privileges and bypasses firestore.rules
    // entirely, so without this second check, a former creator could still
    // call it directly with a known chatId and delete a group they've
    // already left.
    if (!Array.isArray(chat.members) || !chat.members.includes(uid)) {
      throw new HttpsError(
        "permission-denied",
        "You are no longer a member of this group.",
      );
    }

    // Firestore doesn't cascade-delete subcollections — messages must be
    // removed explicitly, in pages within the 500-writes-per-batch limit,
    // before the chat doc itself can go. No orderBy/cursor needed: each
    // page is always "whatever's left", since the previous page is already
    // gone by the time the next .get() runs.
    const messagesRef = chatRef.collection("messages");
    let page = await messagesRef.limit(400).get();
    while (!page.empty) {
      const batch = db.batch();
      for (const doc of page.docs) {
        batch.delete(doc.ref);
      }
      await batch.commit();
      page = await messagesRef.limit(400).get();
    }

    // Storage cleanup (groups/{chatId}/avatar.jpg, if one was ever
    // uploaded) is a known, deliberate gap — no delete flow anywhere in
    // this codebase cleans up Storage objects on document deletion, so
    // this doesn't invent a new pattern for it. The orphaned file is
    // harmless: storage.rules still gates it to former members/admins via
    // chats/{chatId}, which no longer exists after this, and it's not
    // referenced from any UI surface once the chat doc is gone.
    await chatRef.delete();

    return { ok: true };
  },
);

// ---------------------------------------------------------------------
// users/{uid}/statuses/{statusId}.visibleToUids — denormalized audience
// ---------------------------------------------------------------------
// visibleToUids is the exact, server-computed set of uids allowed to read a
// status (see lib/firebase/models.dart's Status.visibleToUids comment for
// the full rationale — firestore.rules needs a real field to filter list/
// collectionGroup queries against, since exists()-based checks can't
// support those). This block keeps it correct in both directions: computed
// once at creation (onStatusCreated below) and kept in sync afterward as
// the owner's friends change (propagateFriendChange, called from
// onFriendRequestUpdated/onFriendRequestDeleted below).

// SCALE NOTE (leave as code comment, not a bug): bounded by how many
// currently active (non-expired) statuses a single user can have at once,
// which is naturally small (a person posts at most a handful of statuses
// per day).
async function updateVisibleToUidsForOwner(
  ownerUid: string,
  otherUid: string,
  gained: boolean,
): Promise<void> {
  const snap = await db
    .collection("users")
    .doc(ownerUid)
    .collection("statuses")
    .where("expiresAt", ">", new Date())
    .where("privacyMode", "in", ["contacts", "contactsExcept"])
    .get();

  const tasks: Promise<unknown>[] = [];
  for (const doc of snap.docs) {
    if (gained) {
      const data = doc.data();
      const privacyList: string[] = data.privacyList ?? [];
      // contactsExcept's allowlist-of-exclusions still applies to a
      // newly-gained friend — never add someone the owner explicitly
      // excluded, even though they're now friends.
      if (data.privacyMode === "contactsExcept" && privacyList.includes(otherUid)) continue;
      tasks.push(doc.ref.update({ visibleToUids: FieldValue.arrayUnion(otherUid) }));
    } else {
      // onlyShareWith is never touched by this propagation (see file
      // header / firestore.rules comment) — already excluded by the
      // privacyMode "in" filter above, so no extra guard needed here.
      tasks.push(doc.ref.update({ visibleToUids: FieldValue.arrayRemove(otherUid) }));
    }
  }
  await Promise.all(tasks);
}

// Symmetric: a friend-relationship change between a and b can affect BOTH
// a's own active statuses (regarding b) and b's own active statuses
// (regarding a) independently.
async function propagateFriendChange(a: string, b: string, gained: boolean): Promise<void> {
  await Promise.all([
    updateVisibleToUidsForOwner(a, b, gained),
    updateVisibleToUidsForOwner(b, a, gained),
  ]);
}

// ---------------------------------------------------------------------
// friendRequests/{requestId} — Facebook-style friend requests. See
// lib/firebase/models.dart's FriendRequest class for the full lifecycle
// (requestId shape, why deletion covers cancel/decline/unfriend, and why
// users/{uid}/friends is server-only) and firestore.rules for what the
// client itself is allowed to write — everything below only reacts to
// those already-validated writes, it doesn't re-validate them.
// ---------------------------------------------------------------------

export const onFriendRequestCreated = onDocumentCreated(
  "friendRequests/{requestId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const { fromUid, toUid } = snap.data();
    if (!fromUid || !toUid) return;

    const fromSnap = await db.collection("users").doc(fromUid).get();
    const fromName: string =
      fromSnap.data()?.name ?? fromSnap.data()?.displayName ?? "Bir istifadəçi";

    await sendPushToUid(
      toUid,
      "Yeni dostluq təklifi",
      `${fromName} sizə dostluq təklifi göndərdi`,
      { type: "friend_request", requestId: event.params.requestId },
    );
  },
);

export const onFriendRequestUpdated = onDocumentUpdated(
  "friendRequests/{requestId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    // Only the pending → accepted transition does anything here — no other
    // update is possible per firestore.rules, but this guard keeps the
    // trigger a no-op if that ever changes rather than assuming it.
    if (before.status === after.status || after.status !== "accepted") return;

    const { fromUid, toUid } = after;
    if (!fromUid || !toUid) return;

    const since = FieldValue.serverTimestamp();
    await Promise.all([
      db.collection("users").doc(fromUid).collection("friends").doc(toUid).set({ since }),
      db.collection("users").doc(toUid).collection("friends").doc(fromUid).set({ since }),
    ]);
    await propagateFriendChange(fromUid, toUid, true);

    const toSnap = await db.collection("users").doc(toUid).get();
    const toName: string =
      toSnap.data()?.name ?? toSnap.data()?.displayName ?? "İstifadəçi";

    await sendPushToUid(
      fromUid,
      "Dostluq təklifi qəbul edildi",
      `${toName} dostluq təklifinizi qəbul etdi`,
      { type: "friend_request_accepted", requestId: event.params.requestId },
    );
  },
);

// "Razıyam" — the recipient of an "İş təklif et" job offer accepting it.
// The client (FirestoreService.acceptJobOffer) only ever flags
// recipientAgreed on the chat doc; everything else happens here, server-
// side with the Admin SDK, specifically because personalEvents' own create
// rule requires the creator to become ownerUid, and ownerUid must stay the
// INITIATOR (jobOfferBy) here, not the accepting recipient — a client-side
// create() from the recipient's own device could never satisfy that rule.
//
// Deliberately does NOT react to cancelledBy (mugam-flutter has no
// separate "agreements" collection to log a cancellation into, unlike
// mugam-v2): cancelChat просто сбрасывает поля переговоров и проставляет
// cancelledBy, никакого PersonalEvent для отменённого предложения не
// создаётся.
//
// Прежняя редакция этого абзаца утверждала, что cancelChat пишет ещё и
// `completed: true`. В коде клиента этого не было никогда — комментарий
// врал про поведение, что хуже отсутствующего. Исправлено 02.08; самого
// поля `completed` больше нет ни у кого.
// Смотрит ли человек прямо сейчас в этот чат — то есть нужно ли молчать
// вместо push (N19). Само решение живёт в presence.ts чистой функцией,
// здесь только чтение документа: цена ошибки тут несимметрична и
// невидима (потерянный push не замечает никто), поэтому решение обязано
// быть покрыто тестами во всех сочетаниях сборок.
async function isWatchingChat(
  uid: string,
  chatId: string,
  activeUsers: string[],
): Promise<boolean> {
  try {
    const snap = await db.collection("users").doc(uid).get();
    const data = snap.data();
    return isWatchingChatDecision({
      userData: data,
      chatId,
      activeUsers,
      uid,
      lastSeenMs: data?.lastSeen?.toMillis?.() ?? null,
      nowMs: Date.now(),
    });
  } catch (e) {
    // Не смогли выяснить — считаем, что не смотрит. Лишний push лучше
    // потерянного: первый заметен и раздражает, второй не заметен вовсе.
    logger.warn("isWatchingChat failed", { uid, chatId, e });
    return false;
  }
}

// Сериализация с рекурсивной сортировкой ключей — сравнивает значения по
// содержимому, а не по случайному порядку полей в снимке. Используется
// сторожем в onChatUpdated ниже.
function canonicalJson(value: unknown): string {
  return JSON.stringify(sortKeysDeep(value));
}

function sortKeysDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeysDeep);
  if (value === null || typeof value !== "object") return value;
  // Timestamp и прочие небанальные объекты Firestore — через toJSON, иначе
  // порядок их внутренних полей тоже пришлось бы угадывать.
  const asJson = value as { toJSON?: () => unknown };
  if (typeof asJson.toJSON === "function") return asJson.toJSON();
  const obj = value as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(obj).sort()) out[k] = sortKeysDeep(obj[k]);
  return out;
}

export const onChatUpdated = onDocumentUpdated(
  "chats/{chatId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    // ПОСТОЯННЫЙ СТОРОЖ, А НЕ ВРЕМЕННАЯ ДИАГНОСТИКА (не снимать вместе с
    // A5). Одна строка на каждое обновление документа чата, с перечнем
    // изменившихся полей.
    //
    // Зачем: с 30.07 по 01.08 этот документ обновлялся 310 634 раза при
    // 441 отправленном сообщении. Минутный разрез показал не нагрузку, а
    // петлю обратной связи: ровное плато 2400–2700 записей в минуту (40 в
    // секунду) по 23 минуты подряд, включается и обрывается мгновенно,
    // ночью, при нуле сообщений в тот час. Петля исчезла 01.08, но какая
    // именно правка её оборвала — восстановить постфактум не удалось: в
    // окне перелома на устройства попало несколько сборок сразу, а
    // счётчик вызовов не знает, какое поле писалось.
    //
    // Отсюда правило: считать вызовы — мало, надо знать имя поля. Эта
    // строка стоит один console.log на обновление (в спокойные сутки ~340
    // строк) и превращает следующий такой случай из недели догадок в один
    // grep. Возврат петли виден по одному и тому же набору полей,
    // повторяющемуся десятки раз в секунду.
    //
    // Ключи сортируются рекурсивно перед сравнением намеренно: Firestore
    // не гарантирует порядок ключей в map-полях между снимками, и без
    // этого typing/deliveredTo/lastReadAt выглядели бы изменившимися
    // всегда (ровно эта ошибка уже ловилась в watchChatNegotiation.ts).
    // Имени поля мало — нужен АВТОР записи. 02.08 сторож показал 19
    // холостых `lastReadAt` после сборки с правкой, и это было принято за
    // провал правки; на деле рядом работало второе устройство со старой
    // сборкой, а лог не различал, чьи это записи. Поэтому у полей-карт,
    // ключом которых служит uid (lastReadAt, deliveredTo, deliveredSeq,
    // typing, unreadCount, negotiationSeenAt, clearedBy), выписываются
    // ещё и изменившиеся ключи: `lastReadAt{6s4Ffvk}`.
    const describe = (k: string): string => {
      const b = before[k];
      const a = after[k];
      const isMap = (v: unknown) =>
        v !== null && typeof v === "object" && !Array.isArray(v);
      if (!isMap(a) && !isMap(b)) return k;
      const bm = (isMap(b) ? b : {}) as Record<string, unknown>;
      const am = (isMap(a) ? a : {}) as Record<string, unknown>;
      const keys = Array.from(new Set([...Object.keys(bm), ...Object.keys(am)]))
        .filter((sub) => canonicalJson(bm[sub]) !== canonicalJson(am[sub]))
        .map((sub) => sub.slice(0, 7))
        .sort();
      return keys.length ? `${k}{${keys.join("|")}}` : k;
    };

    const changed = Array.from(
      new Set([...Object.keys(before), ...Object.keys(after)]),
    )
      .filter((k) => canonicalJson(before[k]) !== canonicalJson(after[k]))
      .sort()
      .map(describe);
    logger.info(`[chat-write] ${event.params.chatId} ${changed.join(",") || "(без изменений)"}`);

    if (before.recipientAgreed === true || after.recipientAgreed !== true) return;

    const initiatorUid: string | undefined = after.jobOfferBy;
    const members: string[] = after.members ?? [];
    const recipientUid = members.find((uid) => uid !== initiatorUid);
    if (!initiatorUid || !recipientUid) return;

    const recipientSnap = await db.collection("users").doc(recipientUid).get();
    const recipientName: string =
      recipientSnap.data()?.name ?? recipientSnap.data()?.displayName ?? "İstifadəçi";

    await db.collection("personalEvents").add({
      ownerUid: initiatorUid,
      date: after.eventDate ?? null,
      type: after.eventType ?? null,
      location: after.eventLocation ?? null,
      notes: after.eventNotes ?? null,
      // Field key is "musicians", not "participantUids" — that's what
      // PersonalEvent.fromFirestore actually parses (models.dart) and what
      // firestore.rules' personalEvents read-rule checks; writing
      // "participantUids" here would leave both parties unable to see
      // this event at all.
      musicians: [initiatorUid, recipientUid],
      // Ответы состава — шаг 1 работы «договоры и мероприятия — одна
      // сущность» (docs/plan.md). Пишется рядом с musicians и НИКЕМ на этом
      // шаге не читается.
      //
      // Правило то же, что у клиента (core/agreements/event_answers.dart):
      // все, кто в составе, — «идут». Здесь оно повторено литералом, а не
      // импортом, потому что импортировать через границу Dart↔TypeScript
      // нечего; цена названа вслух — это ВТОРОЙ писатель того же поля, и
      // разойтись они могут молча. Сторожем против расхождения служит
      // парный тест правил в эмуляторе и проверка состава ключей: у обоих
      // писателей ключи answers обязаны совпасть с musicians поимённо.
      //
      // «Ждём» тут появится на шаге 4 — сегодня согласие УЖЕ дано: договор
      // и рождается ровно тем, что вторая сторона нажала «Razıyam».
      answers: { [initiatorUid]: "going", [recipientUid]: "going" },
      isAgree: true,
      agreementChatId: event.params.chatId,
      partnerUid: recipientUid,
      partnerName: recipientName,
      status: "agreed",
      // Признак автора: договор родился из СОГЛАСИЯ получателя. Без него
      // автором считался владелец-инициатор, получатель попадал в
      // «добавленные участники» и сразу после собственного нажатия
      // «Razıyam» получал «Tədbirə əlavə olundunuz». Обе стороны и так
      // узнают о сделке поздравлением, а инициатор ещё и push'ем.
      lastActionBy: recipientUid,
      lastActionType: "agreed",
      // ОТМЕТКА РАУНДА. Без неё «договор этого раунда» неотличим от
      // «договор когда-либо в этом чате»: во втором и последующих раундах
      // прошлый договор лежит в том же чате всегда, и проверка ожидания
      // после «Razıyam» отвечала «готово» мгновенно — поздравление
      // выходило ДО появления нового договора (N29, замер 04.08: 610 мс).
      //
      // `jobOfferAt` подходит потому, что его переписывает каждый
      // `setJobOffer` и не трогает `saveChatEventDate` — то же поле, на
      // котором держится признак нового предложения.
      jobOfferAt: after.jobOfferAt ?? null,
      // Отмена по согласию: четыре поля вместо прежнего одного cancelledBy.
      // Каждое отвечает на один вопрос — кто предложил, когда предложил,
      // кто подтвердил, когда отменён. Прежнее имя врало по смыслу: при
      // отмене по согласию отменяют двое, а поле называло одного.
      // Переименование обошлось без миграции — поле было мёртвым (54
      // договора в проде, отменённых 0, записей ни одной).
      cancelRequestedBy: null,
      cancelRequestedAt: null,
      cancelConfirmedBy: null,
      cancelledAt: null,
      createdAt: FieldValue.serverTimestamp(),
    });

    // Здесь была ещё одна запись в chats/{chatId} — `completed: true`.
    // Убрана 02.08 вместе с самим полем: его никто никогда не читал (см.
    // комментарий на его месте в models.dart), а лишняя запись шла в тот
    // самый горячий документ, ради которого превью свели в одну
    // транзакцию (B16), а слушателей — в одного (B17).

    await sendPushToUid(
      initiatorUid,
      "İş təklifi qəbul edildi",
      `${recipientName} təklifinizlə razılaşdı`,
      { type: "job_offer_agreed", chatId: event.params.chatId },
    );
  },
);

// Recipient tapped "Razıyam" before the initiator had picked a date yet
// (FirestoreService.setWaitingForDate) — pushes the initiator so this
// nudge doesn't depend on their chat screen being live-mounted at the
// exact instant waitingForDateAt flips (mugam-flutter/chat_screen.dart's
// own negotiationSeenAt-based catch-up handles the in-app dialog
// reliably regardless; this is purely the push-notification backup for
// when the app isn't foregrounded, same as onNewMessage's own push).
// Deliberately a separate function from onChatUpdated above rather than
// folded into it — keeps the already-working accept/PersonalEvent path
// untouched while adding this.
export const onJobOfferWaitingForDate = onDocumentUpdated(
  "chats/{chatId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    if (!after.waitingForDateAt || before.waitingForDateAt === after.waitingForDateAt) {
      return;
    }

    const initiatorUid: string | undefined = after.jobOfferBy;
    if (!initiatorUid) return;

    // Mirrors onNewMessage's own activeUsers suppression (above) — skip
    // the push only, the durable waitingForDateAt/negotiationSeenAt state
    // still gets written regardless, so nothing is lost if this fires.
    const activeUsers: string[] = after.activeUsers ?? [];
    if (await isWatchingChat(initiatorUid, event.params.chatId, activeUsers)) {
      return;
    }

    const members: string[] = after.members ?? [];
    const recipientUid = members.find((uid) => uid !== initiatorUid);
    if (!recipientUid) return;

    const recipientSnap = await db.collection("users").doc(recipientUid).get();
    const recipientName: string =
      recipientSnap.data()?.name ?? recipientSnap.data()?.displayName ?? "İstifadəçi";

    await sendPushToUid(
      initiatorUid,
      "Tarix gözlənilir",
      `${recipientName} sizdən tədbir tarixini gözləyir`,
      { type: "job_offer_waiting_for_date", chatId: event.params.chatId },
    );
  },
);

export const onFriendRequestDeleted = onDocumentDeleted(
  "friendRequests/{requestId}",
  async (event) => {
    const data = event.data?.data();
    if (!data) return;
    // A pending request being deleted was a cancel or a decline — no
    // friends/ doc was ever written for it, so there's nothing to undo.
    // Only an already-accepted pair needs its friends/ docs removed here.
    if (data.status !== "accepted") return;

    const { fromUid, toUid } = data;
    if (!fromUid || !toUid) return;

    await Promise.all([
      db.collection("users").doc(fromUid).collection("friends").doc(toUid).delete(),
      db.collection("users").doc(toUid).collection("friends").doc(fromUid).delete(),
    ]);
    await propagateFriendChange(fromUid, toUid, false);
  },
);

// Computes visibleToUids once at creation time, from the owner's friends
// as they stand right now plus this status's own privacyMode/privacyList.
// This is an onCreate trigger — it fires exactly once per document, and
// the .update() below only ever touches a document that already exists by
// the time this runs, so there is no risk of this write re-triggering
// onStatusCreated itself (that would require a second onCreate event,
// which only fires for a genuinely new document). Do not "fix" this later
// by adding a guard against re-entrancy — there is nothing to guard
// against.
export const onStatusCreated = onDocumentCreated(
  "users/{uid}/statuses/{statusId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const { statusId } = event.params;
    const status = snap.data();
    const ownerUid: string = status.ownerUid;
    const privacyMode: string = status.privacyMode ?? "contacts";
    const privacyList: string[] = status.privacyList ?? [];

    let visibleToUids: string[];
    if (privacyMode === "onlyShareWith") {
      // Independent explicit allowlist — deliberately NOT derived from
      // contacts at all, same semantics as firestore.rules' old
      // statusVisibleTo() had for this mode.
      visibleToUids = [ownerUid, ...privacyList];
    } else {
      const friendsSnap = await db.collection("users").doc(ownerUid).collection("friends").get();
      const friendUids = friendsSnap.docs.map((doc) => doc.id);
      visibleToUids =
        privacyMode === "contactsExcept"
          ? [ownerUid, ...friendUids.filter((uid) => !privacyList.includes(uid))]
          : [ownerUid, ...friendUids];
    }

    // isPublic backs firestore.rules' separate `allow get` rule (a direct
    // single-doc read, e.g. viewing one person's status from their profile)
    // — true for 'contacts'/'contactsExcept' (privacyList is still the
    // exclusion list for 'contactsExcept'; the rule reads it directly, no
    // separate computation needed here), false for 'onlyShareWith', whose
    // explicit allowlist has no public-access equivalent. Independent of
    // visibleToUids, which continues to gate the unchanged `allow list`
    // rule the feed's collectionGroup query depends on.
    const isPublic = privacyMode !== "onlyShareWith";

    try {
      await snap.ref.update({ visibleToUids, isPublic });
    } catch (e) {
      // The status can be deleted (e.g. the user immediately deletes what
      // they just posted) before this trigger finishes its async friends
      // read — same class of benign race as onNewMessage/onMessageDeleted's
      // messageCount counters above. Nothing to reconcile: a deleted
      // status has no visibility left to compute.
      logger.warn("onStatusCreated: update failed (status likely deleted already)", e);
    }

    // Denormalized onto the owner's own user doc so every avatar-showing
    // screen can read User.hasActiveStatus off the same User doc it already
    // fetches, without an extra per-row status query (see that getter's own
    // comment, lib/firebase/models.dart). A separate try/catch from the
    // status update above — a different document with a different failure
    // mode, since the owner's own user doc practically always still exists
    // even on the rare "deleted moments after creation" race above.
    //
    // activeStatusIds is the missing piece mostRecentStatusExpiresAt alone
    // can't provide: a get()-able document id. A non-friend viewer's client
    // can never list users/{ownerUid}/statuses (that stays visibleToUids-
    // gated, unchanged — see firestore.rules' allow list), so without this
    // array there would be no way for them to discover which statusId(s) to
    // get() even once isPublic authorizes reading it. Symmetric with
    // onStatusDeleted's arrayRemove below, which is what keeps this self-
    // cleaning on both explicit delete and TTL-driven expiry cleanup.
    try {
      await db.collection("users").doc(ownerUid).update({
        mostRecentStatusExpiresAt: status.expiresAt,
        // Same denormalization as mostRecentStatusExpiresAt above, just
        // createdAt instead of expiresAt — backs the gold/muted ring
        // parity check (User.hasUnviewedStatusFrom, lib/firebase/
        // models.dart), which needs the owner's latest post time to
        // compare against a viewer's own lastViewedStatusOwnerAt entry for
        // that owner.
        mostRecentStatusCreatedAt: status.createdAt,
        activeStatusIds: FieldValue.arrayUnion(statusId),
      });
    } catch (e) {
      logger.warn("onStatusCreated: mostRecentStatusExpiresAt/mostRecentStatusCreatedAt/activeStatusIds update failed", e);
    }
  },
);

// ---------------------------------------------------------------------
// users/{uid}/statuses/{statusId} cascade cleanup
// ---------------------------------------------------------------------
// Firebase Storage download URLs encode the object's full path between
// "/o/" and the query string (URL-encoded) — parsing it back out avoids
// needing a separate storage-path field on the status doc; mediaUrl is
// already the single source of truth the client itself uses to display
// the media.
function storagePathFromDownloadUrl(url: string): string | null {
  const match = url.match(/\/o\/([^?]+)/);
  if (!match) return null;
  return decodeURIComponent(match[1]);
}

// Exhaustive scope, deliberately: (1) viewer records aren't cascade-
// deleted by Firestore automatically, (2) media file cleanup for
// image/video statuses. Nothing else — no push notifications to clean up
// (disabled pending a paid Apple Developer account), no other subsystem
// references statuses yet.
export const onStatusDeleted = onDocumentDeleted(
  "users/{uid}/statuses/{statusId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const { statusId } = event.params;
    const status = snap.data();
    const ownerUid: string = status.ownerUid;

    // activeStatusIds' cleanup half — see onStatusCreated's own comment for
    // the full rationale. Fires here regardless of why this document was
    // deleted: an explicit user-initiated delete (deleteStatus,
    // firestore_service.dart) and Firestore's own TTL policy on expiresAt
    // (see Status.expiresAt's doc comment, lib/firebase/models.dart) both
    // perform a real document delete, and both fire onDocumentDeleted the
    // same way — this is standard, documented Firestore/Cloud Functions
    // behavior (TTL deletions are recorded and trigger events identically
    // to any other delete), not something the local emulator can exercise
    // directly: the Firestore emulator does not run a background TTL
    // sweep, so this specific path (expiry-driven, rather than explicit-
    // delete-driven) is unverified by this repo's own test suite and rests
    // on that documented platform behavior instead. Independent try/catch,
    // same reasoning as onStatusCreated's — the owner's user doc practically
    // always still exists.
    try {
      await db.collection("users").doc(ownerUid).update({
        activeStatusIds: FieldValue.arrayRemove(statusId),
      });
    } catch (e) {
      logger.warn("onStatusDeleted: activeStatusIds update failed", e);
    }

    // (1) viewers subcollection — chunked into ≤500-op batches (Firestore's
    // hard per-batch limit) and committed sequentially, matching this
    // file's deleteGroupChat batching style above rather than firing all
    // chunks concurrently via Promise.all.
    const viewersSnap = await snap.ref.collection("viewers").get();
    const viewerDocs = viewersSnap.docs;
    for (let i = 0; i < viewerDocs.length; i += 500) {
      const batch = db.batch();
      for (const doc of viewerDocs.slice(i, i + 500)) {
        batch.delete(doc.ref);
      }
      await batch.commit();
    }

    // (2) media file, if any — text statuses have no mediaUrl.
    const mediaUrl: string | undefined = status.mediaUrl;
    if ((status.type === "image" || status.type === "video") && mediaUrl) {
      const path = storagePathFromDownloadUrl(mediaUrl);
      if (!path) {
        logger.warn("onStatusDeleted: could not parse storage path from mediaUrl", { mediaUrl });
      } else {
        try {
          await getStorage().bucket("mugam-club.firebasestorage.app").file(path).delete();
        } catch (e) {
          logger.warn("onStatusDeleted: storage cleanup failed", e);
        }
      }
    }
  },
);

// ---------------------------------------------------------------------
// users/{uid} → Algolia "users" index sync
// ---------------------------------------------------------------------
// Firestore can't do substring name search, and can't combine an
// array-contains (activityInstruments) with other filters in one query —
// see search_screen.dart's old client-side-filtering comment (now removed)
// for the full history. Algolia is now the source of truth for search;
// this keeps its "users" index in sync with every users/{uid} write.
//
// Single onWrite-style trigger rather than split onCreate/onUpdate/onDelete
// (unlike the friendRequests triggers above) — create and update both mean
// exactly the same thing here ("upsert this record"), only delete differs,
// so a single event.data.after.exists check is simpler than three exported
// functions duplicating the same record-mapping logic.
export const onUserWritten = onDocumentWritten(
  { document: "users/{uid}", region: FUNCTIONS_REGION, secrets: [algoliaAdminKey] },
  async (event) => {
    const { uid } = event.params;
    const before = event.data?.before;
    const after = event.data?.after;

    // Сердцебиение присутствия — не изменение того, что ищут (N43).
    // Правило вынесено чистой функцией в ./algoliaShared и проверено
    // тестами там же; здесь только выход до создания клиента Algolia.
    // Одна строка в журнале НА КАЖДУЮ реальную переиндексацию — и ни одной
    // на отказ. Так измеряется экономия N43: до правки таких строк ≈60 в
    // час на человека с открытым приложением, после ≈6.
    //
    // Пишется на пути «да», а не «нет», намеренно: строк на отказе было бы
    // ≈54 в час на человека, то есть журнал платил бы ровно за то, что
    // правка перестала платить.
    //
    // Причина называется словами, поэтому журнал отвечает и на «правильно
    // ли выбраны причины»: если там одни «изменилось поле online» и ни
    // одного «перешагнул отрезок», значит присутствие переворачивает флаг
    // чаще, чем мы думали, и порог экономит не то.
    const reason = reindexReason(
      before?.exists ? before.data() : undefined,
      after?.exists ? after.data() : undefined,
    );
    if (reason === null) return;
    logger.info("algolia reindex", { uid, reason });

    const client = algoliasearch(ALGOLIA_APP_ID, algoliaAdminKey.value());

    try {
      if (!after?.exists) {
        await client.deleteObject({ indexName: ALGOLIA_USERS_INDEX, objectID: uid });
        return;
      }
      await client.saveObject({
        indexName: ALGOLIA_USERS_INDEX,
        body: toAlgoliaUserRecord(uid, after.data()!),
      });
    } catch (e) {
      // Search-index sync failing must never fail the underlying Firestore
      // write it's reacting to (this trigger runs after that write already
      // committed) — same "log and move on" treatment as every other
      // best-effort side effect in this file (messageCount, pushes, etc.).
      logger.warn("onUserWritten: Algolia sync failed", { uid }, e);
    }
  },
);

// channelName is expected to be an existing calls/{callId} — startCall
// (below) sets channelName == callId for exactly this reason, so this can
// re-fetch that same doc and verify the caller is really one of its two
// named participants (callerId/calleeId) before minting a token, matching
// the membership check every other onCall function in this file already
// does against its own resource.
export const generateAgoraToken = onCall(
  { region: FUNCTIONS_REGION, secrets: [agoraAppCertificate] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const { channelName } = (request.data ?? {}) as { channelName?: string };
    if (
      !channelName ||
      !/^[a-zA-Z0-9 !#$%&()+\-:;<=.>?@[\]^_{}|~,]{1,63}$/.test(channelName)
    ) {
      throw new HttpsError("invalid-argument", "Valid channelName is required.");
    }
    const callSnap = await db.collection("calls").doc(channelName).get();
    if (!callSnap.exists) {
      throw new HttpsError("not-found", "Call not found.");
    }
    const call = callSnap.data()!;
    if (call.callerId !== uid && call.calleeId !== uid) {
      throw new HttpsError("permission-denied", "Not a participant of this call.");
    }
    const token = RtcTokenBuilder.buildTokenWithUserAccount(
      AGORA_APP_ID,
      agoraAppCertificate.value(),
      channelName,
      uid,
      RtcRole.PUBLISHER,
      3600,
      3600,
    );
    return { appId: AGORA_APP_ID, channelName, uid, token };
  },
);

// calls/{callId} signaling — channelName is deliberately just the callId
// itself (not a separately-generated value) so the client never has to
// round-trip a second id: generateAgoraToken above already accepts any
// caller-supplied channelName, and the callId this function returns is
// exactly what both caller and callee (once they read the doc) pass to it.
export const startCall = onCall(
  { region: FUNCTIONS_REGION },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const { calleeUid, type } = (request.data ?? {}) as {
      calleeUid?: string;
      type?: "audio" | "video";
    };
    if (!calleeUid || !type) {
      throw new HttpsError("invalid-argument", "calleeUid and type are required.");
    }

    const callRef = db.collection("calls").doc();
    const callId = callRef.id;
    // CallKit (iOS) requires its own id to be a real UUID — a Firestore
    // auto-doc id like `callId` isn't one, and the plugin silently no-ops
    // showCallkitIncoming when it fails to parse one (see
    // CallKitService.showIncoming's own comment on this). Generated once,
    // here, and handed to both sides via the call doc (caller reads it back
    // through callProvider once this returns) and this push payload
    // (callee's FCM background handler has no other way to get it without
    // an extra Firestore round-trip) — never generated independently on
    // either client, or caller and callee would show mismatched CallKit ids
    // for the same call.
    const callkitUuid = randomUUID();
    // Resolved here, server-side, and handed to the callee the same two
    // ways as callkitUuid above (call doc + push payload) — so the
    // callee's native CallKit UI can show the real caller name immediately
    // instead of a placeholder, without an extra round-trip on their end
    // (which would delay the native UI showing at all, defeating the
    // purpose — see showIncoming's own callerName param).
    const callerSnap = await db.collection("users").doc(uid).get();
    // users/{uid} docs use `displayName`, not `name` — matches the same
    // name/displayName fallback the client's own User.fromFirestore uses.
    const callerData = callerSnap.data();
    const callerName =
      (callerData?.name as string | undefined) ||
      (callerData?.displayName as string | undefined) ||
      "Zəng";
    await callRef.set({
      callerId: uid,
      calleeId: calleeUid,
      status: "ringing",
      type,
      channelName: callId,
      callkitUuid,
      callerName,
      createdAt: FieldValue.serverTimestamp(),
    });

    await sendCallPushToUid(calleeUid, {
      type: "incoming_call",
      callId,
      callkitUuid,
      callerId: uid,
      callType: type,
      callerName,
    });

    return { callId };
  },
);

export const respondToCall = onCall(
  { region: FUNCTIONS_REGION },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const { callId, accept } = (request.data ?? {}) as {
      callId?: string;
      accept?: boolean;
    };
    if (!callId || typeof accept !== "boolean") {
      throw new HttpsError("invalid-argument", "callId and accept are required.");
    }

    const callRef = db.collection("calls").doc(callId);
    const callSnap = await callRef.get();
    if (!callSnap.exists) {
      throw new HttpsError("not-found", "Call not found.");
    }
    if (callSnap.data()?.calleeId !== uid) {
      throw new HttpsError("permission-denied", "Not the callee of this call.");
    }

    await callRef.update({ status: accept ? "accepted" : "declined" });
    return { ok: true };
  },
);

export const endCall = onCall(
  { region: FUNCTIONS_REGION },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    const { callId } = (request.data ?? {}) as { callId?: string };
    if (!callId) {
      throw new HttpsError("invalid-argument", "callId is required.");
    }

    const callRef = db.collection("calls").doc(callId);
    const callSnap = await callRef.get();
    if (!callSnap.exists) {
      throw new HttpsError("not-found", "Call not found.");
    }
    const call = callSnap.data()!;
    if (call.callerId !== uid && call.calleeId !== uid) {
      throw new HttpsError("permission-denied", "Not a participant of this call.");
    }

    await callRef.update({ status: "ended" });
    return { ok: true };
  },
);

// ---------------------------------------------------------------------
// Регулярный сборщик осиротевших объектов Storage
// ---------------------------------------------------------------------
// Что считается сиротой и почему механизм один на B11 / статусы /
// B19-B21 — см. orphanSweep.ts, там же оба урока, которые нельзя
// «оптимизировать» обратно.
//
// Удаление выключено по умолчанию и включается ОТДЕЛЬНЫМ осознанным
// шагом: строка ORPHAN_SWEEP_DELETE=true в functions/.env плюс
// повторный деплой. Так сделано ровно потому, что закоммиченная
// удаляющая функция иначе активировалась бы при первом же
// `firebase deploy` по любому постороннему поводу — молча и для всех
// сразу. Значение параметра лежит в git, то есть состояние флага видно
// в истории, а не только в консоли GCP.
const orphanSweepDelete = defineBoolean("ORPHAN_SWEEP_DELETE", { default: false });

// Расписание, а не реакция на событие: сирота по определению не
// порождает события (документа, на удаление которого можно было бы
// подписаться, у неё никогда не было) — именно поэтому onStatusDeleted
// её и не достаёт.
//
// Лимиты не «на глазок», а от замера самой этой функции в проде
// (02.08, 805 документов, 40 объектов): обход ссылок 4.3 с, листинг
// Storage 0.7 с, весь прогон 5.0 с. При бюджете 480 с это запас
// примерно в 90 раз по числу документов. Число названо потому, что
// первая оценка была неверной дважды: «единицы секунд, запас в сотни
// раз» при реальных 90 с, потом 17 с с ноутбука — и только замер
// изнутри региона показал настоящую цифру.
//
// Память и время держатся не таймаутом рантайма, а устройством самого
// прогона: и документы, и объекты Storage читаются страницами, а бюджет
// времени задан ЯВНО и меньше таймаута — прогон обязан свернуться сам и
// записать отчёт, а не быть убитым на середине без следа. Остаток
// работы при этом не теряется: следующий прогон продолжит, сборщик
// идемпотентен.
const ORPHAN_SWEEP_TIMEOUT_SECONDS = 540;
const ORPHAN_SWEEP_TIME_BUDGET_MS = (ORPHAN_SWEEP_TIMEOUT_SECONDS - 60) * 1000;

// Регулярная проверка живости push-токенов (N20).
//
// Зачем нужна отдельно от уборки при отправке: `pruneIfTokenDead` снимает
// мёртвый токен только когда по нему пытались что-то отправить. Токен
// человека, которому давно никто не пишет, остаётся лежать вечно —
// именно так и накопились 7 мёртвых документов из 9 к 02.08, при 673
// неудачных отправках за 30 дней.
//
// Живость выясняется отправкой ВХОЛОСТУЮ: FCM проверяет токен, но не
// доставляет ничего — ни одного уведомления ни на один телефон. Это
// делает механизм безопасным для регулярного запуска, в отличие от
// «отправим и посмотрим».
//
// Цена замера 02.08: 5 различных токенов на весь проект, то есть 5
// проверок и один обход крошечной коллекции. Дешевле, чем сборщик сирот,
// которому нужен обход всей базы.
//
// Удаление, как и у сборщика сирот, выключено по умолчанию: сначала
// отчёт в логах, включение — отдельным шагом через переменную окружения
// плюс деплой.
const pushTokenSweepDelete = defineBoolean("PUSH_TOKEN_SWEEP_DELETE", {
  default: false,
});

export const sweepDeadPushTokensDaily = onSchedule(
  {
    region: FUNCTIONS_REGION,
    // На 15 минут позже сборщика сирот — намеренно врозь, чтобы в логах
    // два независимых прогона не переплетались.
    schedule: "every day 04:35",
    timeZone: "Asia/Baku",
    maxInstances: 1,
    retryCount: 0,
  },
  async () => {
    const dryRun = !pushTokenSweepDelete.value();
    const startedAtMs = Date.now();
    const docs = await db.collectionGroup("pushTokens").get();

    // Группировка по токену: один и тот же токен может лежать в
    // нескольких документах, а проверять его повторно незачем.
    const byToken = new Map<string, FirebaseFirestore.DocumentReference[]>();
    for (const d of docs.docs) {
      const token = d.data().token as string | undefined;
      if (!token) continue;
      const list = byToken.get(token) ?? [];
      list.push(d.ref);
      byToken.set(token, list);
    }

    const dead: string[] = [];
    for (const [token, refs] of byToken) {
      let code = "";
      try {
        await messaging.send({ token, notification: { title: "x", body: "x" } }, true);
        continue;
      } catch (e) {
        code =
          (e as { errorInfo?: { code?: string } })?.errorInfo?.code ??
          (e as { code?: string })?.code ??
          "";
      }
      if (!DEAD_TOKEN_CODES.includes(code)) continue;
      for (const ref of refs) {
        dead.push(ref.path);
        if (!dryRun) await ref.delete();
      }
    }

    await db
      .collection("maintenance")
      .doc("pushTokenSweep")
      .collection("runs")
      .add({
        dryRun,
        startedAt: new Date(startedAtMs),
        finishedAt: new Date(),
        durationMs: Date.now() - startedAtMs,
        scannedDocs: docs.size,
        distinctTokens: byToken.size,
        deadPaths: dead.slice(0, 200),
        deadCount: dead.length,
        deleted: dryRun ? 0 : dead.length,
      })
      .catch((e) => logger.warn("sweepDeadPushTokens: не записал прогон", e));

    logger.info("sweepDeadPushTokensDaily: finished", {
      dryRun,
      scannedDocs: docs.size,
      distinctTokens: byToken.size,
      deadCount: dead.length,
    });
  },
);

export const sweepOrphanMediaDaily = onSchedule(
  {
    region: FUNCTIONS_REGION,
    schedule: "every day 04:20",
    timeZone: "Asia/Baku",
    timeoutSeconds: ORPHAN_SWEEP_TIMEOUT_SECONDS,
    memory: "512MiB",
    // Один прогон за раз: параллельные прогоны друг другу не опасны
    // (сборщик идемпотентен), но удвоили бы чтения ни за чем.
    maxInstances: 1,
    // Ретраев нет намеренно: неудачный прогон не нужно повторять — через
    // сутки придёт следующий и увидит ту же картину, а сборщик от этого
    // ничего не теряет.
    retryCount: 0,
  },
  async () => {
    const dryRun = !orphanSweepDelete.value();
    const result = await runOrphanSweepAndRecord({
      db,
      bucket: getStorage().bucket("mugam-club.firebasestorage.app"),
      dryRun,
      deadlineMs: Date.now() + ORPHAN_SWEEP_TIME_BUDGET_MS,
      trigger: "scheduled",
    });
    logger.info("sweepOrphanMediaDaily: finished", {
      dryRun,
      orphans: result.orphans.length,
      orphanBytes: result.orphanBytes,
      deleted: result.deleted,
      stoppedEarly: result.stoppedEarly,
      stopReason: result.stopReason,
    });
  },
);

// ===========================================================================
// УВЕДОМЛЕНИЯ ОБ ИЗМЕНЕНИЯХ МЕРОПРИЯТИЯ
// ===========================================================================
// Всё, что меняет мероприятие и касается другого человека, шлётся ОТСЮДА, с
// сервера, а не из приложения. Причина не в удобстве: клиентское
// уведомление не уйдёт вовсе, когда приложение закрыто, — а закрыто оно как
// раз тогда, когда уведомление и нужно, — и продублируется при повторе
// отправки. Тот же довод, по которому превью сообщений переехало на сервер
// (B16) и по которому создание договора живёт в onChatUpdated.
//
// Тексты и правила «кому и что» лежат в eventNotifications.ts чистыми
// функциями и покрыты тестами без эмулятора: цена ошибки несимметрична —
// лишнее уведомление человек заметит и пожалуется, потерянное не заметит
// никто.

// ИДЕМПОТЕНТНОСТЬ. Cloud Functions гарантирует доставку события «хотя бы
// один раз», то есть повтор при сбое — норма, а не исключение. Без защиты
// человек получил бы два одинаковых уведомления, и это ровно тот дефект,
// который в чате уже ловили (B15, залипший счётчик от повторного вызова).
//
// Ключ — id самого события Cloud Functions: он стабилен между повторами
// одной доставки и различен у разных изменений. Маркер кладётся в отдельную
// коллекцию, а НЕ в документ мероприятия: запись в него подняла бы этот же
// триггер снова и породила уведомление о собственном уведомлении.
async function claimNotificationOnce(eventKey: string): Promise<boolean> {
  const ref = db.collection("maintenance").doc("eventNotifications")
    .collection("sent").doc(eventKey);
  try {
    await ref.create({ at: FieldValue.serverTimestamp() });
    return true;
  } catch {
    logger.info("[event-push] повтор доставки, пропущено", { eventKey });
    return false;
  }
}

/**
 * Firestore-`Timestamp` → миллисекунды, `null` для всего остального.
 *
 * Проверка по наличию метода, а не `instanceof`: сюда приходят и
 * серверные `Timestamp`, и — на непрогретых полях старых записей —
 * `null`/`undefined`, и в тестах простые объекты.
 */
function tsMillis(v: unknown): number | null {
  if (v && typeof (v as { toMillis?: unknown }).toMillis === "function") {
    return (v as { toMillis: () => number }).toMillis();
  }
  return null;
}

function toEventSnapshot(d: Record<string, unknown>): EventSnapshot {
  return {
    ownerUid: (d.ownerUid as string) ?? "",
    date: (d.date as string) ?? "",
    type: (d.type as string) ?? "",
    location: (d.location as string) ?? "",
    notes: (d.notes as string) ?? "",
    musicians: Array.isArray(d.musicians) ? (d.musicians as string[]) : [],
    cancelRequestedBy: (d.cancelRequestedBy as string) ?? null,
    // Timestamp → миллисекунды здесь, а не в eventNotifications: тот
    // модуль намеренно не знает про Firestore и потому проверяется
    // обычным тестом, без эмулятора.
    cancelRequestedAtMs: tsMillis(d.cancelRequestedAt),
    cancelConfirmedBy: (d.cancelConfirmedBy as string) ?? null,
    status: (d.status as string) ?? "agreed",
    replacedEventId: (d.replacedEventId as string) ?? null,
    lastActionBy: (d.lastActionBy as string) ?? null,
    lastActionType: (d.lastActionType as EventSnapshot["lastActionType"]) ?? null,
    // `?? null` здесь НЕЛЬЗЯ, и это не придирка: `undefined` (поля нет) и
    // `{}` (пустая карта) обязаны дойти разными, иначе теряется единственный
    // признак, по которому норма отличается от поломки (I47). Приводить
    // отсутствие к `null` тоже незачем — `remindableOf` проверяет
    // истинность, а не тип.
    answers: (d.answers as Record<string, string> | undefined),
  };
}

async function displayName(uid: string): Promise<string> {
  if (!uid) return "İstifadəçi";
  const snap = await db.collection("users").doc(uid).get();
  return (snap.data()?.name as string) ??
    (snap.data()?.displayName as string) ?? "İstifadəçi";
}

// СНЯТЬ ОТМЕТКУ «ПРОЧИТАНО» У ВСЕХ, КРОМЕ АВТОРА ПРАВКИ.
//
// Заведено вместе с N40. Пока «Əvəz et» делала удаление с созданием, у
// изменённого мероприятия появлялся НОВЫЙ id — и карточка у второй стороны
// снова выглядела непрочитанной сама собой. Признак работал случайно, как
// побочное следствие поломки. Правка на месте сохраняет id (в том и смысл),
// а `readAgreementIds` — массив id, дописываемый `arrayUnion` при открытии
// карточки и не снимаемый никогда, — значит золотая рамка «непрочитано»
// перестала бы возвращаться вовсе.
//
// Потерю канала создаёт сам этот шаг, поэтому и закрывает её он же. На iOS
// это единственный оставшийся признак: живых push-токенов там нет ни
// одного (N20), и без рамки вторая сторона не узнала бы о правке ничем.
//
// СЕРВЕРОМ, А НЕ КЛИЕНТОМ, по принуждению: `readAgreementIds` лежит на
// документе пользователя, и правила дают писать туда только ему самому.
// Снять отметку второй стороне клиент не может в принципе.
//
// `arrayRemove` идемпотентен, поэтому повтор при ретрае безвреден — и по
// той же причине вызов стоит ДО `claimNotificationOnce`: тот бережёт от
// двойного push'а, а не от двойного снятия, и запирать за ним снятие
// значило бы терять его на повторном заходе функции.
//
// Ошибка по одному человеку не должна ронять остальных и тем более
// уведомления — та же развязка, что в `sendEventPushes` ниже.
async function clearReadMark(eventId: string, uids: string[]): Promise<void> {
  await Promise.all(uids.map(async (uid) => {
    try {
      // `set` с `merge`, а не `update`: `update` падает на несуществующем
      // документе, а отсутствие документа пользователя — не повод уронить
      // рассылку соседям.
      await db.collection("users").doc(uid).set(
        { readAgreementIds: FieldValue.arrayRemove(eventId) },
        { merge: true },
      );
    } catch (e) {
      logger.warn("[event-push] отметку прочтения снять не удалось",
        { uid, eventId, e });
    }
  }));
}

// ПОДАВЛЕНИЕ ПРИСУТСТВИЕМ. Тот же механизм, что в чате: отметка активного
// экрана плюс окно свежести (presence.ts). Поле своё — `activeEventId`, —
// потому что вопрос другой: «смотрит в эту карточку», а не «смотрит в этот
// чат». Одно поле на два вопроса это устройство N19/N21/N22.
//
// При любой неопределённости решаем СЛАТЬ: лишний push заметен и поправим,
// потерянный не заметен никем.
async function sendEventPushes(pushes: EventPush[]): Promise<void> {
  const nowMs = Date.now();
  await Promise.all(pushes.map(async (p) => {
    try {
      const userSnap = await db.collection("users").doc(p.uid).get();
      const userData = userSnap.data();
      const lastSeen = userData?.lastSeen;
      const lastSeenMs =
        lastSeen && typeof lastSeen.toMillis === "function"
          ? lastSeen.toMillis()
          : null;
      const watching = isWatchingEventDecision({
        userData,
        eventId: p.data.eventId,
        uid: p.uid,
        lastSeenMs,
        nowMs,
      });
      if (watching) {
        logger.info("[event-push] смотрит карточку, молчим", {
          uid: p.uid, eventId: p.data.eventId, type: p.data.type,
        });
        return;
      }
      logger.info("[event-push] шлём", {
        uid: p.uid, type: p.data.type, title: p.title,
      });
      await sendPushToUid(p.uid, p.title, p.body, p.data);
    } catch (e) {
      logger.warn("[event-push] отправка не удалась", { uid: p.uid, e });
    }
  }));
}

export const onPersonalEventCreated = onDocumentCreated(
  "personalEvents/{eventId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    if (!(await claimNotificationOnce(event.id))) return;
    const after = toEventSnapshot(snap.data());
    // Договор из согласованного предложения — молчим. Обе стороны уже
    // узнали: обе видят поздравительное окно, инициатор получает
    // «İş təklifi qəbul edildi». Уведомление «вас добавили» пришло бы
    // получателю сразу после его же нажатия «Razıyam».
    if (after.lastActionType === "agreed") return;
    const actor = after.lastActionBy ?? after.ownerUid;
    const actorName = await displayName(actor);

    // ЗАМЕНА — одно уведомление вместо двух. Новое мероприятие несёт
    // `replacedEventId`, по нему и опознаётся пара «удалили старое,
    // создали новое». Без него участник получил бы подряд «silindi» и
    // «əlavə olundunuz» об одном действии, причём первое пугает зря.
    const pushes = after.replacedEventId
      ? recipientsOf(after, actor).map((uid) =>
          pushReplaced(uid, event.params.eventId, actorName, after))
      : recipientsOf(after, actor).map((uid) =>
          pushAdded(uid, event.params.eventId, actorName, after));
    await sendEventPushes(pushes);
  },
);

export const onPersonalEventUpdated = onDocumentUpdated(
  "personalEvents/{eventId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    const b = toEventSnapshot(before);
    const a = toEventSnapshot(after);
    const actor = a.lastActionBy ?? a.ownerUid;
    const actorName = await displayName(actor);
    const pushes = planUpdatePushes({
      eventId: event.params.eventId,
      before: b,
      after: a,
      actorName,
    });
    if (pushes.length === 0) return;
    // Отметка снимается ШИРЕ, чем уходит push: получатели рассылки бывают
    // адресными (подтверждение отмены идёт только просившему), а «запись
    // изменилась, посмотрите» касается всех, кого мероприятие держит. Та
    // же несимметричная цена, что у самих уведомлений: лишняя золотая
    // рамка заметна и снимается открытием карточки, снятая зря — нет.
    await clearReadMark(event.params.eventId, recipientsOf(a, actor));
    if (!(await claimNotificationOnce(event.id))) return;
    await sendEventPushes(pushes);
  },
);

// ДОГОВОР ПОД ВОПРОСОМ — отдельный триггер, а не ветка в предыдущем.
//
// Причина не в опрятности: тот выходит на `pushes.length === 0` РАНЬШЕ
// записи, и «ушёл участник, уведомлять некого» (например, ушёл сам
// владелец) не должно означать «состояние не менять».
//
// Пишет только сервер. Клиенту это состояние писать нечем и незачем:
// правила его не пропускают, а `restoresEvent()` открывает только обратную
// дорогу — из «под вопросом» в силу (Часть 6а `docs/plan.md`).
export const markEventUnsettled = onDocumentUpdated(
  "personalEvents/{eventId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    const patch = unsettledAfterMemberLeft(
      toEventSnapshot(before),
      toEventSnapshot(after),
    );
    if (!patch) return;
    logger.info(
      `[unsettled] ${event.params.eventId} → ${patch.status} (${patch.lastActionType})`,
    );
    await db.collection("personalEvents").doc(event.params.eventId).update(patch);

    // УВЕДОМЛЕНИЕ О САМОМ ПЕРЕХОДЕ, и шлётся оно ЗДЕСЬ, а не общим
    // разбором. Причина: `diffEvents` не сравнивает `status`, а
    // `planUpdatePushes` ветвится по `lastActionType`, где повода
    // `memberLeft` нет вовсе. То есть наша же запись прошла бы молча, и
    // вторая сторона узнавала бы о вопросе, только открыв карточку.
    //
    // Ушедшему не шлём: `recipientsOf` снимает автора, а автор здесь —
    // тот, кто вышел. Он и так знает, что вышел.
    const a = toEventSnapshot({ ...after, ...patch });
    const actor = a.lastActionBy ?? null;
    if (!(await claimNotificationOnce(`unsettled_${event.id}`))) return;
    await sendEventPushes(
      recipientsOf(a, actor).map((uid) =>
        pushUnsettled(uid, event.params.eventId, a),
      ),
    );
  },
);

export const onPersonalEventDeleted = onDocumentDeleted(
  "personalEvents/{eventId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const gone = toEventSnapshot(snap.data());
    // Удалять может только владелец (firestore.rules), поэтому автор
    // выводится, а не берётся из `lastActionBy`: удаление документа не
    // оставляет места, куда его записать.
    const actor = gone.ownerUid;
    const recipients = recipientsOf(gone, actor);
    if (recipients.length === 0) return;

    // ЗАМЕНА: если старое мероприятие снесли ради нового, «silindi» слать
    // не надо — про замену скажет onPersonalEventCreated одним точным
    // уведомлением. Ждать создание нечем, поэтому смотрим, не появилось
    // ли уже мероприятие, ссылающееся на это.
    const replacement = await db.collection("personalEvents")
      .where("replacedEventId", "==", event.params.eventId).limit(1).get();
    if (!replacement.empty) {
      logger.info("[event-push] удаление ради замены, молчим", {
        eventId: event.params.eventId,
      });
      return;
    }
    if (!(await claimNotificationOnce(event.id))) return;
    const actorName = await displayName(actor);
    await sendEventPushes(recipients.map((uid) =>
      pushDeleted(uid, event.params.eventId, actorName, gone)));
  },
);

// НАПОМИНАНИЯ. Раз в час, потому что сроков два — за сутки и за три часа, —
// а суточный прогон не может попасть в трёхчасовое окно.
//
// Расписание в Asia/Baku, и это не косметика: `date` мероприятия — это
// «плавающее гражданское время» (N4), 17:30 там, где мероприятие идёт.
// Считать окна по UTC значило бы сдвинуть все напоминания на четыре часа.
//
// Отметка об отправке кладётся в отдельную коллекцию, а НЕ в документ
// мероприятия: запись в него подняла бы onPersonalEventUpdated и породила
// уведомление «tədbir dəyişdi» о собственном напоминании.
// ПОРОГ, А НЕ ПОЛОСА. Прежняя редакция брала ровно часовую полосу на 24 и
// на 3 часа вперёд, и полосы стыковались встык. Это давало три молчаливых
// потери, разобранные 03.08:
//
//   1. пропущенный прогон (сбой, деплой, задержка GCP — случилось в тот
//      же день) оставлял в покрытии часовую дыру, и всё, что в неё попало,
//      не получало напоминания вовсе;
//   2. дрейф расписания создавал щели между полосами: прогон в 13:02
//      закрывал [16:02,17:02), следующий в 14:05 — [17:05,18:05);
//   3. догона не было ни для чего.
//
// Теперь берётся ВСЁ впереди в пределах порога, а «ровно один раз»
// обеспечивает отметка. Пропущенный прогон догоняется следующим, дрейф
// расписания перестаёт значить что-либо, а дубль невозможен по устройству
// отметки (create() плюс maxInstances: 1).
// Состояние «под вопросом» — то же значение, что в правилах и в клиенте.
// Три места, один смысл; сверять их нечем, кроме этой строки и текста
// рядом с ней (языки разные).
const kStatusUnsettled = "unsettled";

const REMINDER_WINDOWS: { kind: ReminderKind; aheadMs: number }[] = [
  { kind: "24h", aheadMs: 24 * 60 * 60 * 1000 },
  { kind: "3h", aheadMs: 3 * 60 * 60 * 1000 },
];

export const remindUpcomingEventsHourly = onSchedule(
  {
    // Регион тот же, что у всего остального: Firestore лежит в Европе, и
    // почасовой обход из us-central1 платил бы за каждый запрос
    // трансатлантической задержкой. При первом деплое регион не был
    // указан, функция уехала в us-central1 — поймано проверкой по gcloud.
    region: FUNCTIONS_REGION,
    schedule: "every 1 hours",
    timeZone: "Asia/Baku",
    maxInstances: 1,
    retryCount: 0,
  },
  async () => {
    // «Сейчас» по бакинским стенным часам — в той же шкале, в какой
    // записаны сами мероприятия (N4: date это не момент на оси, а запись
    // в календаре).
    const nowMs = Date.now();
    const nowWall = new Date(nowMs + BAKU_OFFSET_MS)
      .toISOString().slice(0, 19);
    const maxAhead = Math.max(...REMINDER_WINDOWS.map((w) => w.aheadMs));
    // Окно запроса расширено на бакинское смещение: в проде date лежит в
    // трёх формах (N26), и старая UTC-запись отличается от стенных часов
    // ровно на него. Запрос сравнивает СТРОКИ и о формах не знает.
    const wideTo = new Date(nowMs + maxAhead + 2 * BAKU_OFFSET_MS)
      .toISOString().slice(0, 19);
    const wideFrom = new Date(nowMs - BAKU_OFFSET_MS)
      .toISOString().slice(0, 19);

    const upcoming = await db.collection("personalEvents")
      .where("date", ">=", wideFrom)
      .where("date", "<", wideTo)
      .get();

    for (const doc of upcoming.docs) {
      const e = toEventSnapshot(doc.data());
      // Отменённое время не занимает и напоминания не заслуживает.
      if (e.status === "cancelled") continue;

      const wall = eventWallClock(e.date);
      const wallMs = Date.parse(`${wall}Z`) - BAKU_OFFSET_MS;
      if (Number.isNaN(wallMs)) continue;
      // Уже началось — молчим. Порог открыт только вперёд: напоминание о
      // прошедшем хуже отсутствия напоминания.
      if (wallMs <= nowMs) continue;

      const createdAt = doc.data().createdAt;
      const createdAtMs =
        createdAt && typeof createdAt.toMillis === "function"
          ? createdAt.toMillis()
          : null;

      // ВЕЧЕР ПОД ВОПРОСОМ НАПОМИНАЕТ О СЕБЕ ИНАЧЕ — и вместо обычного,
      // а не вместе с ним. Пока вопрос не решён, «завтра у вас
      // мероприятие» — сведение неполное: может и не быть.
      //
      // Окно одно, суточное. Трёхчасового здесь нет намеренно: за три
      // часа решать «играю или нет» поздно, и сообщение стало бы шумом,
      // который ничего не меняет.
      if (e.status === kStatusUnsettled) {
        const w = REMINDER_WINDOWS.find((x) => x.kind === "24h");
        if (!w) continue;
        if (wallMs - nowMs > w.aheadMs) continue;
        if (!shouldCatchUp(wallMs, w.aheadMs, createdAtMs)) continue;
        // Ключ СВОЙ: иначе это напоминание заняло бы ключ обычного, и
        // после возвращения договора в силу человек не услышал бы о самом
        // вечере вовсе.
        const key = reminderKey(doc.id, "unsettled24h", wall);
        if (!(await claimNotificationOnce(key))) continue;
        await sendEventPushes(recipientsOf(e, null).map((uid) =>
          pushUnsettledReminder(uid, doc.id, e)));
        continue;
      }

      for (const w of REMINDER_WINDOWS) {
        if (wallMs - nowMs > w.aheadMs) continue;
        // Окно, которого не было: мероприятие создали позже, чем оно
        // прошло. Догон существует ради пропущенных прогонов, а не ради
        // окон, которых не существовало.
        if (!shouldCatchUp(wallMs, w.aheadMs, createdAtMs)) continue;

        const key = reminderKey(doc.id, w.kind, wall);
        if (!(await claimNotificationOnce(key))) continue;

        const hoursLeft = (wallMs - nowMs) / (60 * 60 * 1000);
        // Напоминание идёт ВСЕМ, включая владельца: это не уведомление о
        // чужом действии, а сообщение о времени, и владелец забывает так
        // же, как остальные.
        //
        // ЕДИНСТВЕННОЕ ИСКЛЮЧЕНИЕ — сказавший «не может» (шаг 3,
        // docs/plan.md): напоминание про вечер, на который человек не идёт,
        // никакого решения не поддерживает. Изменения при этом идут ему
        // по-прежнему — `recipientsOf` не тронут, — потому что «не может»
        // сказано про сегодняшние условия, и, поехав дата, он вправе
        // передумать. Фильтр стоит в одном месте: `remindableOf`.
        await sendEventPushes(remindableOf(e).map((uid) =>
          pushReminder(uid, doc.id, e, w.kind, hoursLeft)));
      }
    }
  },
);

// Уведомления по раунду «İş təklif et» — второй стороне (пункт 5 плана).
//
// ОТДЕЛЬНАЯ функция, а не ветка в onChatUpdated, и это то же решение, что
// принято в A3 при отказе сливать функции: изоляция важнее экономии
// вызовов. Исключение в пути уведомлений не должно ронять создание
// договора — а оно живёт в onChatUpdated и является несущим.
//
// Цена изоляции посчитана там же: ~340 обновлений документа чата в сутки,
// то есть плюс столько же вызовов при бесплатном лимите 2 млн в месяц.
export const onJobOfferRoundChanged = onDocumentUpdated(
  { document: "chats/{chatId}", region: FUNCTIONS_REGION },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    const members: string[] = Array.isArray(after.members)
      ? (after.members as string[])
      : [];
    if (members.length === 0) return;

    const args = {
      chatId: event.params.chatId,
      before: before as never,
      after: after as never,
      members,
    };
    // Сначала ДЁШЕВО выясняем, есть ли что слать: имя автора требует
    // чтения документа пользователя, а этот триггер поднимается на каждое
    // обновление горячего документа чата (A3, ~340 в сутки). Имя
    // подставляется вторым проходом — тексты собираются уже с ним.
    if (planOfferPushes({ ...args, actorName: "" }).length === 0) return;
    if (!(await claimNotificationOnce(event.id))) return;

    const actor =
      (after.cancelledBy as string) ??
      (after.jobOfferBy as string) ??
      (before.jobOfferBy as string) ?? "";
    const actorName = await displayName(actor);
    const pushes = planOfferPushes({ ...args, actorName });

    const nowMs = Date.now();
    await Promise.all(pushes.map(async (p) => {
      try {
        const userSnap = await db.collection("users").doc(p.uid).get();
        const userData = userSnap.data();
        const lastSeen = userData?.lastSeen;
        const lastSeenMs =
          lastSeen && typeof lastSeen.toMillis === "function"
            ? lastSeen.toMillis() : null;
        // Подавление РОДНЫМ признаком чата: здесь вопрос «смотрит ли он в
        // этот чат», и на него отвечает activeChatId — тот самый механизм,
        // что глушит push о новом сообщении. Второго заводить незачем.
        const watching = isWatchingChatDecision({
          userData,
          chatId: event.params.chatId,
          activeUsers: Array.isArray(after.activeUsers)
            ? (after.activeUsers as string[]) : [],
          uid: p.uid,
          lastSeenMs,
          nowMs,
        });
        if (watching) {
          logger.info("[offer-push] смотрит чат, молчим",
            { uid: p.uid, type: p.data.type });
          return;
        }
        logger.info("[offer-push] шлём", { uid: p.uid, type: p.data.type });
        await sendPushToUid(p.uid, p.title, p.body, p.data);
      } catch (e) {
        logger.warn("[offer-push] отправка не удалась", { uid: p.uid, e });
      }
    }));
  },
);
