import { strict as assert } from "assert";
import {
  fmtDateTransition,
  planOfferPushes,
  pushOfferChanged,
} from "../src/jobOfferNotifications";

const INIT = "initiator-uid";
const RECIP = "recipient-uid";
const MEMBERS = [INIT, RECIP];

const base = {
  jobOfferBy: INIT,
  jobOfferAt: "2026-08-03T20:55:37.545118Z",
  eventDate: "2026-08-08T17:30:00.000",
  eventType: "Toy",
  eventLocation: "İnci qarayev",
  eventNotes: "Qalstuk",
  recipientAgreed: false,
  cancelledBy: null as string | null,
};

// Состояние чата ПОСЛЕ состоявшейся сделки: jobOfferBy остаётся стоять,
// его очищает только отмена. Это и есть обычное `before` для нового
// предложения — а вовсе не пустой документ.
const prevRound = {
  ...base,
  jobOfferAt: "2026-08-03T14:05:52.629597Z",
  eventDate: "2026-08-10T17:20:00.000",
  recipientAgreed: true,
};

describe("переход даты", () => {
  it("другой день — видно, что день другой, а не только час", () => {
    assert.equal(
      fmtDateTransition("2026-08-08T17:30:00", "2026-08-09T20:00:00"),
      "8 Avqust 17:30 → 9 Avqust 20:00",
    );
  });

  it("тот же день — дата не повторяется дважды", () => {
    assert.equal(
      fmtDateTransition("2026-08-08T17:30:00", "2026-08-08T20:00:00"),
      "8 Avqust, 17:30 → 20:00",
    );
  });

  it("то же время — время не повторяется дважды", () => {
    assert.equal(
      fmtDateTransition("2026-08-08T17:30:00", "2026-08-09T17:30:00"),
      "8 Avqust → 9 Avqust, 17:30",
    );
  });

  it("другой год печатается у обеих половин", () => {
    // Иначе «31 Dekabr → 1 Yanvar» скрыло бы самое существенное.
    assert.equal(
      fmtDateTransition("2026-12-31T23:59:00", "2027-01-01T00:05:00"),
      "31 Dekabr 2026 23:59 → 1 Yanvar 2027 00:05",
    );
  });

  it("самый длинный вариант помещается в баннер", () => {
    const longest = fmtDateTransition(
      "2026-12-31T23:59:00", "2027-01-01T00:05:00");
    const body = `Rafael tarixi dəyişdi: ${longest}`;
    // iOS показывает около двух строк тела до обрезания (~90 знаков).
    // Главное — обе даты — обязано уместиться целиком.
    assert.ok(body.length <= 90, `длина ${body.length}: ${body}`);
  });

  it("битая дата не роняет разбор — показываем хотя бы новое", () => {
    assert.equal(fmtDateTransition("мусор", "2026-08-09T20:00:00"),
      "9 Avqust 2026, 20:00");
  });
});

describe("что уходит второй стороне", () => {
  // ОБЫЧНЫЙ случай — новое предложение в чате, где раунд уже был. Живая
  // система работает во второй и последующие разы; «первый раз за всю
  // жизнь чата» случается однократно и проверяется отдельно ниже.
  it("новое предложение в чате, где раунд уже был", () => {
    const p = planOfferPushes({
      chatId: "c1",
      before: prevRound,
      after: base,
      members: MEMBERS,
      actorName: "Rafael",
    });
    assert.equal(p.length, 1);
    assert.equal(p[0].uid, RECIP);
    assert.equal(p[0].title, "Yeni iş təklifi");
    assert.equal(p[0].body,
      "Rafael sizə iş təklif etdi — Toy · 8 Avqust 2026, 17:30");
    assert.equal(p[0].data.chatId, "c1");
  });

  it("НЕ уходит автору: инициатор своё предложение не получает", () => {
    const p = planOfferPushes({
      chatId: "c1",
      before: prevRound,
      after: base,
      members: MEMBERS,
      actorName: "Rafael",
    });
    assert.equal(p.some((x) => x.uid === INIT), false);
  });


  it("первое предложение в истории чата — тот же результат", () => {
    // Отдельным тестом, а НЕ вместо обычного: пустое before это почти
    // всегда «первый раз за всю жизнь», и построенный из него тест
    // проверяет исключение, выдавая себя за правило.
    const p = planOfferPushes({
      chatId: "c1",
      before: { jobOfferBy: null, jobOfferAt: null },
      after: base,
      members: MEMBERS,
      actorName: "Rafael",
    });
    assert.equal(p.length, 1);
    assert.equal(p[0].title, "Yeni iş təklifi");
  });

  it("«Tarix dəyiş» — это изменение, а не новое предложение", () => {
    // saveChatEventDate не трогает jobOfferAt, поэтому признак не путает
    // два разных действия.
    const p = planOfferPushes({
      chatId: "c1",
      before: base,
      after: { ...base, eventDate: "2026-08-12T21:00:00.000" },
      members: MEMBERS,
      actorName: "Rafael",
    });
    assert.equal(p.length, 1);
    assert.equal(p[0].title, "Təklif dəyişdi");
  });

  it("смена даты — переход, а не только новое значение", () => {
    const p = pushOfferChanged(RECIP, "c1", "Rafael", base,
      { ...base, eventDate: "2026-08-09T20:00:00.000" });
    assert.equal(p.title, "Təklif dəyişdi");
    assert.equal(p.body, "Rafael tarixi dəyişdi: 8 Avqust 17:30 → 9 Avqust 20:00");
  });

  it("смена места — только новое значение, без «было»", () => {
    const p = pushOfferChanged(RECIP, "c1", "Rafael", base,
      { ...base, eventLocation: "Gülüstan" });
    assert.equal(p.body, "Rafael məkanı dəyişdi: Gülüstan");
  });

  it("отмена — второй стороне, а не отменившему", () => {
    const p = planOfferPushes({
      chatId: "c1",
      before: base,
      after: { ...base, jobOfferBy: null, cancelledBy: INIT },
      members: MEMBERS,
      actorName: "Rafael",
    });
    assert.equal(p.length, 1);
    assert.equal(p[0].uid, RECIP);
    assert.equal(p[0].title, "İş təklifi ləğv edildi");
  });

  it("НЕ уходит: согласие уже покрыто onChatUpdated", () => {
    assert.deepEqual(planOfferPushes({
      chatId: "c1",
      before: base,
      after: { ...base, recipientAgreed: true },
      members: MEMBERS,
      actorName: "Teymur",
    }), []);
  });

  it("НЕ уходит: в раунде ничего значимого не менялось", () => {
    assert.deepEqual(planOfferPushes({
      chatId: "c1", before: base, after: base,
      members: MEMBERS, actorName: "Rafael",
    }), []);
  });

  it("НЕ уходит: раунда нет вовсе", () => {
    assert.deepEqual(planOfferPushes({
      chatId: "c1",
      before: { jobOfferBy: null },
      after: { jobOfferBy: null, eventDate: "2026-08-08T17:30:00" },
      members: MEMBERS, actorName: "Rafael",
    }), []);
  });
});
