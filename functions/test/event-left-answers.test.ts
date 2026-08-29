import * as admin from "firebase-admin";
import { getAdminApp, db, clearFirestore, waitFor } from "./helpers";

// УХОД ПО НОВОЙ СХЕМЕ, НАСТОЯЩИЙ ПУТЬ (N121, шаг 1).
//
// --- ЗАЧЕМ ЭТОТ ФАЙЛ, ЕСЛИ ЕСТЬ event-notifications.test.ts ---
//
// Тот проверяет ПРАВИЛО — `planUpdatePushes` с входом, который подаёт сам.
// Он не может ответить на один вопрос, и вопрос этот здесь главный: **зовёт
// ли его `index.ts` так, как мы думаем.** Имя вышедшего берётся не там, где
// считается ветвь: `leftViaAnswers` зовётся ДВАЖДЫ — в триггере, чтобы
// прочитать имена из `users`, и внутри плана, чтобы разослать. Забудь
// триггер первый вызов — правило осталось бы верным, а прод молчал бы именем.
// Ровно тот случай, что N156 и N160: тест подаёт то, отсутствие чего
// проверяет.
//
// Здесь пишется НАСТОЯЩИЙ документ в `personalEvents`, срабатывает настоящий
// `onPersonalEventUpdated`, и смотрим мы на то, что он оставляет в базе.
//
// --- ЧЕМ НАБЛЮДАЕМ ---
//
// APNs в эмуляторе нет, текст уведомления не достаётся ничем. Достаётся
// **снятие отметки «прочитано»**: `clearReadMark(eventId, recipientsOf(...))`
// вычёркивает id вечера из `users/{uid}.readAgreementIds`, и зовётся оно
// ровно при том же условии, что и сама рассылка — `index.ts` выходит раньше,
// если план вернул пустой список. Значит «id пропал у владельца» и есть
// «рассылка состоялась».
//
// **ПЕРВАЯ РЕДАКЦИЯ СМОТРЕЛА НА ДРУГОЕ, И ЭТО ЗАПИСАНО, А НЕ СТЁРТО.** Она
// считала отметки в `maintenance/eventNotifications/sent` — счёт по ОБЩЕЙ
// коллекции, куда пишут все триггеры всех наборов. Прогон дал **6, 5 и 4**
// там, где ожидалась единица: считались чужие срабатывания, дотекавшие после
// очистки. Признак ровно из I13 — сторож считал не то, о чём его спрашивали,
// и число было бы правдоподобным, окажись оно двойкой. Нынешняя отметка
// привязана к КОНКРЕТНОМУ вечеру и чужого не видит по устройству.
//
// **ЧЕГО ЭТИМ УВИДЕТЬ НЕЛЬЗЯ (I50):** отметка отвечает на «ушло ли
// что-нибудь» и молчит о том, ЧТО ушло и кому. Поэтому два случая из шести
// владельческих здесь не стоят, и это сказано прямо: **правка вечера с
// переносом `'left'`** и **удаление ушедшего из состава** обязаны уведомить —
// первая про дату, второе про исключение, — и отметка снимется в обоих. Их
// решает разбор текста, в `event-notifications.test.ts`, где виден сам список
// `EventPush`.
//
// --- ПОЧЕМУ ОТРИЦАНИЯ НЕ ЖДУТ ПО ЧАСАМ ---
//
// «Подождать три секунды и убедиться, что ничего не пришло» — проверка,
// которая зеленеет и когда триггер промолчал верно, и когда он не запускался
// вовсе (I14). Поэтому рядом с молчаливым вечером здесь всегда стоит ВТОРОЙ,
// заведомо шумный, и ждём мы ЕГО. Дождались — значит очередь триггера дошла
// до записи, сделанной ПОЗЖЕ молчаливой; смотрим на первый — отметка на
// месте. Молчание доказано приходом соседа, а не часами.

beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
});

const OWNER = "owner-uid";
const GUEST = "guest-uid";

function eventDoc(over: Record<string, unknown> = {}) {
  return {
    ownerUid: OWNER,
    date: "2026-09-10T17:30:00",
    type: "Toy",
    location: "İnci qarayev",
    notes: "",
    musicians: [OWNER, GUEST],
    status: "agreed",
    answers: { [OWNER]: "going", [GUEST]: "going" },
    // СЛЕД ПРОШЛОГО ДЕЙСТВИЯ, И ОН ЗДЕСЬ НАРОЧНО. Так и будет в проде: новая
    // запись идёт правилом `answersForSelf()`, которое `lastActionBy` не
    // трогает вовсе, — поле остаётся от того, кто правил вечер до этого.
    // Заодно оно делает владельца адресатом: `recipientsOf` снимает автора, и
    // не будь здесь ничего, автором вышел бы сам владелец (`index.ts`
    // подставляет `ownerUid`), и снимать отметку было бы не у кого.
    lastActionBy: GUEST,
    ...over,
  };
}

