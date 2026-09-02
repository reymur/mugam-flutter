import assert from "node:assert";
import { generateKeyPairSync } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import {
  APNS_KEY_ID,
  APNS_TEAM_ID,
  APNS_VOIP_TOPIC,
  DEAD_APNS_REASONS,
  apnsHostFor,
  apnsJwt,
  buildApnsJwt,
  isDeadApnsReason,
  resetApnsJwtCache,
  voipPayloadFor,
} from "../src/voipPush";

// СТОРОЖ НА ОТПРАВКУ ЗВОНКА ЧЕРЕЗ PushKit (шаг 4).
//
// ПОЧЕМУ СТОРОЖ ЗДЕСЬ ВАЖНЕЕ ОБЫЧНОГО. Проверить эту работу глазами можно
// ровно одним способом — позвонить на смахнутую трубку, — и ответ у неё
// двоичный: зазвонило или нет. Всё, что между («ушло в ту среду?», «та ли
// тема?», «та ли форма подписи?»), при ошибке даёт ОДИН И ТОТ ЖЕ исход:
// тишину. APNs на промах не отвечает отказом в том смысле, в каком его
// заметил бы человек, — это уже измерено на этом проекте (N186, N191).
//
// Поэтому всё, что можно решить без сети, решается чистой функцией и
// сторожится здесь.
//
// ЧЕГО ЭТОТ СТОРОЖ НЕ ЛОВИТ (границы пишутся вместе со сторожем):
//   - он НЕ ходит в APNs и ничего не говорит о доставке. Годность ключа,
//     живость адреса и то, зазвонит ли телефон, проверяются только делом;
//   - он сверяет состав полей нагрузки с ТЕКСТОМ AppDelegate.swift, а не с
//     его поведением: переименование поля поймает, а перепутанные местами
//     два значения одного типа — нет;
//   - он ничего не знает про очерёдность двух путей отправки внутри
//     startCall — это отдельный вердикт ниже, и он тоже текстовый.

describe("среда APNs решается полем адреса, а не константой", () => {
  it("КАНАРЕЙКА: обе известные среды дают свой узел", () => {
    // Утверждение НАЛИЧИЯ, значит само себе канарейка (I31): ослепни разбор
    // — вернулся бы null, и вердикт покраснел бы здесь, а не в проде.
    assert.equal(apnsHostFor("sandbox"), "api.sandbox.push.apple.com");
    assert.equal(apnsHostFor("production"), "api.push.apple.com");
  });

  it("НЕИЗВЕСТНАЯ среда не подменяется правдоподобной (I50)", () => {
    // Главный вердикт всей тройки. Взять production «потому что обычно так»
    // означало бы отправку в никуда с видом работающего кода.
    for (const bad of ["unknown", "", "Sandbox", "prod", undefined, null, 7]) {
      assert.equal(apnsHostFor(bad), null, `среда ${String(bad)} прошла как известная`);
    }
  });

  it("узлы у сред РАЗНЫЕ — иначе поле ничего не решает", () => {
    assert.notEqual(apnsHostFor("sandbox"), apnsHostFor("production"));
  });
});

describe("мёртвый адрес APNs опознаётся причиной", () => {
  it("КАНАРЕЙКА: каждая причина из списка опознаётся", () => {
    assert.equal(DEAD_APNS_REASONS.length, 3);
    for (const r of DEAD_APNS_REASONS) {
      assert.equal(isDeadApnsReason(r), true, r);
    }
  });

  // ГЛАВНОЕ ОТРИЦАНИЕ, И ОНО ЖЕ ЦЕНА ОШИБКИ — тот же класс, что у
  // messaging/invalid-argument в push-delivery.test.ts.
  //
  // BadDeviceToken приходит в ДВУХ случаях: адрес мёртв ИЛИ мы промахнулись
  // средой. Отличить их по ответу APNs нельзя — ответ буквально один. Внеси
  // его в список, и первая же наша ошибка со средой снесёт ЖИВЫЕ адреса
  // всех адресатов разом, молча и необратимо. Адресов на 01.09 — 2 у 2
  // человек, то есть всех, у кого PushKit вообще есть.
  it("BadDeviceToken — НЕ смерть, потому что означает и промах средой", () => {
    assert.equal(isDeadApnsReason("BadDeviceToken"), false);
  });

  it("прочее — не смерть", () => {
    for (const r of ["TooManyProviderTokenUpdates", "InternalServerError", "", undefined]) {
      assert.equal(isDeadApnsReason(r), false, String(r));
    }
  });
});

