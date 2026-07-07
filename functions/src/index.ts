import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
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

function previewText(type: string, text: string): string {
  switch (type) {
    case "image":
      return "🖼 Şəkil";
    case "audio":
      return "🎤 Səs mesajı";
    case "video":
      return "🎥 Video";
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
    const body = `${senderName}: ${previewText(message.type, message.text)}`;
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
