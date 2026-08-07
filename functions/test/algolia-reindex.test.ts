import assert from "node:assert";
import fs from "fs";
import path from "path";
import {
  shouldReindexUser,
  ALGOLIA_LAST_SEEN_THROTTLE_MS,
} from "../src/algoliaShared";

// N43 — запись в Algolia на каждое сердцебиение присутствия.
//
// Присутствие пишет в users/{uid} `online` + `lastSeen` + `activeChatId`
// раз в 60 с у каждого, кто держит приложение открытым, а `onUserWritten`
// слал полную запись в индекс на любую запись в документ. Платили за
// сердцебиение, а не за изменение того, что ищут.
//
// Тесты ниже держат ИМЕННО различение: сердцебиение — нет, изменение
// содержимого — да. Наивное правило «сравнить индексируемые поля» этих
// тестов не пройдёт: `online` и `lastSeen` сами индексируемые, и
// присутствие пишет ровно их.

const ts = (ms: number) => ({ toMillis: () => ms });

const base = {
  name: "Rafael",
  city: "Bakı",
  activityInstruments: ["tar"],
  instrument: "tar",
  rating: 5,
  available: true,
  online: true,
  photoURL: null,
  emoji: "🎵",
  lastSeen: ts(1_000_000),
};

describe("shouldReindexUser — сердцебиение против содержимого (N43)", () => {
  it("одно сердцебиение внутри отрезка индекс не трогает", () => {
    const after = { ...base, lastSeen: ts(1_000_000 + 60_000) };
    assert.strictEqual(shouldReindexUser(base, after), false);
  });

  it("час непрерывного сердцебиения — шесть записей, а не шестьдесят", () => {
    // ГЛАВНАЯ проверка этой находки, и она же поймала дефект в первой
    // редакции правила. Триггер сравнивает СОСЕДНИЕ записи документа, а
    // не «последнее, что дошло до индекса»: между сердцебиениями всегда
    // 60 с, поэтому правило «уехал больше чем на 10 минут» не сработало
    // бы ни разу за час, и отметка застыла бы навсегда.
    //
    // Считается ровно то, за что платят: сколько записей в индекс даёт
    // час одного человека с открытым приложением.
    const beat = 60_000;
    const start = 1_000_000;
    let writes = 0;
    for (let i = 1; i <= 60; i++) {
      const before = { ...base, lastSeen: ts(start + (i - 1) * beat) };
      const after = { ...base, lastSeen: ts(start + i * beat) };
      if (shouldReindexUser(before, after)) writes++;
    }
    assert.strictEqual(
      writes,
      6,
      "час сердцебиения даёт не шесть записей в индекс — либо порог " +
        "перестал работать, либо отметка застыла и не доезжает вовсе",
    );
  });

  it("отставание отметки в индексе не превышает шага", () => {
    // Оборотная сторона той же проверки: экономия не должна превращаться
    // в «индекс не обновляется». Наибольший разрыв между записями за час
    // сердцебиения обязан укладываться в шаг.
    const beat = 60_000;
    const start = 1_000_000;
    let lastWrite = start;
    let maxGap = 0;
    for (let i = 1; i <= 60; i++) {
      const before = { ...base, lastSeen: ts(start + (i - 1) * beat) };
      const t = start + i * beat;
      if (shouldReindexUser(before, { ...base, lastSeen: ts(t) })) {
        maxGap = Math.max(maxGap, t - lastWrite);
        lastWrite = t;
      }
    }
    assert.ok(
      maxGap <= ALGOLIA_LAST_SEEN_THROTTLE_MS,
      `отметка отстаёт на ${maxGap} мс — больше обещанного шага`,
    );
  });

  it("`online` перевернулся — пишем, хотя lastSeen сдвинулся чуть-чуть", () => {
    // Выход из аккаунта: online: false и та же секунда. Без этого случая
    // человек оставался бы в поиске «в сети» до следующего срабатывания
    // порога.
    const after = { ...base, online: false, lastSeen: ts(1_000_030) };
    assert.strictEqual(shouldReindexUser(base, after), true);
  });

  it("сменилось имя — пишем", () => {
    assert.strictEqual(shouldReindexUser(base, { ...base, name: "Teymur" }), true);
  });

  it("сменился город — пишем", () => {
    assert.strictEqual(shouldReindexUser(base, { ...base, city: "Gəncə" }), true);
  });

  it("сменился набор инструментов — пишем (список сравнивается по значению)", () => {
    const after = { ...base, activityInstruments: ["tar", "kamança"] };
    assert.strictEqual(shouldReindexUser(base, after), true);
  });

  it("тот же набор в том же порядке — не пишем (иначе каждая запись — новая ссылка)", () => {
    const after = { ...base, activityInstruments: ["tar"] };
    assert.strictEqual(shouldReindexUser(base, after), false);
  });

  it("activeChatId не индексируется вовсе — переход между чатами индекс не трогает", () => {
    const after = { ...base, activeChatId: "chat-2", lastSeen: ts(1_000_030) };
    assert.strictEqual(shouldReindexUser({ ...base, activeChatId: "chat-1" }, after), false);
  });

  it("появление документа — пишем", () => {
    assert.strictEqual(shouldReindexUser(undefined, base), true);
  });

  it("удаление документа — пишем (иначе удалённый останется в поиске)", () => {
    assert.strictEqual(shouldReindexUser(base, undefined), true);
  });

  it("статус появился — пишем: без этого кольцо в подборе участников гаснет", () => {
    const after = { ...base, mostRecentStatusCreatedAt: ts(1_000_005) };
    assert.strictEqual(shouldReindexUser(base, after), true);
  });
});