describe("нагрузка VoIP-push'а", () => {
  const payload = voipPayloadFor({
    callkitUuid: "11111111-2222-3333-4444-555555555555",
    callId: "callDoc1",
    callerName: "Rafael",
    callType: "video",
  });

  it("состав полей ровно тот, что читает AppDelegate", () => {
    assert.deepEqual(
      Object.keys(payload).sort(),
      ["callId", "callType", "id", "nameCaller"],
    );
  });

  it("aps в нагрузке НЕТ — VoIP-push человеку не показывается", () => {
    assert.equal("aps" in payload, false);
  });

  describe("согласие с нативной стороной", () => {
    const swiftPath = path.resolve(__dirname, "../../ios/Runner/AppDelegate.swift");
    let swift = "";

    // КОД БЕЗ КОММЕНТАРИЕВ — ПРЕДОСТОРОЖНОСТЬ, А НЕ ПОЧИНКА ДЫРЫ, и это
    // разделение важнее самой строки.
    //
    // Отсечение заводилось под уверенность, что вердикты слепы: в этом файле
    // объяснение запрета состоит из тех же слов, что и запрет (I12), и
    // `showCallkitIncoming` встречается дважды — вызовом и в разборе.
    // ПОРЧА ЭТУ УВЕРЕННОСТЬ ОПРОВЕРГЛА: со снятым вызовом прежняя, «слепая»
    // форма вердикта покраснела так же. Замер объяснил почему — из восьми
    // строк, которые ищут вердикты ниже, в комментариях не встречается НИ
    // ОДНА (0 из 8): все они ищутся со скобкой либо со скобкой и кавычками,
    // а в разборе слова стоят голыми.
    //
    // Отсечение оставлено потому, что снимает ЗАВИСИМОСТЬ ОТ ПАМЯТИ: сейчас
    // верность держится на том, что каждый образец написан со скобкой, и
    // первый же вердикт, написанный без неё, станет слепым молча. Ошибкой
    // было не отсечение, а слово «починено» — оно превращало
    // предосторожность в найденную и закрытую находку (I46: порча проверяет
    // не только код, но и наше представление о том, что чем сторожится).
    let code = "";

    beforeAll(() => {
      assert.equal(fs.existsSync(swiftPath), true, "AppDelegate.swift пропал");
      swift = fs.readFileSync(swiftPath, "utf8");
      code = swift
        .split("\n")
        .filter((l) => !l.trimStart().startsWith("//"))
        .join("\n");
    });

    it("КАНАРЕЙКА: разбор видит заведомо существующее", () => {
      // Считает вхождения и называет число (I13), а не отвечает «да/нет» на
      // голое имя.
      // Число взято ЗАМЕРОМ по файлу (grep -c "pushRegistry" → 4), а не
      // назначено на глаз. Первая редакция считала didReceiveIncomingPushWith
      // и требовала двух — а он встречается ровно ОДИН раз, потому что имя
      // метода в Swift пишется единожды. Канарейка покраснела на исправном
      // файле: ровно I14, ложная тревога, и поймана она тем, что вывод
      // сверили с тем, каким он обязан быть НА ИСПРАВНОМ.
      const mentions = swift.split("pushRegistry").length - 1;
      assert.ok(mentions >= 3, `разбор нашёл ${mentions} упоминаний — он слеп`);
      assert.equal(
        swift.split("didReceiveIncomingPushWith").length - 1,
        1,
        "приём push'а объявлен не один раз — два делегата на один реестр",
      );
      assert.ok(swift.length > 2000, `файл длиной ${swift.length} — прочитан не он`);
      // Канарейка на само отсечение комментариев: срежь оно лишнего — и
      // вердикты ниже стали бы утверждать про пустоту.
      assert.ok(
        code.length > 1000,
        `кода без комментариев ${code.length} знаков — отсечение съело файл`,
      );
      assert.ok(
        code.length < swift.length,
        "отсечение комментариев не сработало вовсе",
      );
    });

    it("каждое поле нагрузки нативная сторона достаёт из push'а", () => {
      const missing = Object.keys(payload).filter(
        (k) => !code.includes(`body["${k}"]`),
      );
      assert.deepEqual(
        missing,
        [],
        `сервер кладёт поля, которых AppDelegate не читает: ${missing.join(", ")}`,
      );
    });

    // САМЫЙ ДОРОГОЙ ВЕРДИКТ ФАЙЛА: не сообщить о звонке в CallKit — значит
    // получить снятие приложения, а при повторах ПОЛНОЕ ОТКЛЮЧЕНИЕ доставки
    // VoIP-push'ей до переустановки.
    it("на приёме push'а есть отчёт в CallKit", () => {
      assert.ok(
        code.includes("showCallkitIncoming("),
        "приём push'а не отчитывается в CallKit — iOS снимет приложение",
      );
      assert.ok(
        code.includes("completion()"),
        "completion не зовётся — система сочтёт срок пропущенным",
      );
    });

    it("негодный идентификатор заменяется своим, а не роняет отчёт", () => {
      // Плагин на неразбираемом UUID молча НЕ отчитывается. Без замены это
      // ровно тот случай, за который снимают.
      assert.ok(
        code.includes("UUID(uuidString: pushedUuid) != nil"),
        "годность UUID не проверяется до отчёта",
      );
      assert.ok(
        code.includes("UUID().uuidString"),
        "негодный UUID ничем не заменяется — отчёта не будет",
      );
    });
  });
});

