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
  eventDate: "2026-08-08T17:30:00.000",
  eventType: "Toy",
  eventLocation: "İnci qarayev",
  eventNotes: "Qalstuk",
  recipientAgreed: false,
  cancelledBy: null as string | null,
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
  it("предложение появилось — получателю, с предметом сделки", () => {
    const p = planOfferPushes({
      chatId: "c1",
      before: { jobOfferBy: null },
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
      before: { jobOfferBy: null },
      after: base,
      members: MEMBERS,
      actorName: "Rafael",
    });
    assert.equal(p.some((x) => x.uid === INIT), false);
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
