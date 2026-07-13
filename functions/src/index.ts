import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { getStorage } from "firebase-admin/storage";
import { onDocumentCreated, onDocumentDeleted, onDocumentUpdated } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onObjectFinalized } from "firebase-functions/v2/storage";
import { logger } from "firebase-functions";

initializeApp();
const db = getFirestore();
const messaging = getMessaging();
const FUNCTIONS_REGION = "europe-west3";

const EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send";

// mugam-v2 (Expo/React Native) registers Expo push tokens and sends them
// itself client-side whenever *it* is the sender. This function only needs
// to cover the gap that leaves: (a) mugam-flutter recipients (always, since
// nothing else can reach an FCM token), and (b) Expo-token recipients when
// the sender used mugam-flutter (since in that case mugam-v2's own
// client-side send never runs). Sending to an Expo-token recipient when a
// mugam-v2 client sent the message would duplicate what that client already
// did — mugam-v2 is a read-only reference and can't be changed to avoid this
// itself, so the dedup logic lives entirely here.
function isExpoToken(token: string): boolean {
  return token.startsWith("ExponentPushToken[") || token.startsWith("ExpoPushToken[");
}

async function sendExpoPush(
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
): Promise<void> {
  try {
    await fetch(EXPO_PUSH_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ to: token, title, body, data, sound: "default" }),
    });
  } catch (e) {
    logger.warn("Expo push failed", e);
  }
}

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

    // messageCount tracks how many messages currently exist in this chat
    // (not lifetime-ever-sent) — incremented here and decremented by the
    // symmetric onMessageDeleted trigger below. This is the source of
    // truth for a future "frequently contacted" ranking in the forward-
    // message picker, deliberately server-owned (unlike mediaImageCount,
    // which every client send/delete call site increments/decrements
    // itself) so it stays correct regardless of which code path creates
    // or deletes a message, including future ones (e.g. forwarding)
    // without needing every call site updated individually. Independent
    // of the push-notification logic below — must not block/fail pushes,
    // so it's caught and logged rather than thrown.
    try {
      await db.collection("chats").doc(chatId).update({
        messageCount: FieldValue.increment(1),
      });
    } catch (e) {
      logger.warn("onNewMessage: messageCount increment failed", e);
    }

    const members: string[] = chat.members ?? [];
    const activeUsers: string[] = chat.activeUsers ?? [];
    const recipients = members.filter(
      (uid) => uid !== senderId && !activeUsers.includes(uid),
    );
    if (recipients.length === 0) return;

    const senderIsFlutter = message.clientPlatform === "flutter";
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
            if (isExpoToken(token)) {
              if (senderIsFlutter) await sendExpoPush(token, title, body, data);
            } else {
              await sendFcmPush(token, title, body, data);
            }
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
// users/{uid}/contacts/{otherUid} denormalization
// ---------------------------------------------------------------------
// Document existence = "these two users currently share at least one
// chat." Never written by the client (no `allow write` for this
// collection in firestore.rules at all — see that file) — maintained
// exclusively by the three triggers below, on chats/{chatId} create/
// update/delete. This is the real, stored signal the Status feature's
// `contacts` privacy mode checks via isContact(), rather than
// recomputing shared-chat membership on every single status read.
// Returns true if this pair was NOT already contacts before this call (a
// genuine gain, not a redundant re-write of an existing pair) — callers use
// this to decide whether to propagate into any active status's
// visibleToUids (see propagateContactChange below). Checked via a read
// before the write because .set(..., {merge:true}) can't itself distinguish
// "created" from "already existed" the way a plain .create() would.
async function upsertContactPair(a: string, b: string): Promise<boolean> {
  const refA = db.collection("users").doc(a).collection("contacts").doc(b);
  const existedBefore = (await refA.get()).exists;
  const since = FieldValue.serverTimestamp();
  await Promise.all([
    refA.set({ since }, { merge: true }),
    db.collection("users").doc(b).collection("contacts").doc(a).set({ since }, { merge: true }),
  ]);
  return !existedBefore;
}

// SCALE NOTE (leave as code comment, not a bug): this recompute runs only
// on membership-change events, not per status read — acceptable at
// current scale. If a user's total chat count grows very large this
// in-memory filter degrades and should be revisited with better indexing
// at that point.
async function sharesAnyChat(uidX: string, uidY: string): Promise<boolean> {
  const snap = await db.collection("chats").where("members", "array-contains", uidX).get();
  return snap.docs.some((doc) => {
    const members: string[] = doc.data().members ?? [];
    return members.includes(uidY);
  });
}

// Returns true if the pair WAS contacts before this call and this call
// actually deleted it (a genuine loss) — false both when there was never a
// pair and when a surviving shared chat kept it intact. Same rationale as
// upsertContactPair's return value above: callers need to know whether a
// real transition happened before they touch any status's visibleToUids.
async function removeContactPairIfNoSharedChat(uidX: string, uidY: string): Promise<boolean> {
  if (await sharesAnyChat(uidX, uidY)) return false;
  const refX = db.collection("users").doc(uidX).collection("contacts").doc(uidY);
  const existedBefore = (await refX.get()).exists;
  if (!existedBefore) return false;
  await Promise.all([
    refX.delete(),
    db.collection("users").doc(uidY).collection("contacts").doc(uidX).delete(),
  ]);
  return true;
}

