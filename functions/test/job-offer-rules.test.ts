import fs from "fs";
import path from "path";
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, setDoc, updateDoc, getDoc, deleteDoc } from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// ПРЕДЛОЖЕНИЕ РАБОТЫ — ОТДЕЛЬНЫЙ ДОКУМЕНТ `chats/{chatId}/offers/{offerId}`
// (решение автора 13.08, разбор — docs/plan.md, работа 1).
//
// ПАРНО: у каждого разрешения свой запрет. Набор, проверяющий только
// «разрешено», не отличает работающее правило от правила, пропускающего всё.
//
// ЗАПРЕТЫ ЗДЕСЬ ГЛАВНЕЕ РАЗРЕШЕНИЙ, и три из них тише прочих:
//
//   • ДЕНЬ, КОТОРОГО В ПРЕДЛОЖЕНИИ НЕТ. Отметка «20-е» на предложении про
//     9–11-е ничего не ломает в тот же миг: она проходит молча и всплывает
//     при принятии, когда по ней создадут вечер на день, которого
//     работодатель не предлагал;
//   • `dates`, ПЕРЕПИСАННЫЕ ЗАДНИМ ЧИСЛОМ. Отметки, поставленные под старые
//     дни, после подмены молча означают согласие на новые: экран покажет
//     «согласен на 9-е», где человек соглашался совсем на другое;
//   • ЧУЖАЯ ОТМЕТКА. Подделывается не поступок, а рассказ о нём, и снаружи
//     подделка неотличима от правды — тот же класс, что N36 и N37.
//
// ЧЕГО ЭТОТ НАБОР НЕ ЛОВИТ, сказано вместе с ним: он молчит о том, ЧТО
// ПОКАЗЫВАЕТ ЭКРАН и КТО ПОЗОВЁТ эти ходы. Правило держит права, а не
// очерёдность решений в разметке — на неё сторожа в этом проекте нет вовсе
// (I32).
//
// ПРОГОН ТОЛЬКО ЧЕРЕЗ `emulators:exec`. Без эмулятора падает всё целиком,
// включая то, что обязано падать по своему устройству (`assertFails`), и
// читается это как «правило неверно» — зеркальный признак из CLAUDE.md.

const BOSS = "boss-uid";       // инициатор, он же работодатель
const PLAYER = "player-uid";   // музыкант
const STRANGER = "stranger-uid"; // не участник чата

const CHAT = "chat-offer";
const OFFER = "offer-1";
const OFFER_PATH = `chats/${CHAT}/offers/${OFFER}`;

const DAYS = ["2026-08-09", "2026-08-10", "2026-08-11"];

async function seedChat(env: RulesTestEnvironment) {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `chats/${CHAT}`), {
      members: [BOSS, PLAYER],
    });
  });
}

async function seedOffer(
  env: RulesTestEnvironment,
  over: Record<string, unknown> = {},
) {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), OFFER_PATH), {
      createdBy: BOSS,
      createdAt: "2026-08-13T10:00:00.000",
      anchorMessageId: "msg-1",
      dates: DAYS,
      eventType: "Toy",
      // ДЕТАЛИ У КАЖДОГО ДНЯ СВОИ (макет `mugam-14-secim`, 14.08). Прежде
      // здесь стояли три поля на всё предложение — eventTime,
      // eventLocation, eventNotes. Они остались в правилах ДОКУМЕНТА ЧАТА,
      // где держат предложения прежней схемы, но в подколлекции их нет.
      details: {},
      answers: {},
      ...over,
    });
  });
}

const newOffer = (over: Record<string, unknown> = {}) => ({
  createdBy: BOSS,
  createdAt: "2026-08-13T10:00:00.000",
  anchorMessageId: "msg-1",
  dates: DAYS,
  eventType: "Toy",
  details: {},
  answers: {},
  ...over,
});