describe("порог и окно поиска связаны (N57 — слой выше)", () => {
  // Починка триггера ломает СЛОЙ НАД НИМ: фильтр «Onlayn indi» уходит в
  // Algolia числовым условием `lastSeen > сейчас минус окно`. Если окно
  // ýже порога, индекс физически не может его удовлетворить, и фильтр
  // молча вернёт пустоту при полном зале онлайна. Тесты триггера этого
  // не видят — они про триггер.
  it("окно запроса в клиенте ШИРЕ порога переиндексации", () => {
    const models = fs.readFileSync(
      path.join(__dirname, "../../lib/firebase/models.dart"),
      "utf8",
    );
    const m = models.match(
      /onlineQueryWindow\s*=\s*Duration\(minutes:\s*(\d+)\)/,
    );
    assert.ok(
      m,
      "onlineQueryWindow больше не задаётся в минутах — проверь связь с порогом вручную",
    );
    const windowMs = Number(m![1]) * 60 * 1000;
    assert.ok(
      windowMs > ALGOLIA_LAST_SEEN_THROTTLE_MS,
      `окно поиска ${windowMs} мс не больше порога ${ALGOLIA_LAST_SEEN_THROTTLE_MS} мс — ` +
        "фильтр «Onlayn indi» перестанет находить кого бы то ни было",
    );
  });
});

describe("N44 — множитель триггеров на документ чата", () => {
  // Одно обновление документа чата поднимает СТОЛЬКО функций, сколько на
  // него подписано, и каждая читает документ. Число здесь запинено, чтобы
  // четвёртый триггер нельзя было завести молча.
  it("на chats/{chatId} ровно три onDocumentUpdated, и это те самые три", () => {
    const src = fs.readFileSync(path.join(__dirname, "../src/index.ts"), "utf8");
    // Объявления написаны ДВУМЯ способами — голой строкой и объектом
    // настроек. Первая редакция этой проверки знала только про объект и
    // насчитала один триггер из трёх: сторож, считающий не то, молчит
    // ровно так же, как сторож, которому нечего сказать (I9).
    //
    // Поэтому сверяются ИМЕНА, а не число: список имён нельзя недосчитать
    // незаметно — расхождение показывает, кого именно не хватает.
    const found = [
      ...src.matchAll(
        /export const (\w+) = onDocumentUpdated\(\s*(?:"chats\/\{chatId\}"|\{[^)]{0,200}?document:\s*"chats\/\{chatId\}")/g,
      ),
    ].map((m) => m[1]);
    assert.deepStrictEqual(
      [...found].sort(),
      ["onChatUpdated", "onJobOfferRoundChanged", "onJobOfferWaitingForDate"],
      "состав триггеров на документ чата изменился",
    );
    assert.strictEqual(
      found.length,
      3,
      "число триггеров на документ чата изменилось. Арифметика запаса: три " +
        "вызова на обновление, бесплатных вызовов 2 000 000 в месяц, то есть " +
        "≈22 000 обновлений документа чата в сутки. Четвёртый триггер " +
        "опускает запас до ≈16 000 — пересчитай вслух и обнови число здесь.",
    );
  });
});
