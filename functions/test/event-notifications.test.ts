import { strict as assert } from "assert";
import { readFileSync } from "fs";
import {
  diffEvents,
  editedBody,
  EventPush,
  EventSnapshot,
  eventWallClock,
  fmtEventWhen,
  leftViaAnswers,
  planUpdatePushes,
  PlanUpdateInput,
  pushDeleted,
  pushReminder,
  recipientsOf,
  remindableOf,
  reminderKey,
  reminderTitle,
  shouldCatchUp,
  pushUnsettled,
  pushUnsettledReminder,
  unsettledAfterMemberLeft,
  unsettledReasonText,
} from "../src/eventNotifications";
import { isWatchingEventDecision } from "../src/presence";

// Уведомления об изменениях мероприятия. Проверяется то, что проверяемо
// без APNs: кому уходит, что написано, и — не менее важно — КОМУ НЕ УХОДИТ.
//
// Цена ошибки несимметрична: лишнее уведомление человек заметит и
// пожалуется, потерянное не заметит никто. Поэтому случаев «не должно
// отправиться» здесь не меньше, чем положительных.

const OWNER = "owner-uid";
const GUEST = "guest-uid";
const OTHER = "other-uid";

function ev(over: Partial<EventSnapshot> = {}): EventSnapshot {
  return {
    ownerUid: OWNER,
    date: "2026-08-08T17:30:00",
    type: "Toy",
    location: "İnci qarayev",
    notes: "Qalstuk",
    musicians: [OWNER, GUEST],
    ...over,
  };
}

// Обёртка над `planUpdatePushes` с пустым `leftNames` по умолчанию.
//
// Поле обязательное по устройству — так `index.ts` не может забыть его
// передать (см. довод у самого поля). Здесь же ни одна проверка, кроме
// проверок ухода, про имена вышедших ничего не знает, и писать «тут никто не
// выходил» двадцать раз значило бы прятать те два места, где это важно.
function plan(
  input:
    & Omit<PlanUpdateInput, "leftNames">
    & { leftNames?: Record<string, string> },
): EventPush[] {
  return planUpdatePushes({ leftNames: {}, ...input });
}

describe("договор становится «под вопросом» (Часть 6а)", () => {
  const before = ev({ status: "agreed" });

  it("ушёл участник — договор под вопросом, повод назван", () => {
    const after = ev({
      status: "agreed",
      musicians: [OWNER],
      lastActionType: "left",
    });
    assert.deepEqual(unsettledAfterMemberLeft(before, after), {
      status: "unsettled",
      lastActionType: "memberLeft",
    });
  });

  // Без этого триггер писал бы сам себе без конца: его же запись меняет
  // документ и поднимает его заново.
  it("повторного захода нет: после записи повод уже не «left»", () => {
    const after = ev({
      status: "unsettled",
      musicians: [OWNER],
      lastActionType: "memberLeft",
    });
    assert.equal(unsettledAfterMemberLeft(before, after), null);
  });

  // Из отменённого пути в «под вопросом» нет: он закрыт по согласию сторон.
  it("отменённый договор под вопрос не ставится", () => {
    const after = ev({
      status: "cancelled",
      musicians: [OWNER],
      lastActionType: "left",
    });
    assert.equal(unsettledAfterMemberLeft(before, after), null);
  });

  // ЭТОТ СЛУЧАЙ ДОПИСАН ПО ПРОВЕРКЕ ВОЗВРАТОМ 09.08. Сняв условие «кто-то
  // действительно ушёл», я не уронил НИ ОДНОГО теста: соседние случаи
  // подставляли другой повод (`edited`), и до проверки состава разбор не
  // доходил. Тест, которого не хватало, — повод «left» ПРИ НЕТРОНУТОМ
  // составе: так выглядит холостая запись, и состояние по ней менять
  // нечем.
  it("повод «left», а состав не изменился — не под вопросом", () => {
    const after = ev({ status: "agreed", lastActionType: "left" });
    assert.equal(unsettledAfterMemberLeft(before, after), null);
  });

  // Правка места или даты — не уход, и состояние трогать нечем.
  it("состав не менялся — состояние прежнее", () => {
    const after = ev({ status: "agreed", lastActionType: "edited" });
    assert.equal(unsettledAfterMemberLeft(before, after), null);
  });

  // Добавление участника — тоже не уход.
  it("участника ДОБАВИЛИ — не под вопросом", () => {
    const after = ev({
      status: "agreed",
      musicians: [OWNER, GUEST, "third"],
      lastActionType: "edited",
    });
    assert.equal(unsettledAfterMemberLeft(before, after), null);
  });
});

describe("сообщения о «под вопросом» (Часть 6а)", () => {
  const e = ev({ status: "unsettled", lastActionType: "memberLeft" });

  it("повод назван в уведомлении о переходе", () => {
    const p = pushUnsettled("u", "ev1", e);
    assert.ok(p.body.includes("iştirakçı ayrıldı"));
  });

  it("повод «работа исчезла» называется своими словами", () => {
    const p = pushUnsettled(
      "u",
      "ev1",
      ev({ status: "unsettled", lastActionType: "workCancelled" }),
    );
    assert.ok(p.body.includes("iş ləğv olundu"));
  });

  // ГЛАВНОЕ В ЭТОМ НАБОРЕ. Ключ отметки обязан различать, ЧТО отправлено:
  // иначе напоминание «под вопросом» занимает ключ обычного, и после
  // возвращения договора в силу человек не услышит о самом вечере вовсе.
  // Устаревшее сообщение не просто уходит — оно съедает верное.
  it("ключ отметки различает напоминание под вопросом и обычное", () => {
    const wall = "2026-08-09T19:00:00";
    assert.notEqual(
      reminderKey("ev1", "unsettled24h", wall),
      reminderKey("ev1", "24h", wall),
    );
  });

  // СТОРОЖ НА МЕСТО ВЫЗОВА, а не только на саму функцию ключа.
  //
  // Заведён проверкой возвратом: испортив ВЫЗОВ (передав обычный вид),
  // я не уронил ни одного теста — проверка выше сторожит функцию, и ей
  // всё равно, каким видом её зовут. Ровно та форма I9, что записана в
  // реестре: до испорченного места исполнение не добиралось.
  it("почасовой проход зовёт ключ ИМЕННО вида «под вопросом»", () => {
    const src = readFileSync(`${__dirname}/../src/index.ts`, "utf8");
    assert.ok(
      src.includes('reminderKey(doc.id, "unsettled24h", wall)'),
      "почасовой проход перестал звать ключ вида unsettled24h: напоминание " +
        "«под вопросом» займёт ключ обычного, и после возвращения договора " +
        "в силу человек не услышит о самом вечере вовсе",
    );
  });

  it("напоминание называет повод, а не только состояние", () => {
    const p = pushUnsettledReminder("u", "ev1", e);
    assert.ok(p.body.includes("iştirakçı ayrıldı"));
  });

  // Соседка: без неё разбор повода мог бы возвращать пустоту, и три
  // проверки выше прошли бы на пустой строке.
  it("повод непустой при любом значении", () => {
    assert.ok(unsettledReasonText("memberLeft").length > 0);
    assert.ok(unsettledReasonText("workCancelled").length > 0);
    assert.ok(unsettledReasonText(null).length > 0);
  });
});