/** Завести вечер, у которого владелец отметил карточку прочитанной. */
async function makeEvent(
  over: Record<string, unknown> = {},
): Promise<FirebaseFirestore.DocumentReference> {
  const ref = db().collection("personalEvents").doc();
  await ref.set(eventDoc(over));
  // `arrayUnion`, А НЕ ЛИТЕРАЛ СПИСКА — И ЭТО НЕ ОПРЯТНОСТЬ.
  //
  // `set` с `merge` сливает ПОЛЯ, а не содержимое массива: литерал `[ref.id]`
  // затирает всё, что лежало в поле раньше. В отрицательных проверках вечера
  // ДВА и владелец у них один, поэтому отметка второго стирала отметку
  // первого — и «молчаливый вечер» выглядел уведомлённым. Обе проверки
  // покраснели именно так, ложной тревогой: ветвь была ни при чём.
  await db().collection("users").doc(OWNER).set(
    { readAgreementIds: admin.firestore.FieldValue.arrayUnion(ref.id) },
    { merge: true },
  );
  return ref;
}

/** Состоялась ли рассылка ПО ЭТОМУ вечеру — по снятой отметке «прочитано». */
async function notified(eventId: string): Promise<boolean> {
  const snap = await db().collection("users").doc(OWNER).get();
  const ids = (snap.data()?.readAgreementIds as string[]) ?? [];
  return !ids.includes(eventId);
}

/** Заведомо шумная правка — сосед, по приходу которого судят о молчании. */
async function noisyWrite(
  ref: FirebaseFirestore.DocumentReference,
): Promise<void> {
  await ref.update({ location: "Başqa yer", lastActionBy: GUEST });
}

test("переход answers → 'left' даёт рассылку", async () => {
  const ref = await makeEvent();
  await ref.update({ [`answers.${GUEST}`]: "left" });

  await waitFor(() => notified(ref.id));
});

test("повторная запись того же 'left' рассылки НЕ даёт", async () => {
  const quiet = await makeEvent({
    answers: { [OWNER]: "going", [GUEST]: "left" },
  });
  // Тот же ответ ещё раз — перехода нет.
  await quiet.update({ [`answers.${GUEST}`]: "left" });

  const loud = await makeEvent();
  await noisyWrite(loud);

  await waitFor(() => notified(loud.id));
  expect(await notified(quiet.id)).toBe(false);
});

test("повторное приглашение ('waiting') рассылки НЕ даёт", async () => {
  const quiet = await makeEvent({
    answers: { [OWNER]: "going", [GUEST]: "left" },
  });
  // Владелец зовёт заново: `'left'` сменился на `'waiting'`. Ни ухода, ни
  // изменения полей — уведомлять не о чем.
  await quiet.update({ [`answers.${GUEST}`]: "waiting" });

  const loud = await makeEvent();
  await noisyWrite(loud);

  await waitFor(() => notified(loud.id));
  expect(await notified(quiet.id)).toBe(false);
});

// СТАРЫЙ ПУТЬ БОЛЬШЕ НЕ ПИШЕТ ОБ УХОДЕ — N121, шаг 3, 30.08.
//
// Здесь стояла канарейка наоборот: «уход по СТАРОЙ схеме по-прежнему даёт
// рассылку». Она сторожила инертность шага 1 и вместе со своим предметом
// снята.
//
// ПОЧЕМУ НА ЕЁ МЕСТЕ ОТРИЦАНИЕ, А НЕ ПУСТОТА, И ПОЧЕМУ ОНО ЗДЕСЬ ЧЕСТНОЕ.
// Пишем мы Admin SDK, мимо правил, — то есть заводим ровно ту запись,
// которую участнику правила теперь не дают сделать, и смотрим, что сервер
// на неё МОЛЧИТ. Это не проверка правил (её место в `rules.test.ts`), а
// проверка второй половины работы: даже приди такая запись от чужого
// писателя (сервер, консоль — I49), «İştirakçı ayrıldı» из неё больше не
// родится.
//
// ЖДЁМ НЕ ПО ЧАСАМ, а по шумному соседу — тот же приём, что у остальных
// отрицаний этого файла: молчание доказано приходом соседа, заведомо
// сделанным ПОЗЖЕ.
test("СНЯТО: правка musicians с 'left' рассылки об уходе НЕ даёт", async () => {
  const quiet = await makeEvent();
  await quiet.update({
    musicians: [OWNER],
    lastActionBy: GUEST,
    lastActionType: "left",
  });

  const loud = await makeEvent();
  await noisyWrite(loud);

  await waitFor(() => notified(loud.id));
  expect(await notified(quiet.id)).toBe(false);
});
