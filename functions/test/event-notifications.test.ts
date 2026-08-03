import { strict as assert } from "assert";
import {
  diffEvents,
  editedBody,
  EventSnapshot,
  eventWallClock,
  fmtEventWhen,
  planUpdatePushes,
  pushDeleted,
  pushReminder,
  recipientsOf,
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

describe("изменение полей", () => {
  it("изменилась дата — текст называет новую", () => {
    const before = ev();
    const after = ev({ date: "2026-08-09T20:00:00", lastActionBy: OWNER });
    const pushes = planUpdatePushes({
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
    const pushes = planUpdatePushes({
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
    assert.deepEqual(planUpdatePushes({
      eventId: "e1", before, after, actorName: "Rafael",
    }), []);
  });

  it("НЕ отправляется автору: правил владелец — владельцу не приходит", () => {
    const pushes = planUpdatePushes({
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
    const pushes = planUpdatePushes({
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
    const pushes = planUpdatePushes({
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
    const pushes = planUpdatePushes({
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
    const pushes = planUpdatePushes({
      eventId: "e1", before, after, actorName: "Teymur",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, OWNER);
    assert.equal(pushes[0].title, "İştirakçı ayrıldı");
  });

  it("вышедший сам не получает «вас исключили»", () => {
    // Ровно тот случай, ради которого заведён lastActionType: diff у
    // «вышел сам» и «владелец убрал» одинаковый.
    const pushes = planUpdatePushes({
      eventId: "e1",
      before: ev(),
      after: ev({ musicians: [OWNER], lastActionBy: GUEST, lastActionType: "left" }),
      actorName: "Teymur",
    });
    assert.equal(pushes.some((p) => p.uid === GUEST), false);
  });
});

describe("отмена по согласию", () => {
  it("запрос отмены уходит второй стороне", () => {
    const pushes = planUpdatePushes({
      eventId: "e1",
      before: ev(),
      after: ev({ cancelRequestedBy: OWNER, lastActionBy: OWNER }),
      actorName: "Rafael",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, GUEST);
    assert.equal(pushes[0].title, "Ləğv təklifi");
  });

  it("подтверждение отмены уходит тому, кто просил", () => {
    const pushes = planUpdatePushes({
      eventId: "e1",
      before: ev({ cancelRequestedBy: OWNER }),
      after: ev({
        cancelRequestedBy: OWNER,
        cancelConfirmedBy: GUEST,
        status: "cancelled",
        lastActionBy: GUEST,
      }),
      actorName: "Teymur",
    });
    assert.equal(pushes.length, 1);
    assert.equal(pushes[0].uid, OWNER);
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
  it("за сутки и за три часа — разные заголовки", () => {
    assert.equal(pushReminder(GUEST, "e1", ev(), "24h").title,
      "Sabah tədbiriniz var");
    assert.equal(pushReminder(GUEST, "e1", ev(), "3h").title,
      "Tədbirə 3 saat qaldı");
  });

  it("в теле — время и место, без висящих разделителей", () => {
    assert.equal(pushReminder(GUEST, "e1", ev(), "24h").body,
      "«Toy» — 8 Avqust 2026, 17:30, İnci qarayev");
    assert.equal(pushReminder(GUEST, "e1", ev({ location: "" }), "24h").body,
      "«Toy» — 8 Avqust 2026, 17:30");
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