describe("ключ доступа к APNs", () => {
  // Настоящий .p8 в репозитории не лежит и лежать не должен; для сторожа
  // выписывается свой ключ той же кривой (P-256), что требует Apple.
  const { privateKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  }) as unknown as { privateKey: string };

  beforeEach(() => resetApnsJwtCache());

  it("состоит из трёх частей и называет наш ключ и нашу команду", () => {
    const jwt = buildApnsJwt(privateKey, 1_700_000_000);
    const parts = jwt.split(".");
    assert.equal(parts.length, 3);
    const header = JSON.parse(Buffer.from(parts[0], "base64url").toString());
    const claims = JSON.parse(Buffer.from(parts[1], "base64url").toString());
    assert.equal(header.alg, "ES256");
    assert.equal(header.kid, APNS_KEY_ID);
    assert.equal(claims.iss, APNS_TEAM_ID);
    assert.equal(claims.iat, 1_700_000_000);
  });

  // ТОНКОСТЬ, КОТОРАЯ ЛОМАЕТ ОТПРАВКУ МОЛЧА И ВЫГЛЯДИТ КАК «НЕ ТОТ КЛЮЧ».
  // По умолчанию node подписывает в DER — подпись переменной длины, около
  // 70 байт. Apple принимает только голые r‖s, ровно 64 байта, и на DER
  // отвечает InvalidProviderToken, то есть жалуется на ключ, а не на форму.
  it("подпись в форме ieee-p1363 — ровно 64 байта, а не DER", () => {
    const jwt = buildApnsJwt(privateKey, 1_700_000_000);
    const sig = Buffer.from(jwt.split(".")[2], "base64url");
    assert.equal(sig.length, 64, `подпись ${sig.length} байт — похоже на DER`);
  });

  // Apple отвечает TooManyProviderTokenUpdates, если выписывать чаще
  // примерно раза в 20 минут, и отказ приходит НЕ на первый звонок.
  it("ключ переиспользуется внутри окна и обновляется за ним", () => {
    const first = apnsJwt(privateKey, 1_000_000);
    assert.equal(apnsJwt(privateKey, 1_000_000 + 60), first, "ключ выписан заново");
    assert.notEqual(
      apnsJwt(privateKey, 1_000_000 + 60 * 60),
      first,
      "ключ не обновился за окном",
    );
  });
});