// ---------------------------------------------------------------------
// users/{uid}/statuses/{statusId}.visibleToUids — denormalized audience
// ---------------------------------------------------------------------
// visibleToUids is the exact, server-computed set of uids allowed to read a
// status (see lib/firebase/models.dart's Status.visibleToUids comment for
// the full rationale — firestore.rules needs a real field to filter list/
// collectionGroup queries against, since exists()-based checks can't
// support those). This block keeps it correct in both directions: computed
// once at creation (onStatusCreated below) and kept in sync afterward as
// the owner's contacts change (propagateContactChange, called from
// onChatUpdated/onChatDeleted's own contact-pair add/remove logic above).

// SCALE NOTE (leave as code comment, not a bug): bounded by how many
// currently active (non-expired) statuses a single user can have at once,
// which is naturally small (a person posts at most a handful of statuses
// per day) — not a scale risk like the sharesAnyChat() chat-count one
// flagged above.
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
      // newly-gained contact — never add someone the owner explicitly
      // excluded, even though they now share a chat.
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

// Symmetric: a contact-relationship change between a and b can affect BOTH
// a's own active statuses (regarding b) and b's own active statuses
// (regarding a) independently.
async function propagateContactChange(a: string, b: string, gained: boolean): Promise<void> {
  await Promise.all([
    updateVisibleToUidsForOwner(a, b, gained),
    updateVisibleToUidsForOwner(b, a, gained),
  ]);
}

export const onChatCreated = onDocumentCreated("chats/{chatId}", async (event) => {
  const snap = event.data;
  if (!snap) return;
  const members: string[] = snap.data().members ?? [];

  // Mirrors onChatUpdated's "added" branch below: a brand-new chat can
  // make two users contacts for the very first time, and if either
  // already has an active 'contacts'/'contactsExcept' status, the newly-
  // gained contact must be added to its visibleToUids immediately — not
  // only after some later membership-change event propagates it.
  const tasks: Promise<unknown>[] = [];
  for (let i = 0; i < members.length; i++) {
    for (let j = i + 1; j < members.length; j++) {
      tasks.push(
        (async () => {
          const gained = await upsertContactPair(members[i], members[j]);
          if (gained) await propagateContactChange(members[i], members[j], true);
        })(),
      );
    }
  }
  await Promise.all(tasks);
});

export const onChatUpdated = onDocumentUpdated("chats/{chatId}", async (event) => {
  const beforeMembers: string[] = event.data?.before.data().members ?? [];
  const afterMembers: string[] = event.data?.after.data().members ?? [];
  const added = afterMembers.filter((uid) => !beforeMembers.includes(uid));
  const removed = beforeMembers.filter((uid) => !afterMembers.includes(uid));

  const tasks: Promise<unknown>[] = [];
  for (const uid of added) {
    for (const other of afterMembers) {
      if (other === uid) continue;
      tasks.push(
        (async () => {
          const gained = await upsertContactPair(uid, other);
          if (gained) await propagateContactChange(uid, other, true);
        })(),
      );
    }
  }
  for (const uid of removed) {
    for (const other of afterMembers) {
      tasks.push(
        (async () => {
          const lost = await removeContactPairIfNoSharedChat(uid, other);
          if (lost) await propagateContactChange(uid, other, false);
        })(),
      );
    }
  }
  await Promise.all(tasks);
});

export const onChatDeleted = onDocumentDeleted("chats/{chatId}", async (event) => {
  const snap = event.data;
  if (!snap) return;
  const members: string[] = snap.data().members ?? [];
  const tasks: Promise<unknown>[] = [];
  for (let i = 0; i < members.length; i++) {
    for (let j = i + 1; j < members.length; j++) {
      tasks.push(
        (async () => {
          const lost = await removeContactPairIfNoSharedChat(members[i], members[j]);
          if (lost) await propagateContactChange(members[i], members[j], false);
        })(),
      );
    }
  }
  await Promise.all(tasks);
});

// Computes visibleToUids once at creation time, from the owner's contacts
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
      const contactsSnap = await db.collection("users").doc(ownerUid).collection("contacts").get();
      const contactUids = contactsSnap.docs.map((doc) => doc.id);
      visibleToUids =
        privacyMode === "contactsExcept"
          ? [ownerUid, ...contactUids.filter((uid) => !privacyList.includes(uid))]
          : [ownerUid, ...contactUids];
    }

    try {
      await snap.ref.update({ visibleToUids });
    } catch (e) {
      // The status can be deleted (e.g. the user immediately deletes what
      // they just posted) before this trigger finishes its async contacts
      // read — same class of benign race as onNewMessage/onMessageDeleted's
      // messageCount counters above. Nothing to reconcile: a deleted
      // status has no visibility left to compute.
      logger.warn("onStatusCreated: update failed (status likely deleted already)", e);
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
    const status = snap.data();

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
