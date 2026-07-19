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

// Fans a push out to every device a single user has registered, reusing
// the same expo/fcm split onNewMessage does inline below — extracted here
// (rather than inlined a third time) only because the two friendRequests
// triggers below both need the exact same "fetch pushTokens, dispatch by
// token type" step onNewMessage already performs; onNewMessage itself is
// left untouched to avoid risking its own working behavior.
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
      if (isExpoToken(token)) {
        await sendExpoPush(token, title, body, data);
      } else {
        await sendFcmPush(token, title, body, data);
      }
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

    // unreadCount is a per-user map ({uid: count}, same shape mugam-v2's own
    // sendMessage already writes — see mugam-v2/src/firebase/firestore.ts)
    // reset to 0 for a uid by markChatAsReadBy (firestore_service.dart) when
    // that user opens the chat. Incremented for every member except the
    // sender, deliberately including anyone in activeUsers (unlike the push
    // recipients filter below) — activeUsers only means "has this chat
    // screen open right now", not "has already read this exact message";
    // mirrors mugam-v2's own unconditional increment.
    if (members.length > 1) {
      try {
        const unreadUpdate: Record<string, FirebaseFirestore.FieldValue> = {};
        for (const uid of members) {
          if (uid !== senderId) {
            unreadUpdate[`unreadCount.${uid}`] = FieldValue.increment(1);
          }
        }
        await db.collection("chats").doc(chatId).update(unreadUpdate);
      } catch (e) {
        logger.warn("onNewMessage: unreadCount increment failed", e);
      }
    }

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
