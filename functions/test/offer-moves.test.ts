import assert from "node:assert";
import {
  answeredBy,
  daysCount,
  planOfferMovePushes,
  type OfferDoc,
} from "../src/offerMoves";

// ХОДЫ ПРЕДЛОЖЕНИЯ — ПРАВИЛО (N130, шаг 4).
//
// Этот набор проверяет РАЗБОР: `planOfferMovePushes` с входом, который
// подаёт сам. На один вопрос он ответить не может — зовёт ли его `index.ts`
// так, как мы думаем, — и на него отвечает `offer-moves-live.test.ts`
// в эмуляторе. Разделение то же, что у `event-notifications` и
// `event-left-answers`, и по той же причине (N156, N160: тест подаёт то,
// отсутствие чего проверяет).

const BOSS = "boss-uid";
const PLAYER = "player-uid";
const MEMBERS = [BOSS, PLAYER];

function offer(over: Partial<OfferDoc> = {}): OfferDoc {
  return {
    createdBy: BOSS,
    dates: ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05"],
    eventType: "Toy",
    answers: {},
    ...over,
  };
}

function plan(before: OfferDoc, after: OfferDoc, actorName = "Teymur") {
  return planOfferMovePushes({
    chatId: "c1", before, after, members: MEMBERS, actorName,
  });
}

describe("ответ музыканта (N130, шаг 4)", () => {
  it("отмеченные дни — узнаёт инициатор, и только он", () => {
    const p = plan(offer(), offer({ answers: { [PLAYER]: ["2026-09-01", "2026-09-02", "2026-09-03"] } }), "Rafael");
    assert.equal(p.length, 1);
    assert.equal(p[0].uid, BOSS);
    assert.equal(p[0].title, "Cavab gəldi");
    assert.equal(p[0].body, "Rafael 3/5 gün seçdi");
    assert.equal(p[0].data.type, "job_offer_answered");
  });

  // ГЛАВНОЕ РАСЩЕПЛЕНИЕ ЭТОЙ ВЕТВИ, И ОНО НЕ КОСМЕТИЧЕСКОЕ.
  //
  // Ноль отмеченных — ОТКАЗ, а не ответ с количеством. «0/5 gün seçdi» было
  // бы верно по числу и неверно по смыслу: инициатор должен видеть разницу
  // между «он назвал три дня» и «он не может ни в один», не открывая чат.
  // Это пятое состояние строки ленты, и здесь оно то же самое.
  it("НОЛЬ отмеченных — отдельная новость, а не «ответил»", () => {
    const p = plan(offer(), offer({ answers: { [PLAYER]: [] } }), "Rafael");
    assert.equal(p.length, 1);
    assert.equal(p[0].uid, BOSS);
    assert.equal(p[0].body, "Rafael heç bir günə gələ bilmir");
    assert.equal(p[0].body.includes("0"), false,
      "ноль не называется числом — это отказ, а не счёт");
  });

  it("числа совпали — дроби нет", () => {
    const p = plan(
      offer({ dates: ["2026-09-01"] }),
      offer({ dates: ["2026-09-01"], answers: { [PLAYER]: ["2026-09-01"] } }),
      "Rafael",
    );
    assert.equal(p[0].body, "Rafael 1 gün seçdi");
  });

  it("ПЕРЕОТВЕТ считается ответом: отметки сменились", () => {
    // Переответ разрешён, пока раунд открыт («не устраивает — говорят
    // голосом, музыкант меняет отметки и шлёт снова»), и инициатор обязан
    // узнать о новом ответе так же, как о первом.
    const before = offer({ answers: { [PLAYER]: ["2026-09-01"] } });
    const after = offer({ answers: { [PLAYER]: ["2026-09-01", "2026-09-02"] } });
    const p = plan(before, after, "Rafael");
    assert.equal(p.length, 1);
    assert.equal(p[0].body, "Rafael 2/5 gün seçdi");
  });

  it("НЕ уходит: те же отметки записаны заново", () => {
    const same = offer({ answers: { [PLAYER]: ["2026-09-01"] } });
    assert.deepEqual(plan(same, same), []);
  });

  it("НЕ уходит автору: инициатор своего ответа не получает", () => {
    // Отвечать инициатор не вправе (правила), но если ключ поедет от
    // чужого писателя — Admin SDK, консоль (I49), — уведомление не должно
    // уйти ему же.
    const p = plan(offer(), offer({ answers: { [BOSS]: ["2026-09-01"] } }));
    assert.deepEqual(p, []);
  });
});