describe("предложение работы: права на подколлекции offers", () => {
  const rulesPath = path.resolve(__dirname, "../../firestore.rules");
  const realRules = fs.readFileSync(rulesPath, "utf8");

  let env: RulesTestEnvironment;

  beforeAll(async () => {
    env = await initializeTestEnvironment({
      projectId: PROJECT_ID,
      firestore: {
        host: "localhost",
        port: FIRESTORE_EMULATOR_PORT,
        rules: realRules,
      },
    });
  });

  afterAll(async () => {
    await env?.cleanup();
  });

  beforeEach(async () => {
    await env.clearFirestore();
    await seedChat(env);
  });

  // ------------------------------------------------------------------
  // РАЗРЕШЕНО — семь
  // ------------------------------------------------------------------

  it("инициатор создаёт предложение на три дня", async () => {
    const db = env.authenticatedContext(BOSS).firestore();
    await assertSucceeds(setDoc(doc(db, OFFER_PATH), newOffer()));
  });

  // N127 — РОЛЬ ПРИНАДЛЕЖИТ ПРЕДЛОЖЕНИЮ, А НЕ ЧЕЛОВЕКУ, и записано это
  // здесь потому, что найдено этим самым набором.
  //
  // В разборе стояло «создание — только инициатор». Прогон показал, что
  // утверждение КРУГОВОЕ: инициатором становится тот, кто создал, и до
  // создания роли не существует вовсе. Запретить «музыканту создавать»
  // нечем — в чате нет ни работодателей, ни музыкантов, есть двое
  // участников, и позвать на работу может любой из них (так же было и у
  // прежнего `jobOfferBy` на документе чата: любой участник мог назвать им
  // себя).
  //
  // Тест оставлен разрешающим НАМЕРЕННО: он держит эту симметрию, чтобы
  // следующий не завёл роль на уровне чата, увидев в разборе слово
  // «инициатор». Роль живёт внутри одного предложения и кончается вместе
  // с ним.
  it("любой участник чата может позвать на работу — роль даёт предложение", async () => {
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertSucceeds(
      setDoc(doc(db, OFFER_PATH), newOffer({ createdBy: PLAYER })),
    );
  });

  it("музыкант отмечает два дня из трёх", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, OFFER_PATH), {
        answers: { [PLAYER]: ["2026-08-09", "2026-08-11"] },
      }),
    );
  });

  it("музыкант переотмечает, пока раунд открыт", async () => {
    await seedOffer(env, { answers: { [PLAYER]: ["2026-08-09"] } });
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, OFFER_PATH), {
        answers: { [PLAYER]: ["2026-08-10", "2026-08-11"] },
      }),
    );
  });

  // ПУСТОЙ СПИСОК — ЗАКОННЫЙ ОТВЕТ, А НЕ ОШИБКА И НЕ ОТСУТСТВИЕ ОТВЕТА.
  // Он означает «не могу ни на один день»: отдельного отказа в этой работе
  // нет, неотмеченные дни и значат «нет». Сказано здесь прямо, потому что
  // следующий, увидев пустой список в данных, primet его за недописанное
  // и «починит» — заведя проверку на непустоту, которая запретит человеку
  // ответить отказом.
  it("музыкант отмечает НОЛЬ дней — это ответ «не могу ни на один»", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, OFFER_PATH), { answers: { [PLAYER]: [] } }),
    );
  });

  it("инициатор принимает", async () => {
    await seedOffer(env, { answers: { [PLAYER]: ["2026-08-09"] } });
    const db = env.authenticatedContext(BOSS).firestore();
    await assertSucceeds(
      updateDoc(doc(db, OFFER_PATH), {
        acceptedBy: BOSS,
        acceptedAt: "2026-08-13T12:00:00.000",
      }),
    );
  });

  it("инициатор отзывает непринятое предложение", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(BOSS).firestore();
    await assertSucceeds(
      updateDoc(doc(db, OFFER_PATH), {
        withdrawnBy: BOSS,
        withdrawnAt: "2026-08-13T12:00:00.000",
      }),
    );
  });

  it("участник чата читает предложение", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertSucceeds(getDoc(doc(db, OFFER_PATH)));
  });

  // ------------------------------------------------------------------
  // ЗАПРЕЩЕНО — четырнадцать плюс два на закрытый раунд
  // ------------------------------------------------------------------

  it("посторонний не создаёт предложение в чужом чате", async () => {
    const db = env.authenticatedContext(STRANGER).firestore();
    await assertFails(
      setDoc(doc(db, OFFER_PATH), newOffer({ createdBy: STRANGER })),
    );
  });

  it("участник не создаёт предложение от чужого имени", async () => {
    const db = env.authenticatedContext(BOSS).firestore();
    await assertFails(
      setDoc(doc(db, OFFER_PATH), newOffer({ createdBy: PLAYER })),
    );
  });

  it("предложение не создаётся с уже проставленными отметками", async () => {
    const db = env.authenticatedContext(BOSS).firestore();
    await assertFails(
      setDoc(
        doc(db, OFFER_PATH),
        newOffer({ answers: { [PLAYER]: ["2026-08-09"] } }),
      ),
    );
  });

  // Три отдельных запрета вместо одного на всю форму. Ключи разные, и
  // разрешение у них тоже могло бы разойтись: один за всех доказывает
  // ровно про того одного, а про двух других — ничего (I13: сверять
  // состав, а не количество).
  it("музыкант не правит dates", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), { dates: ["2026-08-20"] }),
    );
  });

  it("музыкант не правит eventType", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(updateDoc(doc(db, OFFER_PATH), { eventType: "Nişan" }));
  });

  it("музыкант не правит eventTime", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(updateDoc(doc(db, OFFER_PATH), { eventTime: "21:00" }));
  });

  it("музыкант не правит eventLocation", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), { eventLocation: "Bakı" }),
    );
  });

  // САМЫЙ ТИХИЙ ИЗ ЗАПРЕТОВ СО СТОРОНЫ МУЗЫКАНТА.
  it("музыкант не отмечает день, которого нет в предложении", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), {
        answers: { [PLAYER]: ["2026-08-09", "2026-08-20"] },
      }),
    );
  });

  it("музыкант не пишет отметку за другого", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), {
        answers: { [BOSS]: ["2026-08-09"] },
      }),
    );
  });

  it("музыкант не стирает чужую отметку, оставляя свою", async () => {
    await seedOffer(env, {
      answers: { [PLAYER]: ["2026-08-09"], [STRANGER]: ["2026-08-10"] },
    });
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), {
        answers: { [PLAYER]: ["2026-08-09"] },
      }),
    );
  });

  it("музыкант не принимает", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), {
        acceptedBy: PLAYER,
        acceptedAt: "2026-08-13T12:00:00.000",
      }),
    );
  });

  it("музыкант не отзывает", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), {
        withdrawnBy: PLAYER,
        withdrawnAt: "2026-08-13T12:00:00.000",
      }),
    );
  });

  it("инициатор не правит отметки музыканта", async () => {
    await seedOffer(env, { answers: { [PLAYER]: ["2026-08-09"] } });
    const db = env.authenticatedContext(BOSS).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), {
        answers: { [PLAYER]: ["2026-08-09", "2026-08-10", "2026-08-11"] },
      }),
    );
  });

  // САМЫЙ ТИХИЙ ИЗ ЗАПРЕТОВ СО СТОРОНЫ ИНИЦИАТОРА — и он же тот, из-за
  // которого `dates` не назван НИ В ОДНОЙ из трёх форм правки.
  it("инициатор не переписывает dates после того, как музыкант отметился", async () => {
    await seedOffer(env, { answers: { [PLAYER]: ["2026-08-09"] } });
    const db = env.authenticatedContext(BOSS).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), {
        dates: ["2026-08-20", "2026-08-21", "2026-08-22"],
      }),
    );
  });

  it("предложение не удаляет ни одна из сторон", async () => {
    await seedOffer(env);
    const boss = env.authenticatedContext(BOSS).firestore();
    const player = env.authenticatedContext(PLAYER).firestore();
    await assertFails(deleteDoc(doc(boss, OFFER_PATH)));
    await assertFails(deleteDoc(doc(player, OFFER_PATH)));
  });

  it("посторонний не читает чужое предложение", async () => {
    await seedOffer(env);
    const db = env.authenticatedContext(STRANGER).firestore();
    await assertFails(getDoc(doc(db, OFFER_PATH)));
  });

  // --- закрытый раунд -------------------------------------------------

  it("после принятия отметки больше не принимаются", async () => {
    await seedOffer(env, {
      answers: { [PLAYER]: ["2026-08-09"] },
      acceptedBy: BOSS,
      acceptedAt: "2026-08-13T12:00:00.000",
    });
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), {
        answers: { [PLAYER]: ["2026-08-09", "2026-08-10"] },
      }),
    );
  });

  it("после отзыва отметки больше не принимаются", async () => {
    await seedOffer(env, {
      withdrawnBy: BOSS,
      withdrawnAt: "2026-08-13T12:00:00.000",
    });
    const db = env.authenticatedContext(PLAYER).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), {
        answers: { [PLAYER]: ["2026-08-09"] },
      }),
    );
  });

  // Отозвать принятое нельзя: вечера уже созданы, и отзыв после них
  // означал бы их снятие — другой ход с другими последствиями.
  it("принятое предложение не отзывается", async () => {
    await seedOffer(env, {
      acceptedBy: BOSS,
      acceptedAt: "2026-08-13T12:00:00.000",
    });
    const db = env.authenticatedContext(BOSS).firestore();
    await assertFails(
      updateDoc(doc(db, OFFER_PATH), {
        withdrawnBy: BOSS,
        withdrawnAt: "2026-08-13T13:00:00.000",
      }),
    );
  });
});

