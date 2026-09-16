import { getAdminApp, db, clearFirestore, waitFor } from "./helpers";

// ХОДЫ ПРЕДЛОЖЕНИЯ, НАСТОЯЩИЙ ПУТЬ (N130, шаг 4).
//
// --- ЗАЧЕМ ЭТОТ ФАЙЛ, ЕСЛИ ЕСТЬ offer-moves.test.ts ---
//
// Тот проверяет ПРАВИЛО — `planOfferMovePushes` с входом, который подаёт
// сам. На один вопрос он ответить не может, и вопрос этот здесь главный:
// **висит ли триггер на том пути.** Ровно на нём и погорела прежняя машина
// уведомлений: `planOfferPushes` написан, покрыт восемнадцатью проверками и
// выложен — а `onJobOfferRoundChanged` слушает документ чата, куда новые
// ходы не пишут вовсе. Правило было верным всё это время; не срабатывало
// ничего.
//
// Здесь пишется НАСТОЯЩИЙ документ в `chats/{chatId}/offers/{offerId}`,
// поднимается настоящий `onOfferMoved`, и смотрим мы на то, что он
// оставляет в базе.
//
// --- ЧЕМ НАБЛЮДАЕМ ---
//
// APNs в эмуляторе нет, текст уведомления не достаётся ничем, и отправка
// заведомо не удаётся — настоящего FCM здесь нет. **Достаётся сам ОТКАЗ
// доставки:** `sendFcmPush` с 30.08 возвращает исход, а `sendPushToUid`
// пишет каждый отказ в `maintenance/pushDelivery/failures` с полем `uid`
// (N186, вторая половина).
//
// То есть наблюдаемое здесь — «сервер дошёл до отправки ИМЕННО ЭТОМУ
// человеку». Это сильнее, чем отметка `claimNotificationOnce`: та привязана
// к записи и молчит о том, КОМУ собирались слать, а разведение адресатов —
// половина смысла всех трёх ветвей.
//
// **Отметка в общей коллекции сюда не годится, и это уже проверено дорого:**
// первая редакция соседнего набора считала записи в
// `maintenance/eventNotifications/sent` и дала 6, 5 и 4 там, где ожидалась
// единица — считались чужие срабатывания, дотекавшие после очистки (I13).
//
// **ЧЕГО ЭТИМ УВИДЕТЬ НЕЛЬЗЯ (I50):** отказ называет адресата и не называет
// ТЕКСТ. Что написано в письме, решает разбор в `offer-moves.test.ts`, где
// виден сам список `OfferPush`.
//
// --- ПОЧЕМУ ОТРИЦАНИЯ НЕ ЖДУТ ПО ЧАСАМ ---
//
// «Подождать и убедиться, что ничего не пришло» зеленеет и когда триггер
// промолчал верно, и когда он не запускался вовсе (I14). Поэтому рядом с
// молчаливым предложением всегда стоит второе, заведомо шумное, и ждём мы
// ЕГО.

beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
  // Свои имена на каждый вердикт — разбор у самих объявлений ниже.
  verdictNo += 1;
  BOSS = `boss-uid-${verdictNo}`;
  PLAYER = `player-uid-${verdictNo}`;
  CHAT = `chat-offer-${verdictNo}`;
});

// СВОИ ИМЕНА НА КАЖДЫЙ ВЕРДИКТ, А НЕ ОБЩИЕ НА ФАЙЛ (16.09).
//
// `attempted(uid)` ищет по ОБЩЕЙ коллекции `maintenance/pushDelivery/
// failures`, а первый вердикт этого файла нарочно доводит `attempted(BOSS)`
// до истины. `clearFirestore` в `beforeEach` документы стирает, но ОЧЕРЕДЬ
// ТРИГГЕРОВ НЕ ОСУШАЕТ: опоздавшая доставка первого вердикта приземляется
// уже после очистки четвёртого и попадает под тот же запрос. С уникальным
// именем на вердикт чужой остаток совпасть не может — по построению, а не
// по везению.
//
// ПРАВКА ОБОСНОВАНА ЧТЕНИЕМ КОДА, А НЕ ВОСПРОИЗВЕДЁННЫМ ОТКАЗОМ. Вердикт
// «та же отметка записана заново» падал 16.09 один раз из восемнадцати
// полных прогонов, но воспроизвести отказ не удалось: десять прогонов
// этого набора в одиночку дали ноль красных — то есть утечка, если она
// есть, приходит НЕ ИЗ ЭТОГО ФАЙЛА. **N77 этой правкой НЕ закрывается.**
let BOSS = "boss-uid";
let PLAYER = "player-uid";
let CHAT = "chat-offer";
let verdictNo = 0;