describe("проводка внутри startCall", () => {
  const indexPath = path.resolve(__dirname, "../src/index.ts");
  let src = "";

  beforeAll(() => {
    assert.equal(fs.existsSync(indexPath), true, "index.ts пропал");
    src = fs.readFileSync(indexPath, "utf8");
  });

  it("КАНАРЕЙКА: разбор видит startCall", () => {
    const mentions = src.split("startCall").length - 1;
    assert.ok(mentions >= 2, `разбор нашёл ${mentions} упоминаний — он слеп`);
  });

  /** Тело startCall, от объявления до следующего экспорта. */
  function startCallBody(): string {
    const from = src.indexOf("export const startCall = onCall(");
    assert.ok(from > 0, "startCall не найден");
    const to = src.indexOf("export const respondToCall", from);
    assert.ok(to > from, "конец startCall не найден");
    return src.slice(from, to);
  }

  it("КАНАРЕЙКА: тело startCall вырезано, а не пусто", () => {
    // Срез по именам-границам доказывает, что кусок ТОТ, и не доказывает,
    // что он целый (N104) — поэтому длина названа числом.
    const body = startCallBody();
    assert.ok(body.length > 500, `тело длиной ${body.length} — срез уехал`);
  });

  // СТАРЫЙ ПУТЬ ДЕРЖИМ — вердикт стоит здесь затем, чтобы его снятие было
  // решением, а не побочным следствием уборки. Снять FCM можно будет только
  // после проверки делом; до тех пор оба пути идут вместе.
  it("оба пути отправки зовутся: FCM И PushKit", () => {
    const body = startCallBody();
    assert.ok(body.includes("sendCallPushToUid("), "путь FCM снят");
    assert.ok(body.includes("sendVoipCallPushToUid("), "путь PushKit не подключён");
  });

  // ЭТО И ЕСТЬ ЗАЩИТА ОТ ДВОЙНОГО ОКНА, И ОНА ДЕРЖИТСЯ НА ОДНОМ: оба пути
  // несут ОДИН И ТОТ ЖЕ callkitUuid, выданный один раз. Выдай их два — и
  // CallKit покажет два окна на один звонок, потому что отказывает он
  // только на ПОВТОРНЫЙ уже занятый UUID.
  it("callkitUuid выдаётся ОДИН раз и уходит в оба пути", () => {
    const body = startCallBody();
    const generated = body.split("randomUUID()").length - 1;
    assert.equal(generated, 1, `randomUUID() зовётся ${generated} раз, а не 1`);
    assert.ok(body.includes("voipPayloadFor("), "нагрузка VoIP собирается не здесь");
  });

  it("секрет с ключом APNs объявлен у самой функции", () => {
    const body = startCallBody();
    assert.ok(
      body.includes("secrets: [apnsAuthKey]"),
      "ключ APNs не объявлен — apnsAuthKey.value() отдаст пустоту в проде",
    );
  });

  it("тема VoIP — это bundle id С СУФФИКСОМ .voip, а не bundle id", () => {
    assert.equal(APNS_VOIP_TOPIC, "com.mugam.mugamFlutter.voip");
    assert.notEqual(APNS_VOIP_TOPIC, "com.mugam.mugamFlutter");
  });
});