describe("формат времени мероприятия", () => {
  it("«плавающее гражданское время» читается как есть, без сдвига пояса", () => {
    // N4: 17:30 означает 17:30 ТАМ, где мероприятие идёт. Никакой
    // Date-арифметики по поясам — иначе текст уведомления разъедется с
    // тем, что человек видит на карточке.
    assert.equal(fmtEventWhen("2026-08-08T17:30:00"), "8 Avqust 2026, 17:30");
    assert.equal(fmtEventWhen("2026-01-01T00:00"), "1 Yanvar 2026, 00:00");
  });

  it("дата без времени не даёт висящей запятой", () => {
    assert.equal(fmtEventWhen("2026-08-08"), "8 Avqust 2026");
  });

  it("мусор не роняет разбор", () => {
    assert.equal(fmtEventWhen(""), "");
    assert.equal(fmtEventWhen("не дата"), "");
  });
});

describe("кому уходит", () => {
  it("автор действия не получает уведомления о собственном действии", () => {
    assert.deepEqual(recipientsOf(ev(), OWNER), [GUEST]);
  });

  it("владелец, числящийся и в участниках, не получает двух штук", () => {
    // Владелец лежит в собственном массиве musicians — без дедупа он
    // получил бы по два уведомления на каждое изменение. Тот же дубль,
    // что 03.08 показывал «6 tədbiriniz var» вместо «3».
    const r = recipientsOf(ev({ musicians: [OWNER, OWNER, GUEST] }), null);
    assert.deepEqual(r.sort(), [GUEST, OWNER].sort());
  });

  it("владелец один в мероприятии — уведомлять некого", () => {
    assert.deepEqual(recipientsOf(ev({ musicians: [OWNER] }), OWNER), []);
  });
});

describe("кому уходит НАПОМИНАНИЕ (шаг 3, docs/plan.md)", () => {
  // РАЗВЕДЕНИЕ АДРЕСАТОВ. Изменения идут всем, кто ВИДИТ, — `recipientsOf`
  // выше не тронут, и это главное: сказавший «не может» сказал это про
  // СЕГОДНЯШНИЕ условия, и, поехав дата, он вправе передумать. Напоминание
  // же ничего не решает, оно про время: про вечер, на который человек не
  // идёт, оно чистый шум.
  //
  // ЧТО ЭТО МЕНЯЕТ НА ШАГЕ 3: ничего. Все ответы сегодня `going` — писателя
  // `waiting`/`cant` нет до шага 4. Проверки ниже описывают поведение,
  // которое ЗАРАБОТАЕТ позже; сейчас они сторожат, что читатель встал верно
  // (I48 — необратимый шаг не должен нести чужую работу).

  it("поля нет вовсе — напоминание всем, как до шага 1", () => {
    // Запасной путь для 75 записей прода, у которых поля не было никогда.
    assert.deepEqual(remindableOf(ev()).sort(), [GUEST, OWNER].sort());
  });

  it("все идут — напоминание всем", () => {
    const r = remindableOf(
      ev({ answers: { [OWNER]: "going", [GUEST]: "going" } }),
    );
    assert.deepEqual(r.sort(), [GUEST, OWNER].sort());
  });

  it("сказавший «не может» напоминания не получает", () => {
    const r = remindableOf(ev({ answers: { [GUEST]: "cant" } }));
    assert.deepEqual(r, [OWNER]);
  });

  it("«ждём» напоминание получает — он ещё решает", () => {
    const r = remindableOf(ev({ answers: { [GUEST]: "waiting" } }));
    assert.deepEqual(r.sort(), [GUEST, OWNER].sort());
  });

  it("ВЛАДЕЛЕЦ получает всегда, даже сказав «не может»", () => {
    // У 46 обычных мероприятий из 48 владельца в `musicians` нет вовсе
    // (перепись 10.08), и напоминание про собственный вечер он терять не
    // должен ни при каком ответе.
    const r = remindableOf(
      ev({ answers: { [OWNER]: "cant", [GUEST]: "cant" } }),
    );
    assert.deepEqual(r, [OWNER]);
  });

  it("ключа нет — недостача ожидаема, напоминание идёт", () => {
    // Старые сборки и mugam-v2 правят состав, не зная про поле.
    const r = remindableOf(ev({ answers: { [OWNER]: "going" } }));
    assert.deepEqual(r.sort(), [GUEST, OWNER].sort());
  });

  it("незнакомое значение не отнимает напоминания", () => {
    const r = remindableOf(
      ev({ answers: { [GUEST]: "нечто" } as Record<string, string> }),
    );
    assert.deepEqual(r.sort(), [GUEST, OWNER].sort());
  });

  it("пустая карта при непустом составе напоминания не отнимает", () => {
    // В ОТВЕТЕ пустая карта и отсутствие поля неразличимы (I47); различать
    // их обязана перепись, а не рассылка.
    const r = remindableOf(ev({ answers: {} }));
    assert.deepEqual(r.sort(), [GUEST, OWNER].sort());
  });
});