/** Завести чат и по токену каждой стороне — без токена слать некому. */
async function makeChat(): Promise<void> {
  await db().collection("chats").doc(CHAT).set({
    members: [BOSS, PLAYER],
    isGroup: false,
    activeUsers: [],
  });
  for (const uid of [BOSS, PLAYER]) {
    await db().collection("users").doc(uid).set({ name: uid });
    await db().collection("users").doc(uid)
      .collection("pushTokens").doc("dev1")
      .set({ token: `fake-token-${uid}`, clientPlatform: "flutter" });
  }
}

async function makeOffer(
  over: Record<string, unknown> = {},
): Promise<FirebaseFirestore.DocumentReference> {
  const ref = db().collection("chats").doc(CHAT).collection("offers").doc();
  await ref.set({
    createdBy: BOSS,
    createdAt: "2026-08-30T10:00:00.000",
    anchorMessageId: null,
    dates: ["2026-09-01", "2026-09-02", "2026-09-03"],
    eventType: "Toy",
    details: {},
    answers: {},
    ...over,
  });
  return ref;
}

/** Пытались ли слать ЭТОМУ человеку. */
async function attempted(uid: string): Promise<boolean> {
  const snap = await db().collection("maintenance").doc("pushDelivery")
    .collection("failures").where("uid", "==", uid).get();
  return !snap.empty;
}

test("ответ музыканта доходит до инициатора", async () => {
  await makeChat();
  const ref = await makeOffer();
  await ref.update({ [`answers.${PLAYER}`]: ["2026-09-01"] });

  await waitFor(() => attempted(BOSS));
});

test("принятие доходит до музыканта", async () => {
  await makeChat();
  const ref = await makeOffer({ answers: { [PLAYER]: ["2026-09-01"] } });
  await ref.update({ acceptedBy: BOSS, acceptedAt: "2026-08-30T11:00:00.000" });

  await waitFor(() => attempted(PLAYER));
});

test("отзыв доходит до музыканта", async () => {
  await makeChat();
  const ref = await makeOffer();
  await ref.update({ withdrawnBy: BOSS, withdrawnAt: "2026-08-30T11:00:00.000" });

  await waitFor(() => attempted(PLAYER));
});

// ОТРИЦАНИЕ — И ОНО ЖДЁТ ШУМНОГО СОСЕДА, А НЕ ЧАСОВ.
test("та же отметка записана заново — рассылки НЕТ", async () => {
  await makeChat();
  const quiet = await makeOffer({ answers: { [PLAYER]: ["2026-09-01"] } });
  await quiet.update({ [`answers.${PLAYER}`]: ["2026-09-01"] });

  // Сосед, заведомо шумный, и сделан ПОЗЖЕ молчаливого.
  const loud = await makeOffer();
  await loud.update({ withdrawnBy: BOSS, withdrawnAt: "2026-08-30T12:00:00.000" });

  // Дождались соседа — значит очередь триггера дошла до записи, сделанной
  // после молчаливой. Смотрим на первого: инициатору не писали.
  //
  // ЧЕГО ЭТОТ ВЕРДИКТ НЕ ДОКАЗЫВАЕТ, И ЭТО ДОЛГ N239, А НЕ МЕЛОЧЬ.
  // Он доказывает ПРИХОД СОСЕДА и не доказывает МОЛЧАНИЕ МОЛЧУНА: порядок
  // между разными документами очередью не гарантирован, и под нагрузкой он
  // инвертируется. «Ничего не придёт» — утверждение об отсутствии,
  // растянутое во времени; наблюдением в одну точку оно не устанавливается
  // по определению.
  //
  // ЧТО НУЖНО, ЧТОБЫ ДОКАЗЫВАЛ: отметка «обработчик отработал на ЭТОЙ
  // записи и решил не слать», которую `onOfferMoved` кладёт ВСЕГДА, в том
  // числе при молчании. Тогда ждать надо её по САМОМУ молчуну, и отрицание
  // перестаёт быть отрицанием. Это правка в `functions/src`, а не здесь.
  //
  // Уникальные имена на вердикт (см. объявления вверху файла) убирают
  // ЧУЖОЙ источник — остаток соседнего вердикта; СВОЙ остаётся
  // вероятностным.
  await waitFor(() => attempted(PLAYER));
  expect(await attempted(BOSS)).toBe(false);
});
