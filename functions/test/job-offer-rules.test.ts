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
      eventTime: "",
      eventLocation: "",
      eventNotes: "",
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
  eventTime: "",
  eventLocation: "",
  eventNotes: "",
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