describe("изменение полей", () => {
  it("изменилась дата — текст называет новую", () => {
    const before = ev();
    const after = ev({ date: "2026-08-09T20:00:00", lastActionBy: OWNER });
    const pushes = plan({
      eventId: "e1", before, after, actorName: "Rafael",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, GUEST);
    assert.equal(pushes[0].title, "Tədbir dəyişdi");
    assert.equal(pushes[0].body, "Rafael tarixi dəyişdi: 9 Avqust 2026, 20:00");
    assert.equal(pushes[0].data.eventId, "e1");
  });

  it("изменилось несколько полей — одно уведомление, не три", () => {
    const before = ev();
    const after = ev({
      date: "2026-08-09T20:00:00",
      location: "Gülüstan",
      lastActionBy: OWNER,
    });
    const pushes = plan({
      eventId: "e1", before, after, actorName: "Rafael",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].body, "Rafael tədbir məlumatlarını dəyişdi");
  });

  it("место стёрли — так и сказано, а не «изменил на пустоту»", () => {
    const diff = diffEvents(ev(), ev({ location: "" }));
    assert.equal(editedBody("Rafael", ev({ location: "" }), diff),
      "Rafael məkanı sildi");
  });

  it("НЕ отправляется: ничего значимого не изменилось", () => {
    // Служебная правка (например, отметка автора) не должна будить
    // никого: уведомление без содержания приучает их не читать.
    const before = ev();
    const after = ev({ lastActionBy: OWNER });
    assert.deepEqual(plan({
      eventId: "e1", before, after, actorName: "Rafael",
    }), []);
  });

  it("НЕ отправляется автору: правил владелец — владельцу не приходит", () => {
    const pushes = plan({
      eventId: "e1",
      before: ev(),
      after: ev({ date: "2026-08-09T20:00:00", lastActionBy: OWNER }),
      actorName: "Rafael",
    });
    assert.equal(pushes.some((p) => p.uid === OWNER), false);
  });
});

describe("состав участников", () => {
  it("добавленный получает «вас добавили», а не «дата изменилась»", () => {
    const before = ev({ musicians: [OWNER] });
    const after = ev({ musicians: [OWNER, GUEST], lastActionBy: OWNER });
    const pushes = plan({
      eventId: "e1", before, after, actorName: "Rafael",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, GUEST);
    assert.equal(pushes[0].title, "Tədbirə əlavə olundunuz");
  });

  it("добавленный не получает ВТОРОГО уведомления об изменении полей", () => {
    // Для него всё мероприятие новое: он этой даты и не видел раньше.
    const before = ev({ musicians: [OWNER] });
    const after = ev({
      musicians: [OWNER, GUEST],
      date: "2026-08-09T20:00:00",
      lastActionBy: OWNER,
    });
    const pushes = plan({
      eventId: "e1", before, after, actorName: "Rafael",
    });
    const forGuest = pushes.filter((p) => p.uid === GUEST);
    assert.equal(forGuest.length, 1);
    assert.equal(forGuest[0].title, "Tədbirə əlavə olundunuz");
  });

  it("убранный ведётся в СПИСОК, а не в карточку", () => {
    // Правила больше не дают ему читать это мероприятие — переход в
    // карточку вернул бы отказ по правам. Уведомление, ведущее в
    // ошибку, хуже уведомления без перехода.
    const before = ev();
    const after = ev({ musicians: [OWNER], lastActionBy: OWNER });
    const pushes = plan({
      eventId: "e1", before, after, actorName: "Rafael",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, GUEST);
    assert.equal(pushes[0].title, "Tədbirdən çıxarıldınız");
    assert.equal(pushes[0].data.openList, "1");
  });

  it("вышел сам — узнаёт ВЛАДЕЛЕЦ, и только он", () => {
    const before = ev({ musicians: [OWNER, GUEST, OTHER] });
    const after = ev({
      musicians: [OWNER, OTHER],
      lastActionBy: GUEST,
      lastActionType: "left",
    });
    const pushes = plan({
      eventId: "e1", before, after, actorName: "Teymur",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, OWNER);
    assert.equal(pushes[0].title, "İştirakçı ayrıldı");
  });

  it("вышедший сам не получает «вас исключили»", () => {
    // Ровно тот случай, ради которого заведён lastActionType: diff у
    // «вышел сам» и «владелец убрал» одинаковый.
    const pushes = plan({
      eventId: "e1",
      before: ev(),
      after: ev({ musicians: [OWNER], lastActionBy: GUEST, lastActionType: "left" }),
      actorName: "Teymur",
    });
    assert.equal(pushes.some((p) => p.uid === GUEST), false);
  });
});

// УХОД ПО НОВОЙ СХЕМЕ — переход ключа `answers` в `'left'` (N121, шаг 1).
//
// ШЕСТЬ ПРОВЕРОК, И ПЯТЬ ИЗ НИХ ОТРИЦАТЕЛЬНЫЕ. Это не перестраховка:
// признак-переход дешёв, а всё, что он обязан НЕ считать уходом, —
// повседневные записи, которые в проде идут пачками. Ошибись он в эту
// сторону, и владелец получал бы «İştirakçı ayrıldı» на каждое сохранение
// формы вечера, про человека, который никуда не уходил.
//
// ШЕСТАЯ — КАНАРЕЙКА, И ОНА ЗДЕСЬ ГЛАВНАЯ (I31): она утверждает НАЛИЧИЕ —
// что старая ветвь жива, — и потому падает, а не зеленеет, если новая
// съест старую. Без неё пять зелёных отрицаний означали бы с равным успехом
// «переход считается верно» и «ветвь не работает вовсе».
describe("участник вышел — НОВАЯ схема, переход answers → left (N121)", () => {
  // Состав НЕ МЕНЯЕТСЯ — в этом вся разница со старой схемой: человек
  // остаётся в `musicians`, меняется только его ответ.
  const before = ev({ answers: { [OWNER]: "going", [GUEST]: "going" } });
  const after = ev({ answers: { [OWNER]: "going", [GUEST]: "left" } });

  it("переход в 'left' даёт уведомление — владельцу, и только ему", () => {
    const pushes = plan({
      eventId: "e1", before, after, actorName: "НЕ ДОЛЖНО ПОПАСТЬ В ТЕКСТ",
      leftNames: { [GUEST]: "Teymur" },
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, OWNER);
    assert.equal(pushes[0].title, "İştirakçı ayrıldı");
  });

  // ПОЛОВИНА ОТВЕТА, КОТОРОЙ НЕ БЫЛО В РАЗБОРЕ 26.08. `answersForSelf()`
  // пускает только ключ `answers`, значит `lastActionBy` остаётся от
  // ПРОШЛОГО действия, а когда его нет — `index.ts` подставляет владельца.
  // Возьми текст имя оттуда, и владелец прочитал бы, что вышел он сам.
  it("имя берётся от uid перехода, а не из lastActionBy", () => {
    const pushes = plan({
      eventId: "e1",
      before,
      // `lastActionBy` намеренно указывает на ПОСТОРОННЕГО: так и будет в
      // проде, где он остался от прошлой правки вечера.
      after: ev({
        answers: { [OWNER]: "going", [GUEST]: "left" },
        lastActionBy: OTHER,
        lastActionType: "edited",
      }),
      actorName: "Rafael",
      leftNames: { [GUEST]: "Teymur" },
    });
    assert.equal(pushes.length, 1);
    assert.ok(pushes[0].body.startsWith("Teymur "), pushes[0].body);
    assert.equal(pushes[0].body.includes("Rafael"), false);
  });

  it("имени нет в карте — запасное слово, а не «undefined»", () => {
    // У 7 учёток из 12 поля `name` нет вовсе (N142), и `displayName`
    // отвечает тем же словом. Печатать сюда `undefined` значило бы
    // показать человеку поломку вместо новости.
    const pushes = plan({
      eventId: "e1", before, after, actorName: "Rafael", leftNames: {},
    });
    assert.equal(pushes.length, 1);
    assert.ok(pushes[0].body.startsWith("İstifadəçi "), pushes[0].body);
  });

  it("повторная запись 'left' уведомления НЕ даёт", () => {
    assert.deepEqual(plan({
      eventId: "e1", before: after, after, actorName: "Rafael",
      leftNames: { [GUEST]: "Teymur" },
    }), []);
  });

  it("перенос 'left' при правке вечера владельцем уведомления НЕ даёт", () => {
    // `answersForParticipants` переносит знакомый ответ как есть, и правок
    // вечера бывает сколько угодно. Признак-СОСТОЯНИЕ дал бы здесь push на
    // каждую; признак-переход не даёт ни одного — и без единой добавочной
    // проверки, потому что `before` и `after` оба `'left'`.
    const pushes = plan({
      eventId: "e1",
      before: after,
      after: ev({
        date: "2026-08-09T20:00:00",
        answers: { [OWNER]: "going", [GUEST]: "left" },
        lastActionBy: OWNER,
      }),
      actorName: "Rafael",
      leftNames: { [GUEST]: "Teymur" },
    });
    // Про уход — ни слова; про правку даты владелец сам себе не шлёт, а
    // вышедший её больше не получает (`recipientsOf`).
    assert.equal(pushes.some((p) => p.title === "İştirakçı ayrıldı"), false);
  });

  it("удаление ушедшего из состава уведомления об уходе НЕ даёт", () => {
    // Ключ пропал вовсе: `after[uid]` больше не `'left'`, перехода нет.
    const pushes = plan({
      eventId: "e1",
      before: after,
      after: ev({
        musicians: [OWNER],
        answers: { [OWNER]: "going" },
        lastActionBy: OWNER,
      }),
      actorName: "Rafael",
      leftNames: {},
    });
    assert.equal(pushes.some((p) => p.title === "İştirakçı ayrıldı"), false);
  });

  it("повторное приглашение ('waiting') уведомления НЕ даёт", () => {
    assert.deepEqual(plan({
      eventId: "e1",
      before: after,
      after: ev({ answers: { [OWNER]: "going", [GUEST]: "waiting" } }),
      actorName: "Rafael",
      leftNames: {},
    }), []);
  });

  // КАНАРЕЙКА К ПЯТИ ОТРИЦАНИЯМ ВЫШЕ И К САМОЙ ВЫКЛАДКЕ.
  //
  // Она утверждает НАЛИЧИЕ (I31: такой сторож сам себе канарейка) и потому
  // доказывает ровно то, ради чего шаг 1 выкладывается инертным: старый путь
  // — через `musicians` и `lastActionType` — работает как работал. Съешь
  // новая ветвь старую, покраснеет здесь, а не на трубке у владельца.
  it("КАНАРЕЙКА: обычный уход по СТАРОЙ схеме по-прежнему даёт", () => {
    const pushes = plan({
      eventId: "e1",
      before: ev({ musicians: [OWNER, GUEST, OTHER] }),
      after: ev({
        musicians: [OWNER, OTHER],
        lastActionBy: GUEST,
        lastActionType: "left",
      }),
      actorName: "Teymur",
      leftNames: {},
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, OWNER);
    assert.equal(pushes[0].title, "İştirakçı ayrıldı");
    assert.ok(pushes[0].body.startsWith("Teymur "), pushes[0].body);
  });

  // СТОРОЖ НА ПРОВОДКУ ИМЕНИ, И ПОСТАВЛЕН ОН ПО РЕЗУЛЬТАТУ ПОРЧИ, А НЕ ЗАРАНЕЕ.
  //
  // 28.08 порча «`leftNames[uid] = actorName` вместо `await displayName(uid)`»
  // в `index.ts` прошла ЗЕЛЁНОЙ на всех 360 проверках — и это ровно тот
  // дефект, ради которого половина ветви и писалась: владелец прочитал бы, что
  // из вечера вышел он сам. Не поймал никто и не мог:
  //
  //   • разбор `EventPush` подаёт `leftNames` сам — тест не видит, откуда они
  //     взялись в проде (N156, N160: тест подаёт то, отсутствие чего
  //     проверяет);
  //   • эмулятор текста уведомления не достаёт ничем — APNs в нём нет, а
  //     `sendFcmPush` тела нигде не сохраняет. Проверка отсутствует не по
  //     недосмотру, а по устройству (I50).
  //
  // **ЧЕГО ЭТОТ СТОРОЖ НЕ ЛОВИТ, И ЭТО ЕГО ГЛАВНОЕ СВОЙСТВО:** он сравнивает
  // ТЕКСТ, а не поведение. Переименуют `displayName`, вынесут чтение имён в
  // отдельную функцию, соберут строку иначе — он покраснеет на исправном
  // коде; поменяют местами uid в двух соседних строках — пропустит. Он держит
  // ровно одну руку: ту, что «упростит» ветвь, подставив готовый `actorName`.
  // Настоящая проверка появится, только если тексты уведомлений станут
  // доставаться из эмулятора.
  it("index.ts берёт имя вышедшего у ЕГО uid, а не готовое actorName", () => {
    const src = readFileSync(`${__dirname}/../src/index.ts`, "utf8");
    assert.ok(
      src.includes("leftNames[uid] = await displayName(uid);"),
      "проводка имени вышедшего изменилась: если имя снова берётся из " +
        "actorName, «İştirakçı ayrıldı» назовёт постороннего — чаще всего " +
        "самого владельца, потому что при пустом lastActionBy подставляется " +
        "ownerUid",
    );
  });

  // СОСЕДКА К СТОРОЖУ ВЫШЕ (I31): он утверждает НАЛИЧИЕ строки, значит сам
  // себе канарейка — ослепший разбор дал бы ноль и покраснел. Но слепота
  // бывает и к материалу: прочитайся файл пустым, обе проверки прошли бы
  // молча, если бы вторая утверждала отсутствие. Здесь она утверждает, что
  // файл вообще читается и что искомое место в нём одно, а не два.
  it("соседка: место чтения имён в index.ts ровно одно", () => {
    const src = readFileSync(`${__dirname}/../src/index.ts`, "utf8");
    assert.equal(src.split("leftNames[uid] = ").length - 1, 1);
    assert.ok(src.includes("leftViaAnswers(b, a)"));
  });

  // САМ ПРИЗНАК, ОТДЕЛЬНО ОТ РАССЫЛКИ: его зовёт и `index.ts` — ради имён, —
  // и `planUpdatePushes`, ради ветвления. Порознь зовут, порознь и проверяем.
  describe("сам признак перехода", () => {
    it("называет вышедшего поимённо", () => {
      assert.deepEqual(leftViaAnswers(before, after), [GUEST]);
    });

    it("поля не было вовсе — перехода нет", () => {
      assert.deepEqual(leftViaAnswers(ev(), ev()), []);
    });

    it("left → going → left: второй уход — законный, и он виден", () => {
      const back = ev({ answers: { [OWNER]: "going", [GUEST]: "going" } });
      assert.deepEqual(leftViaAnswers(after, back), []);
      assert.deepEqual(leftViaAnswers(back, after), [GUEST]);
    });

    it("вышли двое одной записью — названы оба, а не первый", () => {
      // В проде правило пускает один ключ за запись; но писатель у документа
      // не один (I49), и сигнатура на одного прятала бы второго молча
      // (N51/I11).
      const two = ev({
        musicians: [OWNER, GUEST, OTHER],
        answers: { [OWNER]: "going", [GUEST]: "left", [OTHER]: "left" },
      });
      assert.deepEqual(
        leftViaAnswers(ev({ musicians: [OWNER, GUEST, OTHER] }), two).sort(),
        [GUEST, OTHER].sort(),
      );
    });
  });
});

// ВЫШЕДШИЙ ПЕРЕСТАЁТ БЫТЬ ЖИВЫМ В ВЕЧЕРЕ (N121, шаг 1).
//
// Отсев стоит в ОДНОМ месте — `recipientsOf`, — а `remindableOf` получает
// его оттуда, потому что на нём и построен. Проверки при этом ДВЕ: порознь
// зовут обе, значит порознь обе и обязаны отвечать. Сними кто-нибудь
// зависимость между ними — покраснеет вторая, а не выяснится на трубке.
describe("вышедший ('left') не считается живым", () => {
  it("рассылка изменений его больше не касается", () => {
    const e = ev({
      musicians: [OWNER, GUEST, OTHER],
      answers: { [GUEST]: "left", [OTHER]: "going" },
    });
    assert.deepEqual(recipientsOf(e, null).sort(), [OTHER, OWNER].sort());
  });

  it("напоминаний он больше не получает", () => {
    const e = ev({
      musicians: [OWNER, GUEST, OTHER],
      answers: { [GUEST]: "left", [OTHER]: "going" },
    });
    assert.deepEqual(remindableOf(e).sort(), [OTHER, OWNER].sort());
  });

  it("сказавший «не может» изменения получает по-прежнему", () => {
    // Соседка к двум проверкам выше, и она про разные вопросы, а не про
    // разные значения: `cant` — «я не приду», человек в вечере и вправе
    // передумать, поехав дата; `'left'` — «меня здесь больше нет».
    const e = ev({ answers: { [GUEST]: "cant" } });
    assert.deepEqual(recipientsOf(e, null).sort(), [GUEST, OWNER].sort());
  });

  it("ВЛАДЕЛЬЦА не снимает даже с 'left' в карте", () => {
    // Правила такого не пропустят (`answersForSelf` требует
    // `ownerUid != uid`), значит взяться это может только от чужого
    // писателя — Admin SDK, консоль (I49). Отнимать у человека вести о
    // собственном вечере по чужой записи мы не будем.
    const e = ev({ answers: { [OWNER]: "left", [GUEST]: "going" } });
    assert.deepEqual(recipientsOf(e, null).sort(), [GUEST, OWNER].sort());
    assert.deepEqual(remindableOf(e).sort(), [GUEST, OWNER].sort());
  });
});

describe("отмена по согласию", () => {
  // Четыре хода, и ветвление идёт ПО ИМЕНИ ПОСТУПКА. Проверяется здесь
  // прежде всего то, чего сравнением before/after не добиться вовсе:
  // отзыв и отказ оставляют ОДИН И ТОТ ЖЕ след в данных, а уходят разным
  // людям. Перепутай их — и человек получит ровно противоположную новость
  // о судьбе своего договора.

  it("запрос отмены уходит второй стороне", () => {
    const pushes = plan({
      eventId: "e1",
      before: ev(),
      after: ev({
        cancelRequestedBy: OWNER,
        cancelRequestedAtMs: 1000,
        lastActionBy: OWNER,
        lastActionType: "cancelRequested",
      }),
      actorName: "Rafael",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, GUEST);
    assert.equal(pushes[0].title, "Ləğv təklifi");
  });

  it("повторная просьба БЕЗ очистки поля тоже уходит — тут признаки и расходятся (N29)", () => {
    // Единственный случай, где «сдвиг отметки» и «появление из пустого»
    // дают РАЗНЫЙ ответ, и потому единственный, который доказывает выбор
    // признака. Поле непусто в обоих снимках — «появления» нет, — а
    // просьба подана новая, и отметка это говорит.
    //
    // Сегодня такого пути в приложении нет: и отзыв, и отказ поле
    // очищают. Тест защищает от дня, когда он появится, — а появится он
    // молча, потому что признак-переход не ошибается, он просто не
    // срабатывает.
    const pushes = plan({
      eventId: "e1",
      before: ev({ cancelRequestedBy: OWNER, cancelRequestedAtMs: 1000 }),
      after: ev({
        cancelRequestedBy: OWNER,
        cancelRequestedAtMs: 5000,
        lastActionBy: OWNER,
        lastActionType: "cancelRequested",
      }),
      actorName: "Rafael",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, GUEST);
    assert.equal(pushes[0].title, "Ləğv təklifi");
  });

  it("ВТОРОЙ запрос после отзыва уходит", () => {
    // Отзыв вернул поле в null, значит «появление из пустого» по одному
    // договору случается сколько угодно раз. Признак построен на сдвиге
    // отметки времени и потому отвечает на вопрос «просьба подана», а не
    // «поле сейчас заполнено».
    const pushes = plan({
      eventId: "e1",
      before: ev({ cancelRequestedBy: null, cancelRequestedAtMs: null }),
      after: ev({
        cancelRequestedBy: OWNER,
        cancelRequestedAtMs: 2000,
        lastActionBy: OWNER,
        lastActionType: "cancelRequested",
      }),
      actorName: "Rafael",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, GUEST);
  });

  it("переписанная тем же временем просьба второго уведомления не даёт", () => {
    // Холостая запись — не новая просьба. Тот же довод, что и у сдвига:
    // уведомление привязано к СОБЫТИЮ, а не к состоянию поля.
    const pushes = plan({
      eventId: "e1",
      before: ev({ cancelRequestedBy: OWNER, cancelRequestedAtMs: 1000 }),
      after: ev({
        cancelRequestedBy: OWNER,
        cancelRequestedAtMs: 1000,
        lastActionBy: OWNER,
        lastActionType: "cancelRequested",
      }),
      actorName: "Rafael",
    });
    assert.equal(pushes.length, 0);
  });

  it("подтверждение отмены уходит тому, кто просил", () => {
    const pushes = plan({
      eventId: "e1",
      before: ev({ cancelRequestedBy: OWNER, cancelRequestedAtMs: 1000 }),
      after: ev({
        cancelRequestedBy: OWNER,
        cancelRequestedAtMs: 1000,
        cancelConfirmedBy: GUEST,
        status: "cancelled",
        lastActionBy: GUEST,
        lastActionType: "cancelConfirmed",
      }),
      actorName: "Teymur",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, OWNER);
    assert.equal(pushes[0].title, "Müqavilə ləğv edildi");
  });

  it("ОТЗЫВ уходит второй стороне — той, кого просили подтвердить", () => {
    const pushes = plan({
      eventId: "e1",
      before: ev({ cancelRequestedBy: OWNER, cancelRequestedAtMs: 1000 }),
      after: ev({
        cancelRequestedBy: null,
        cancelRequestedAtMs: null,
        lastActionBy: OWNER,
        lastActionType: "cancelWithdrawn",
      }),
      actorName: "Rafael",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, GUEST);
    assert.equal(pushes[0].title, "Ləğv təklifi geri götürüldü");
  });

  it("ОТКАЗ уходит запросившему — адресат берётся из before", () => {
    // В `after` поле уже пустое: его очистил тот самый ход, о котором
    // шлём. Возьми адресата из `after` — уведомление не уйдёт никому, и
    // человек останется ждать ответа, которого уже не будет.
    const pushes = plan({
      eventId: "e1",
      before: ev({ cancelRequestedBy: OWNER, cancelRequestedAtMs: 1000 }),
      after: ev({
        cancelRequestedBy: null,
        cancelRequestedAtMs: null,
        lastActionBy: GUEST,
        lastActionType: "cancelDeclined",
      }),
      actorName: "Teymur",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, OWNER);
    assert.equal(pushes[0].title, "Ləğv təklifi qəbul edilmədi");
  });

  it("отзыв и отказ при ОДИНАКОВЫХ данных дают РАЗНЫЕ новости", () => {
    // Главная проверка всего блока. before и after у обоих ходов
    // совпадают до последнего поля, кроме имени поступка и автора —
    // именно поэтому ветвиться по before/after нельзя в принципе.
    //
    // Проверяются и адресат, и СЛОВА, причём слова важнее. В договоре
    // ровно двое, поэтому «все кроме автора» случайно совпадает с нужным
    // адресатом и у отзыва, и у отказа — сверка одних лишь uid пропустила
    // бы подмену одного хода другим. А человек получил бы про свой
    // договор ровно противоположную новость: «передумали просить» вместо
    // «вам отказали».
    const before = ev({ cancelRequestedBy: OWNER, cancelRequestedAtMs: 1000 });
    const cleared = { cancelRequestedBy: null, cancelRequestedAtMs: null };
    const withdrawn = plan({
      eventId: "e1",
      before,
      after: ev({
        ...cleared,
        lastActionBy: OWNER,
        lastActionType: "cancelWithdrawn",
      }),
      actorName: "Rafael",
    });
    const declined = plan({
      eventId: "e1",
      before,
      after: ev({
        ...cleared,
        lastActionBy: GUEST,
        lastActionType: "cancelDeclined",
      }),
      actorName: "Teymur",
    });
    assert.notEqual(withdrawn[0].uid, declined[0].uid);
    assert.equal(withdrawn[0].uid, GUEST);
    assert.equal(declined[0].uid, OWNER);
    // Слова — то, что при подмене ходов расходится по существу.
    assert.notEqual(withdrawn[0].title, declined[0].title);
    assert.equal(withdrawn[0].title, "Ləğv təklifi geri götürüldü");
    assert.equal(declined[0].title, "Ləğv təklifi qəbul edilmədi");
  });

  it("автор своего же хода не получает ничего — все четыре", () => {
    // Цена ошибки тут не «лишнее письмо»: человек получил бы новость о
    // собственном нажатии и решил, что её прислал второй.
    const before = ev({ cancelRequestedBy: OWNER, cancelRequestedAtMs: 1000 });
    for (const [type, actor] of [
      ["cancelRequested", OWNER],
      ["cancelConfirmed", GUEST],
      ["cancelWithdrawn", OWNER],
      ["cancelDeclined", GUEST],
    ] as const) {
      const pushes = plan({
        eventId: "e1",
        before: type === "cancelRequested" ? ev() : before,
        after: ev({
          cancelRequestedBy: type === "cancelRequested" ? OWNER : null,
          cancelRequestedAtMs: type === "cancelRequested" ? 2000 : null,
          cancelConfirmedBy: type === "cancelConfirmed" ? GUEST : null,
          status: type === "cancelConfirmed" ? "cancelled" : "agreed",
          lastActionBy: actor,
          lastActionType: type,
        }),
        actorName: "Kim",
      });
      for (const p of pushes) {
        assert.notEqual(p.uid, actor, `${type} ушло собственному автору`);
      }
    }
  });

  it("отмена не тянет за собой уведомление о правке полей", () => {
    // Ветка отмены обрывает разбор: иначе смена `status` на `cancelled`
    // вместе с чем-нибудь ещё дала бы человеку две новости об одном
    // действии — «договор отменён» и «поля изменились».
    const pushes = plan({
      eventId: "e1",
      before: ev({ cancelRequestedBy: OWNER, cancelRequestedAtMs: 1000 }),
      after: ev({
        cancelRequestedBy: OWNER,
        cancelRequestedAtMs: 1000,
        cancelConfirmedBy: GUEST,
        status: "cancelled",
        location: "Başqa yer",
        lastActionBy: GUEST,
        lastActionType: "cancelConfirmed",
      }),
      actorName: "Teymur",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].title, "Müqavilə ləğv edildi");
  });
});

describe("удаление", () => {
  it("текст читается как законченный факт, без задачи для читателя", () => {
    const p = pushDeleted(GUEST, "e1", "Rafael", ev());
    assert.equal(p.title, "Tədbir silindi");
    assert.equal(p.body, "Rafael «Toy» tədbirini sildi — 8 Avqust 2026, 17:30");
    // Ни вопроса, ни призыва: делать читателю нечего, мероприятия больше
    // нет. Дата в тексте обязательна — иначе при нескольких мероприятиях
    // человек не поймёт, какое исчезло.
    assert.equal(/\?|yoxlayın|təsdiq/.test(p.body), false);
    assert.equal(p.data.openList, "1");
  });
});

describe("напоминания", () => {
  it("заголовок считается от фактического остатка, а не от названия окна", () => {
    // Догнанное напоминание с «осталось 3 часа», когда осталось два, —
    // отметка, утверждающая то, чего не проверяла.
    assert.equal(reminderTitle(23.4), "Sabah tədbiriniz var");
    assert.equal(reminderTitle(20), "Sabah tədbiriniz var");
    assert.equal(reminderTitle(19.4), "Tədbirə 19 saat qaldı");
    assert.equal(reminderTitle(3), "Tədbirə 3 saat qaldı");
    assert.equal(reminderTitle(1.6), "Tədbirə 2 saat qaldı");
    assert.equal(reminderTitle(0.4), "Tədbirə az qaldı");
  });

  it("в теле — время и место, без висящих разделителей", () => {
    assert.equal(pushReminder(GUEST, "e1", ev(), "24h", 23).body,
      "«Toy» — 8 Avqust 2026, 17:30, İnci qarayev");
    assert.equal(pushReminder(GUEST, "e1", ev({ location: "" }), "24h", 23).body,
      "«Toy» — 8 Avqust 2026, 17:30");
  });

  it("перенос мероприятия открывает НОВОЕ напоминание", () => {
    // Ключ по одному id запер бы его: отметка о старом времени стоит, а
    // время уже другое — человек получил бы напоминание о том времени,
    // которого больше нет, и ни одного о новом.
    const a = reminderKey("e1", "24h", "2026-08-08T17:30:00");
    const b = reminderKey("e1", "24h", "2026-08-09T20:00:00");
    assert.notEqual(a, b);
  });

  it("правка места второго напоминания не порождает", () => {
    // Время не менялось — ключ тот же.
    assert.equal(
      reminderKey("e1", "3h", "2026-08-08T17:30:00"),
      reminderKey("e1", "3h", "2026-08-08T17:30:00"),
    );
  });

  it("догоняется окно, пропущенное из-за несостоявшегося прогона", () => {
    const wall = Date.parse("2026-08-08T17:30:00Z");
    const ahead = 24 * 3600 * 1000;
    // Мероприятие создано за неделю — окно существовало, значит прогон
    // просто не отработал, и догнать надо.
    const created = wall - 7 * 24 * 3600 * 1000;
    assert.equal(shouldCatchUp(wall, ahead, created), true);
  });

  it("НЕ догоняется окно, которого не было: создали позже его прохождения", () => {
    const wall = Date.parse("2026-08-08T17:30:00Z");
    const ahead = 24 * 3600 * 1000;
    // Создано за 17 часов — суточное окно к тому моменту уже прошло.
    // Человек только что получил «Tədbirə əlavə olundunuz».
    const created = wall - 17 * 3600 * 1000;
    assert.equal(shouldCatchUp(wall, ahead, created), false);
    // Трёхчасовое при этом придёт: его окно ещё впереди.
    assert.equal(shouldCatchUp(wall, 3 * 3600 * 1000, created), true);
  });

  it("нет createdAt — трактуем как «было», сомнение в сторону лишнего", () => {
    const wall = Date.parse("2026-08-08T17:30:00Z");
    assert.equal(shouldCatchUp(wall, 24 * 3600 * 1000, null), true);
  });
});

describe("подавление присутствием", () => {
  const base = { uid: GUEST, nowMs: 1_000_000 };

  it("НЕ отправляется: человек смотрит на эту карточку прямо сейчас", () => {
    assert.equal(isWatchingEventDecision({
      ...base,
      userData: { activeEventId: "e1", presenceIntervalMs: 30000 },
      eventId: "e1",
      lastSeenMs: 1_000_000 - 10_000,
    }), true);
  });

  it("смотрит ДРУГУЮ карточку — уведомление уходит", () => {
    assert.equal(isWatchingEventDecision({
      ...base,
      userData: { activeEventId: "e2", presenceIntervalMs: 30000 },
      eventId: "e1",
      lastSeenMs: 1_000_000 - 10_000,
    }), false);
  });

  it("отметка протухла — уведомление уходит", () => {
    // Свернул, убил приложение или потерял сеть: сердцебиение
    // прекращается, отметка перестаёт быть свежей сама.
    assert.equal(isWatchingEventDecision({
      ...base,
      userData: { activeEventId: "e1", presenceIntervalMs: 30000 },
      eventId: "e1",
      lastSeenMs: 1_000_000 - 61_000,
    }), false);
  });

  it("сборка про карточки ничего не сообщает — уведомление уходит", () => {
    // Направление выбрано намеренно: лишний push заметен и поправим,
    // потерянный не заметен никем.
    assert.equal(isWatchingEventDecision({
      ...base,
      userData: { presenceIntervalMs: 30000 },
      eventId: "e1",
      lastSeenMs: 1_000_000,
    }), false);
  });

  it("документа пользователя нет вовсе — уведомление уходит", () => {
    assert.equal(isWatchingEventDecision({
      ...base, userData: undefined, eventId: "e1", lastSeenMs: 1_000_000,
    }), false);
  });
});

describe("три формы даты в проде (N26)", () => {
  it("плавающая читается как есть — запрет N4 не нарушен", () => {
    assert.equal(eventWallClock("2026-08-08T17:30:00.000"),
      "2026-08-08T17:30:00.000");
    assert.equal(eventWallClock("2026-07-29T18:12:37.122341"),
      "2026-07-29T18:12:37.122341");
  });

  it("старая UTC-запись приводится к бакинским стенным часам", () => {
    // 15:50Z — это 19:50 в Баку. Без перевода напоминание ушло бы на
    // четыре часа раньше срока.
    assert.equal(eventWallClock("2026-07-01T15:50:02.000Z"),
      "2026-07-01T19:50:02");
    assert.equal(fmtEventWhen("2026-07-01T15:50:02.000Z"),
      "1 İyul 2026, 19:50");
  });

  it("запись с явным смещением тоже приводится", () => {
    assert.equal(eventWallClock("2026-08-08T13:30:00+00:00"),
      "2026-08-08T17:30:00");
  });

  it("мусор не роняет разбор и не подменяется", () => {
    assert.equal(eventWallClock(""), "");
    assert.equal(eventWallClock("не дата"), "не дата");
  });
});

// УБРАЛИ ВСЛЕД ЗА УХОДОМ — ВЫШЕДШЕМУ НЕ ПИШЕМ (решение владельца 29.08).
//
// Довод владельца дословно: «не надо отправлять push, потому что Рафаэль
// вышел сознательно». Удаление здесь — уборка вслед за его же ходом, а не
// поступок над ним, и «{Ad} sizi tədbirindən çıxardı» рассказало бы человеку
// о его собственном решении чужими словами.
//
// НАБОР ДЕРЖИТ ОБЕ СТОРОНЫ, и это не симметрия ради красоты: гашение,
// написанное шире, чем задумано, отняло бы у владельца единственный способ
// сказать участнику «я тебя убрал». Поэтому рядом с «молчим» стоит «пишем».
describe("удаление вслед за уходом (N121, шаг 2)", () => {
  it("вышедшего убрали из состава — ему НЕ пишут", () => {
    const before = ev({
      musicians: [OWNER, GUEST],
      answers: { [OWNER]: "going", [GUEST]: "left" },
    });
    const after = ev({
      musicians: [OWNER],
      answers: { [OWNER]: "going" },
      lastActionType: "edited",
      lastActionBy: OWNER,
    });
    const out = plan({
      eventId: "e1",
      before,
      after,
      actorName: "Teymur",
    });
    assert.deepEqual(out.filter((p) => p.uid === GUEST), []);
  });

  it("СОСЕДКА: не уходившего убрали — ему пишут", () => {
    // Тот же ход, та же форма записи, разница ровно в одном ключе карты.
    // Без этой проверки «ему не пишут» подтвердилось бы и гашением,
    // которое молчит всегда, — а это отняло бы у владельца возможность
    // сказать участнику, что он его убрал.
    const before = ev({
      musicians: [OWNER, GUEST],
      answers: { [OWNER]: "going", [GUEST]: "going" },
    });
    const after = ev({
      musicians: [OWNER],
      answers: { [OWNER]: "going" },
      lastActionType: "edited",
      lastActionBy: OWNER,
    });
    const out = plan({
      eventId: "e1",
      before,
      after,
      actorName: "Teymur",
    });
    const mine = out.filter((p) => p.uid === GUEST);
    assert.equal(mine.length, 1);
    assert.equal(mine[0].title, "Tədbirdən çıxarıldınız");
  });

  it("признак берётся из BEFORE — в AFTER ключа уже нет", () => {
    // Правка состава переписывает карту по составу, и удалённый из неё
    // выпадает. Спроси признак у `after` — он был бы пуст ВСЕГДА, гашение
    // не сработало бы ни разу, а выглядело бы это как «сделали, не помогло».
    // Здесь `after.answers` намеренно НЕ содержит ушедшего, как в проде.
    const before = ev({
      musicians: [OWNER, GUEST],
      answers: { [OWNER]: "going", [GUEST]: "left" },
    });
    const after = ev({
      musicians: [OWNER],
      answers: { [OWNER]: "going" },
      lastActionBy: OWNER,
    });
    assert.equal(after.answers?.[GUEST], undefined);
    const out = plan({
      eventId: "e1",
      before,
      after,
      actorName: "Teymur",
    });
    assert.deepEqual(out.filter((p) => p.uid === GUEST), []);
  });

  it("вышедший не получает и «дата изменилась» той же правкой", () => {
    // Пометка `touchedByActor` ставится ДО решения о письме. Поставь её
    // только в ветви с письмом — и погашенный участник получил бы вместо
    // «вас убрали» рассылку об изменении вечера, из которого его убрали.
    const before = ev({
      musicians: [OWNER, GUEST],
      answers: { [OWNER]: "going", [GUEST]: "left" },
    });
    const after = ev({
      musicians: [OWNER],
      answers: { [OWNER]: "going" },
      date: "2026-08-09T19:00:00",
      lastActionBy: OWNER,
    });
    const out = plan({
      eventId: "e1",
      before,
      after,
      actorName: "Teymur",
    });
    assert.deepEqual(out.filter((p) => p.uid === GUEST), []);
  });
});
