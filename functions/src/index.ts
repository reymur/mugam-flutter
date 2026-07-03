import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { logger } from "firebase-functions";

initializeApp();
const db = getFirestore();
const messaging = getMessaging();

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