describe("принятие (N130, шаг 4)", () => {
  it("узнаёт музыкант, и число дней — его отмеченные", () => {
    const before = offer({ answers: { [PLAYER]: ["2026-09-01", "2026-09-02"] } });
    const after = { ...before, acceptedBy: BOSS, acceptedAt: "2026-09-01T10:00:00" };
    const p = plan(before, after, "Teymur");
    assert.equal(p.length, 1);
    assert.equal(p[0].uid, PLAYER);
    assert.equal(p[0].title, "Təklif qəbul edildi");
    assert.equal(p[0].body, "Teymur təklifi qəbul etdi — 2 gün");
    assert.equal(p[0].data.type, "job_offer_accepted");
  });

  it("ВЕДЁТ В ЧАТ, а не в вечер: несёт chatId и не несёт eventId", () => {
    // Решение владельца 30.08. Вечеров создаётся несколько, и уведомление
    // привело бы к одному из них либо к списку — ни то ни другое не
    // отвечает на «что произошло».
    const before = offer({ answers: { [PLAYER]: ["2026-09-01"] } });
    const p = plan(before, { ...before, acceptedBy: BOSS });
    assert.equal(p[0].data.chatId, "c1");
    assert.equal(p[0].data.eventId, undefined);
  });

  it("НЕ уходит: принятие уже стояло, документ тронули иначе", () => {
    const accepted = offer({ acceptedBy: BOSS, answers: { [PLAYER]: ["2026-09-01"] } });
    assert.deepEqual(plan(accepted, { ...accepted, eventType: "Konsert" }), []);
  });
});

describe("отзыв (N130, шаг 4)", () => {
  it("узнаёт музыкант", () => {
    const p = plan(offer(), offer({ withdrawnBy: BOSS }), "Teymur");
    assert.equal(p.length, 1);
    assert.equal(p[0].uid, PLAYER);
    assert.equal(p[0].title, "İş təklifi geri götürüldü");
    assert.equal(p[0].body, "Teymur iş təklifini geri götürdü");
    assert.equal(p[0].data.type, "job_offer_withdrawn");
  });

  // ОТЗЫВ ДО ОТВЕТА — ТОТ СЛУЧАЙ, РАДИ КОТОРОГО ЧИТАЕТСЯ СОСТАВ ЧАТА.
  //
  // `answers` пуст, значит uid музыканта в документе предложения нет ни
  // одного, и взять адресата больше неоткуда.
  it("отзыв ДО ответа доходит: адресат берётся из состава чата", () => {
    const p = plan(offer({ answers: {} }), offer({ answers: {}, withdrawnBy: BOSS }));
    assert.equal(p.length, 1);
    assert.equal(p[0].uid, PLAYER);
  });

  // ЭТОТ СЛУЧАЙ ДОПИСАН ПО ПРОВЕРКЕ ВОЗВРАТОМ 30.08, И БЕЗ НЕЁ ЕГО БЫ НЕ
  // БЫЛО.
  //
  // Заменив признак ПЕРЕХОДА на признак СОСТОЯНИЯ — `!before.withdrawnBy &&
  // !!after.withdrawnBy` на просто `!!after.withdrawnBy`, — я не уронил НИ
  // ОДНОГО теста из четырёхсот. Соседние случаи подставляли `before` без
  // отзыва, и до различия разбор не доходил.
  //
  // Разница видна только здесь: у отозванного предложения документ ещё
  // трогают (правила это позволяют владельцу — `roundOpen()` закрывает
  // отметки и принятие, но не всякую запись), и признак-состояние слал бы
  // «geri götürüldü» на каждую такую запись. Человек получал бы отзыв
  // одного и того же предложения снова и снова.
  //
  // У принятия ровно этот случай уже стоял («принятие уже стояло, документ
  // тронули иначе»), у отзыва — не стоял. Тот же класс, что нашёлся 09.08 у
  // `unsettledAfterMemberLeft`: пара ветвей, у одной случай есть, у второй
  // забыт.
  it("НЕ уходит: отзыв уже стоял, документ тронули иначе", () => {
    const withdrawn = offer({ withdrawnBy: BOSS });
    assert.deepEqual(plan(withdrawn, { ...withdrawn, eventType: "Konsert" }), []);
  });

  it("слово НЕ «ləğv edildi»: это другой поступок", () => {
    // `pushOfferCancelled` старой схемы говорит «ləğv edildi». Строка ленты
    // у отзыва печатает «geri götürüldü», и назвать один поступок двумя
    // словами значит заставить человека решить, что случились два разных.
    const p = plan(offer(), offer({ withdrawnBy: BOSS }));
    assert.equal(p[0].body.includes("ləğv"), false);
  });
});

