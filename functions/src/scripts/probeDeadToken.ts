// ХВОСТ N186: РАЗБУДИТЬ ОДИН АДРЕС И ПРОЧИТАТЬ ОТВЕТ FCM ЦЕЛИКОМ.
//
// Вопрос, на который отвечает только отправка. Мёртвый адрес Рафаэля от
// 26.08 не удалился, отказов за это время — ноль. Значит либо он ЖИВ, либо
// FCM его принимает, а APNs выбрасывает молча; по данным эти два случая
// неотличимы, потому что глушение и приём выглядят одинаково — тишиной.
// Различает их ровно одна отправка с чтением ответа (I50: где проверки
// нет, так и сказано; здесь проверка есть, и вот она).
//
// РАЗРЕШЕНО ВЛАДЕЛЬЦЕМ 01.09 ЯВНО: телефон его, будить можно.
//
// ЧТО ЭТОТ СКРИПТ ДЕЛАЕТ И ЧЕГО НЕ ДЕЛАЕТ.
//   делает:    одну отправку на ОДИН названный документ токена;
//              печатает ответ целиком — messageId при успехе, code и
//              message при отказе, плюс сырой объект ошибки;
//              спрашивает НАСТОЯЩИЙ разбор (`isDeadTokenError` из
//              pushDelivery.ts), а не свою копию его;
//              перечитывает документ и говорит, на месте ли он.
//   НЕ делает: не удаляет ничего. Удаление в проде живёт в
//              `pruneIfTokenDead` и случится при следующей настоящей
//              отправке; здесь оно было бы вторым необратимым действием в
//              одном шаге, а необратимый шаг обязан нести одну переменную
//              (I48).
//
// Разбор берётся ИМПОРТОМ, а не переписыванием: скопированный разбор мерил
// бы мою выдумку вместо поведения сервера — ровно то, чего боится I13.
//
// --- Как запускать ---
//   gcloud auth application-default login   (один раз)
//   из functions/:
//     npm run build
//     node lib/scripts/probeDeadToken.js <uid> <docId>

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";

import { pushErrorOf, isDeadTokenError, DEAD_TOKEN_CODES } from "../pushDelivery";

const PROJECT_ID = "mugam-club";

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();
const messaging = getMessaging();

async function main(): Promise<void> {
  const [uid, docId] = process.argv.slice(2);
  if (!uid || !docId) {
    console.error("нужны два довода: <uid> <docId>");
    process.exit(2);
  }

  const ref = db.collection("users").doc(uid).collection("pushTokens").doc(docId);
  const before = await ref.get();
  if (!before.exists) {
    console.error(`документа нет: ${ref.path}`);
    process.exit(2);
  }
  const token = before.data()?.token as string | undefined;
  if (!token) {
    console.error(`в документе нет поля token: ${ref.path}`);
    process.exit(2);
  }

  console.log("=== ЧТО ОТПРАВЛЯЕМ ===");
  console.log(`документ:  ${ref.path}`);
  console.log(`обновлён:  ${String(before.data()?.updatedAt?.toDate?.().toISOString() ?? "—")}`);
  console.log(`адрес:     ${token.slice(0, 24)}…${token.slice(-8)} (длина ${token.length})`);
  console.log(`отправлено в ${new Date().toISOString()}\n`);

  // Форма письма та же, что у `sendFcmPush` в index.ts: notification +
  // data + звук в apns. Иначе отказ мог бы прийти на форму, а не на адрес,
  // и мы приняли бы одно за другое.
  try {
    const messageId = await messaging.send({
      token,
      notification: {
        title: "Yoxlama",
        body: "N186 — çatdırılma yoxlanışı",
      },
      data: { type: "probe_n186" },
      apns: { payload: { aps: { sound: "default" } } },
    });
    console.log("=== ОТВЕТ FCM: УСПЕХ ===");
    console.log(`messageId: ${messageId}`);
    console.log("");
    console.log("ЧТО ЭТО ЗНАЧИТ: FCM ПРИНЯЛ письмо. Это НЕ значит, что оно");
    console.log("доставлено — FCM отвечает о приёме, а не о вручении. Если на");
    console.log("трубке ничего не появилось, значит APNs выбросил молча, и");
    console.log("вторая половина N186 видит отказы ТОЛЬКО СВОЕГО СЛОЯ.");
  } catch (e) {
    const { code, message } = pushErrorOf(e);
    const dead = isDeadTokenError(e);
    console.log("=== ОТВЕТ FCM: ОТКАЗ ===");
    console.log(`code:    ${code}`);
    console.log(`message: ${message}`);
    console.log("");
    console.log("--- сырой объект ошибки целиком ---");
    console.dir(e, { depth: null });
    console.log("");
    console.log("=== ЧТО ГОВОРИТ НАШ РАЗБОР (импортирован, не переписан) ===");
    console.log(`isDeadTokenError: ${dead}`);
    console.log(`DEAD_TOKEN_CODES: ${DEAD_TOKEN_CODES.join(", ")}`);
    console.log(`код в списке смертей: ${code ? DEAD_TOKEN_CODES.includes(code) : false}`);
    console.log(
      dead
        ? "СМЕРТЬ ОПОЗНАНА -> в проде `pruneIfTokenDead` удалил бы документ."
        : "СМЕРТЬ НЕ ОПОЗНАНА -> в проде документ остался бы на месте.",
    );
  }

  const after = await ref.get();
  console.log("");
  console.log("=== ДОКУМЕНТ ПОСЛЕ ОТПРАВКИ ===");
  console.log(`существует: ${after.exists}`);
  console.log("Этот скрипт НИЧЕГО НЕ УДАЛЯЛ — см. шапку. Значение выше");
  console.log("отвечает на «жив ли документ», а не на «сработала ли чистка».");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