// ВЕРХНИЕ ПРЕДЕЛЫ НА СОЗДАНИЕ — ПЯТЬ ПРОВЕРОК, И ВСЕ ПЯТЬ ЗАВЕДЕНЫ 22.08,
// ДО ВЫКЛАДКИ ПРЕДЕЛОВ В ПРОД.
//
// **Почему без них выкладывать нельзя было честно.** Существующий тест
// «инициатор создаёт предложение на три дня» проходит ОДИНАКОВО с пределом
// и без него — он утверждает наличие разрешения, а нужен сторож отказа
// (I31). А на трубке отказ человеку не виден вовсе: `job_offer_entry.dart`
// закрывает лист ДО записи (`Navigator.pop()` первой строкой) и `catch` не
// ставит, поэтому «предел сработал» и «предел отбивает всё» выглядят
// одинаково — лист закрылся, в переписке ничего не появилось.
//
// **ГРАНИЦА ПРОВЕРЯЕТСЯ С ОБЕИХ СТОРОН — 31/32 и 24/25.** Только «32
// отбивается» не отличило бы предела в 31 от предела в 3; только «31
// проходит» не отличило бы предела от его отсутствия.
describe("предложение работы: верхние пределы на создание", () => {
  const rulesPath = path.resolve(__dirname, "../../firestore.rules");
  const realRules = fs.readFileSync(rulesPath, "utf8");

  // ТЕ САМЫЕ ДВЕ СТРОКИ, ДОСЛОВНО. Ниже из них собирается вторая редакция
  // правил — БЕЗ пределов, — и на ней отказные проверки обязаны
  // проваливаться. Это проверка возвратом, сделанная постоянной: она
  // доказывает, что отказ идёт ИМЕННО от этих строк, а не от чего-то
  // ещё в блоке создания.
  const LIMIT_DATES = "&& request.resource.data.dates.size() <= 31";
  const LIMIT_TYPE = "&& request.resource.data.eventType.size() <= 24";

  const days = (n: number) =>
    Array.from({ length: n }, (_, i) =>
      `2026-10-${String(i + 1).padStart(2, "0")}`,
    );

  let env: RulesTestEnvironment;
  let envNoLimits: RulesTestEnvironment;

  beforeAll(async () => {
    // ПОРЧА ПРОВЕРЯЕТСЯ НА МЕСТЕ, А НЕ НА ВЕРУ (I56). Не найдись образец —
    // замена прошла бы вхолостую, «правила без пределов» оказались бы
    // обычными правилами, и проверка возвратом молча подтвердила бы, что
    // всё в порядке. Поэтому здесь бросок, а не тихое `replace`.
    if (!realRules.includes(LIMIT_DATES) || !realRules.includes(LIMIT_TYPE)) {
      throw new Error(
        "в firestore.rules не найдены строки пределов дословно — " +
          "проверка возвратом ниже стала бы пустой",
      );
    }
    const noLimits = realRules
      .replace(LIMIT_DATES, "")
      .replace(LIMIT_TYPE, "");

    env = await initializeTestEnvironment({
      projectId: PROJECT_ID,
      firestore: {
        host: "localhost",
        port: FIRESTORE_EMULATOR_PORT,
        rules: realRules,
      },
    });
    envNoLimits = await initializeTestEnvironment({
      projectId: `${PROJECT_ID}-nolimits`,
      firestore: {
        host: "localhost",
        port: FIRESTORE_EMULATOR_PORT,
        rules: noLimits,
      },
    });
  });

  afterAll(async () => {
    await env?.cleanup();
    await envNoLimits?.cleanup();
  });

  beforeEach(async () => {
    await env.clearFirestore();
    await seedChat(env);
    await envNoLimits.clearFirestore();
    await seedChat(envNoLimits);
  });

  // КАНАРЕЙКА, И ОНА ЗЕЛЕНА КАК ДО ВЫКЛАДКИ, ТАК И ПОСЛЕ.
  //
  // Без неё «длинное отбивается» не отличалось бы от «отбивается всё»: на
  // трубке оба выглядят одинаково — лист закрылся, предложения нет. Здесь
  // же названо, что обычное предложение сегодняшнего вида проходит.
  // Замер прода 19.08: 14 предложений, тип «Toy» у 13.
  it("канарейка: обычное предложение — 3 дня, «Toy» — проходит", async () => {
    const db = env.authenticatedContext(BOSS).firestore();
    await assertSucceeds(setDoc(doc(db, OFFER_PATH), newOffer()));
  });

  it("31 день — граница, проходит", async () => {
    const db = env.authenticatedContext(BOSS).firestore();
    await assertSucceeds(
      setDoc(doc(db, OFFER_PATH), newOffer({ dates: days(31) })),
    );
  });

  it("32 дня — отбивается", async () => {
    const db = env.authenticatedContext(BOSS).firestore();
    await assertFails(
      setDoc(doc(db, OFFER_PATH), newOffer({ dates: days(32) })),
    );
  });

  it("тип работы в 24 знака — граница, проходит", async () => {
    const db = env.authenticatedContext(BOSS).firestore();
    await assertSucceeds(
      setDoc(doc(db, OFFER_PATH), newOffer({ eventType: "x".repeat(24) })),
    );
  });

  it("тип работы в 25 знаков — отбивается", async () => {
    const db = env.authenticatedContext(BOSS).firestore();
    await assertFails(
      setDoc(doc(db, OFFER_PATH), newOffer({ eventType: "x".repeat(25) })),
    );
  });

  // ------------------------------------------------------------------
  // ПРОВЕРКА ВОЗВРАТОМ, СДЕЛАННАЯ ПОСТОЯННОЙ — две
  // ------------------------------------------------------------------
  //
  // На правилах БЕЗ двух строк те же записи обязаны ПРОХОДИТЬ. Иначе два
  // отказных теста выше отбивают что-то другое — длину поля, состав
  // ключей, роль, — и к пределам отношения не имеют.
  //
  // Это ровно тот прогон, который иначе пришлось бы делать руками, правя
  // файл туда и обратно. Здесь он повторяем и не трогает `firestore.rules`
  // ни на секунду: вторая редакция собирается из ТОЙ ЖЕ прочитанной строки.

  it("без предела дней 32 дня проходят — значит отбивает именно предел", async () => {
    const db = envNoLimits.authenticatedContext(BOSS).firestore();
    await assertSucceeds(
      setDoc(doc(db, OFFER_PATH), newOffer({ dates: days(32) })),
    );
  });

  it("без предела длины тип в 25 знаков проходит — значит отбивает именно предел", async () => {
    const db = envNoLimits.authenticatedContext(BOSS).firestore();
    await assertSucceeds(
      setDoc(doc(db, OFFER_PATH), newOffer({ eventType: "x".repeat(25) })),
    );
  });
});
