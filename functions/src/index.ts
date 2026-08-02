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
import { RtcRole, RtcTokenBuilder } from "agora-token";
import { algoliasearch } from "algoliasearch";
import { randomUUID } from "crypto";
import { ALGOLIA_APP_ID, ALGOLIA_USERS_INDEX, toAlgoliaUserRecord } from "./algoliaShared";

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

async function sendFcmPush(
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
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
  }
}

async function sendCallPushToUid(uid: string, data: Record<string, string>): Promise<void> {
  const tokensSnap = await db.collection("users").doc(uid).collection("pushTokens").get();
  await Promise.all(
    tokensSnap.docs.map(async (tokenDoc) => {
      const token = tokenDoc.data().token as string | undefined;
      if (!token) return;
      await sendCallDataPush(token, data);
    }),
  );
}

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
      await sendFcmPush(token, title, body, data);
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

// How far back to look for the replacement preview when the message the
// chat card currently shows is removed. Matches the client's own former
// _findLastMessage cap: if every one of the 50 newest messages is deleted
// for everyone, the card falls back to empty rather than paying for an
// unbounded scan on every delete.
const PREVIEW_LOOKBACK_LIMIT = 50;

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
  const newestQuery = chatRef
    .collection("messages")
    .orderBy("seq", "desc")
    .limit(PREVIEW_LOOKBACK_LIMIT);
  try {
    await db.runTransaction(async (tx) => {
      const chatSnap = await tx.get(chatRef);
      if (!chatSnap.exists) return;
      const storedSeq: number = chatSnap.data()?.lastMessageSeq ?? 0;
      // Not the message the card is showing — nothing to do.
      if (storedSeq !== removedSeq) return;

      const newest = await tx.get(newestQuery);
      // deletedForAll is filtered here rather than in the query on purpose:
      // messages written before that field existed simply don't have it,
      // and a Firestore equality filter never matches a missing field, so
      // a `where("deletedForAll","==",false)` would skip almost everything.
      const replacement = newest.docs.find(
        (d) => d.data().deletedForAll !== true,
      );
      if (!replacement) {
        tx.update(chatRef, {
          lastMessage: "",
          lastMessageTime: null,
          lastMessageSeq: 0,
          lastMessageDeletedFor: [],
        });
        return;
      }
      const data = replacement.data();
      tx.update(chatRef, {
        lastMessage: previewText(data.type, data.text, data.fileName),
        lastMessageTime: data.timestamp ?? null,
        lastMessageSeq: data.seq ?? 0,
        // Carries over whoever had already hidden the newly-promoted
        // message for themselves, rather than resurrecting it for them.
        lastMessageDeletedFor: data.deletedFor ?? [],
      });
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
          update.lastMessage = previewText(
            message.type,
            message.text,
            message.fileName,
          );
          update.lastMessageTime = message.timestamp ?? null;
          update.lastMessageSeq = thisSeq;
          update.lastMessageDeletedFor = [];
        }
        tx.update(chatRef, update);
      });
    } catch (e) {
      logger.warn("onNewMessage: chat denormalisation failed", e);
    }

    const activeUsers: string[] = chat.activeUsers ?? [];
    const recipients = members.filter(
      (uid) => uid !== senderId && !activeUsers.includes(uid),
    );
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
            await sendFcmPush(token, title, body, data);
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
    const newest = await chatRef
      .collection("messages")
      .orderBy("seq", "desc")
      .limit(PREVIEW_LOOKBACK_LIMIT)
      .get();
    const replacement = newest.docs.find(
      (d) => d.data().deletedForAll !== true,
    );
    const trueSeq: number = replacement?.data().seq ?? 0;
    if (trueSeq === storedSeq) return { updated: false };

    if (!replacement) {
      await chatRef.update({
        lastMessage: "",
        lastMessageTime: null,
        lastMessageSeq: 0,
        lastMessageDeletedFor: [],
      });
      return { updated: true };
    }
    const data = replacement.data();
    await chatRef.update({
      lastMessage: previewText(data.type, data.text, data.fileName),
      lastMessageTime: data.timestamp ?? null,
      lastMessageSeq: trueSeq,
      lastMessageDeletedFor: data.deletedFor ?? [],
    });
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
    const changed = Array.from(
      new Set([...Object.keys(before), ...Object.keys(after)]),
    )
      .filter((k) => canonicalJson(before[k]) !== canonicalJson(after[k]))
      .sort();
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
      isAgree: true,
      agreementChatId: event.params.chatId,
      partnerUid: recipientUid,
      partnerName: recipientName,
      status: "agreed",
      cancelledBy: null,
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
    if (activeUsers.includes(initiatorUid)) return;

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
    const client = algoliasearch(ALGOLIA_APP_ID, algoliaAdminKey.value());
    const after = event.data?.after;

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