describe("что НЕ порождает уведомления", () => {
  it("документ не менялся", () => {
    assert.deepEqual(plan(offer(), offer()), []);
  });

  it("создателя нет вовсе — разбор молчит, а не падает", () => {
    const o = offer({ createdBy: null });
    assert.deepEqual(plan(o, { ...o, withdrawnBy: BOSS }), []);
  });

  it("состав пуст — слать некому", () => {
    assert.deepEqual(planOfferMovePushes({
      chatId: "c1", before: offer(), after: offer({ withdrawnBy: BOSS }),
      members: [], actorName: "Teymur",
    }), []);
  });
});

describe("канарейки к отрицаниям выше", () => {
  // Пять отрицаний в этом файле утверждают ОТСУТСТВИЕ, и без соседок,
  // утверждающих наличие, «ничего не уходит» и «разбор не работает вовсе»
  // дают один и тот же зелёный вывод (I31, I14).
  it("КАНАРЕЙКА: каждая из трёх ветвей хоть раз даёт письмо", () => {
    const answered = plan(offer(), offer({ answers: { [PLAYER]: ["2026-09-01"] } }));
    const accepted = plan(offer(), offer({ acceptedBy: BOSS }));
    const withdrawn = plan(offer(), offer({ withdrawnBy: BOSS }));
    assert.equal(answered.length, 1, "ветвь ответа молчит");
    assert.equal(accepted.length, 1, "ветвь принятия молчит");
    assert.equal(withdrawn.length, 1, "ветвь отзыва молчит");
    // И три разных типа: схлопнись разбор в один ответ, отрицания выше
    // остались бы зелёными.
    const types = new Set([answered, accepted, withdrawn].map((p) => p[0].data.type));
    assert.equal(types.size, 3, "три ветви дали не три разных типа");
  });

  it("признак автора: `answeredBy` находит сдвинутый ключ", () => {
    assert.equal(answeredBy({ answers: {} }, { answers: { [PLAYER]: [] } }), PLAYER);
    assert.equal(
      answeredBy({ answers: { [PLAYER]: ["a"] } }, { answers: { [PLAYER]: ["b"] } }),
      PLAYER,
    );
    assert.equal(
      answeredBy({ answers: { [PLAYER]: ["a"] } }, { answers: { [PLAYER]: ["a"] } }),
      null,
    );
  });

  it("счёт дней: дробь только там, где числа разные", () => {
    assert.equal(daysCount(3, 5), "3/5");
    assert.equal(daysCount(1, 1), "1");
    assert.equal(daysCount(0, 5), "0/5");
  });
});
