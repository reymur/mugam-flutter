// Разовая уборка испорченных документов push-токенов (N20).
//
// Что чинилось в коде: id документа брался от сборки ОС Android
// (`androidInfo.id`), поэтому РАЗНЫЕ устройства писали в одну запись, а
// ОДНО устройство после обновления прошивки заводило новую и бросало
// старую. Плюс `unregisterToken` не вызывался при выходе из аккаунта.
// Итог в проде 02.08: 9 документов, 5 различных токенов, три токена
// лежали под несколькими пользователями сразу — push, адресованный
// одному, уходил туда, где сидит другой, вместе с именем отправителя и
// началом сообщения.
//
// Правило уборки ровно одно и оно проверяемое: **удаляется документ,
// чей токен FCM считает несуществующим**. Живой токен не удаляется
// никогда, даже если он делится между аккаунтами — там, где он живой,
// решение о том, кому он принадлежит, за нами не стоит: устройство само
// перезапишет свою запись при следующем входе уже новым id.
//
// Живость выясняется отправкой ВХОЛОСТУЮ (dryRun): FCM проверяет токен,
// но не доставляет ничего — ни одного уведомления ни на один телефон.
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/cleanupPushTokens.js          # только показать
//     node lib/scripts/cleanupPushTokens.js --delete # удалить
//
// Без --delete не пишет ничего.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";

const PROJECT_ID = "mugam-club";

// Те же два кода, что и у сторожа в index.ts: «получателя больше нет».
// invalid-argument намеренно не в списке — он приходит и на испорченную
// полезную нагрузку, и удаление по нему стирало бы живые токены из-за
// нашей же ошибки.
const DEAD_CODES = [
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
];

interface Row {
  uid: string;
  name: string;
  deviceId: string;
  token: string;
  updatedAt: string;
}

async function main(): Promise<void> {
  const doDelete = process.argv.includes("--delete");
  initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
  const db = getFirestore();
  const messaging = getMessaging();

  const rows: Row[] = [];
  const users = await db.collection("users").get();
  for (const u of users.docs) {
    const tokens = await u.ref.collection("pushTokens").get();
    for (const d of tokens.docs) {
      const data = d.data();
      if (typeof data.token !== "string") continue;
      rows.push({
        uid: u.id,
        name: (u.data().name as string) ?? "?",
        deviceId: d.id,
        token: data.token,
        updatedAt: (data.updatedAt as string) ?? "—",
      });
    }
  }

  const byToken = new Map<string, Row[]>();
  for (const r of rows) {
    const list = byToken.get(r.token) ?? [];
    list.push(r);
    byToken.set(r.token, list);
  }

  console.log(
    `Документов: ${rows.length}, различных токенов: ${byToken.size}, режим: ${
      doDelete ? "УДАЛЕНИЕ" : "только показать"
    }\n`,
  );

  const doomed: Row[] = [];
  for (const [token, holders] of byToken) {
    let dead = false;
    let code = "";
    try {
      await messaging.send({ token, notification: { title: "x", body: "x" } }, true);
    } catch (e) {
      code =
        (e as { errorInfo?: { code?: string } }).errorInfo?.code ??
        (e as { code?: string }).code ??
        "?";
      dead = DEAD_CODES.includes(code);
    }
    const shared = holders.length > 1 ? `  ⚠ у ${holders.length} пользователей` : "";
    console.log(`${token.slice(0, 22)}…  ${dead ? `МЁРТВЫЙ (${code})` : "ЖИВОЙ"}${shared}`);
    for (const h of holders) {
      console.log(
        `    ${h.uid.slice(0, 7)} ${h.name.padEnd(16)} ${h.deviceId.padEnd(22)} ${h.updatedAt}`,
      );
      if (dead) doomed.push(h);
    }
  }

  console.log(`\nК удалению: ${doomed.length} из ${rows.length}`);
  if (!doDelete) {
    console.log("Ничего не тронуто. Для удаления добавьте --delete.");
    return;
  }
  let removed = 0;
  for (const r of doomed) {
    await db
      .collection("users")
      .doc(r.uid)
      .collection("pushTokens")
      .doc(r.deviceId)
      .delete();
    removed++;
  }
  console.log(`Удалено: ${removed}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
