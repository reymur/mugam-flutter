import fs from "fs";
import path from "path";
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
  deleteField,
  serverTimestamp,
} from "firebase/firestore";
import { PROJECT_ID, FIRESTORE_EMULATOR_PORT } from "./helpers";

// ПРАВИЛО «УЧАСТНИК ОТВЕЧАЕТ ЗА СЕБЯ» — шаг 4, пункт 1 (`docs/plan.md`).
//
// ПАРНО, а не по одному разрешению: набор, проверяющий только «разрешено»,
// не отличает работающее правило от правила, которое пропускает вообще всё.
// Поэтому у каждого `assertSucceeds` здесь есть свой `assertFails`, и
// запреты — главная половина файла, а не довесок.
//
// ЧТО ИМЕННО СТОРОЖИТСЯ, если читать список запретов сверху вниз: участник
// не должен мочь ответить за другого, тронуть этим ходом состав, дату или
// статус, отвечать после выхода из состава — и не должен мочь ОТМЕНИТЬ САМ
// ФАКТ ВОПРОСА, стерев свой ключ или записав в него мусор.

const OWNER = "owner-uid";
const GUEST = "guest-uid";
const OTHER = "other-uid";
const STRANGER = "stranger-uid";
const EVENT = "ev-answers";

async function seed(
  env: RulesTestEnvironment,
  answers: Record<string, unknown> | undefined,
  musicians: string[] = [OWNER, GUEST, OTHER],
) {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `personalEvents/${EVENT}`), {
      ownerUid: OWNER,
      musicians,
      date: "2026-09-01T19:00:00.000",
      type: "Toy",
      location: "",
      notes: "",
      isAgree: false,
      status: "agreed",
      ...(answers === undefined ? {} : { answers }),
    });
  });
}

describe("шаг 4: участник отвечает за себя, и только за себя", () => {
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
  });

  // ------------------------------------------------------------------
  // РАЗРЕШЕНО
  // ------------------------------------------------------------------

  it("участник ставит «иду»", async () => {
    await seed(env, { [GUEST]: "waiting", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
      }),
    );
  });

  it("участник ставит «не могу»", async () => {
    await seed(env, { [GUEST]: "waiting", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "cant",
      }),
    );
  });

  it("участник меняет свой ответ второй раз подряд", async () => {
    // Ответ не приколочен: передумать можно, и это не отдельный поступок.
    await seed(env, { [GUEST]: "going", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "cant",
      }),
    );
  });

  it("у СТАРОГО документа без карты участник отвечает впервые", async () => {
    // 75 записей прода живут без поля `answers` вовсе. Первый ответ в таком
    // документе создаёт карту — и это законный ход, а не обход.
    await seed(env, undefined);
    const db = env.authenticatedContext(GUEST).firestore();
    await assertSucceeds(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "cant",
      }),
    );
  });

  // ------------------------------------------------------------------
  // ЗАПРЕЩЕНО — по одному запрету на каждое разрешение выше и сверх того
  // ------------------------------------------------------------------

  it("НЕЛЬЗЯ ответить за другого", async () => {
    await seed(env, { [GUEST]: "waiting", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${OTHER}`]: "going",
      }),
    );
  });

  it("НЕЛЬЗЯ написать свой и чужой ключ ОДНОЙ записью", async () => {
    // Главный случай: «свой» рядом с чужим выглядит законным ходом.
    await seed(env, { [GUEST]: "waiting", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
        [`answers.${OTHER}`]: "going",
      }),
    );
  });

  it("НЕЛЬЗЯ этим ходом сдвинуть дату", async () => {
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
        date: "2026-09-02T19:00:00.000",
      }),
    );
  });

  it("НЕЛЬЗЯ этим ходом тронуть состав", async () => {
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
        musicians: [OWNER, GUEST],
      }),
    );
  });

  it("НЕЛЬЗЯ этим ходом отменить вечер", async () => {
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
        status: "cancelled",
      }),
    );
  });

  it("НЕЛЬЗЯ приписать этому ходу ИМЯ ПОСТУПКА", async () => {
    // Ход выглядит безобидным: свой ключ на месте, чужого нет. Но
    // `lastActionType` — это РАССКАЗ о случившемся, и сервер верит ему без
    // проверки: по нему он решает, кого известить и какими словами. Дать
    // участнику ставить его вместе с ответом значило бы дать ему выдать
    // ответ за уход, отмену или возврат в силу.
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "going",
        lastActionType: "left",
        lastActionBy: GUEST,
      }),
    );
  });

  // ОБХОД ЧЕРЕЗ ОТСУТСТВИЕ — два запрета, один класс.
  //
  // `answerOf` читает пустоту и мусор ОДИНАКОВО: как `notAsked`, то есть «его
  // не спрашивали». Значит обе дороги ведут к одному — участник отменяет сам
  // факт вопроса, и выглядит это не как отказ, а как будто его не звали.

  it("НЕЛЬЗЯ стереть свой ключ — это подделка «меня не спрашивали»", async () => {
    await seed(env, { [GUEST]: "going", [OTHER]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: deleteField(),
      }),
    );
  });

  it("НЕЛЬЗЯ записать незнакомую строку — та же подделка другим путём", async () => {
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "нечто",
      }),
    );
  });

  it("НЕЛЬЗЯ записать notAsked — оно И ЕСТЬ отсутствие ключа", async () => {
    await seed(env, { [GUEST]: "waiting" });
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "notAsked",
      }),
    );
  });

  it("НЕЛЬЗЯ отвечать в вечере, где тебя нет в составе", async () => {
    await seed(env, { [GUEST]: "waiting" }, [OWNER, GUEST]);
    const db = env.authenticatedContext(STRANGER).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${STRANGER}`]: "going",
      }),
    );
  });

  it("УШЕДШИЙ не может ответить после выхода", async () => {
    // Его ключ в карте остался — `leavesEvent` (снято 30.08) к `answers` не
    // пускало. Но `isParty()` его больше не признаёт, и вся ветка ему закрыта.
    await seed(env, { [GUEST]: "going" }, [OWNER, OTHER]);
    const db = env.authenticatedContext(GUEST).firestore();
    await assertFails(
      updateDoc(doc(db, `personalEvents/${EVENT}`), {
        [`answers.${GUEST}`]: "cant",
      }),
    );
  });

  // ------------------------------------------------------------------
  // СТАНДАРТНЫЙ ПУТЬ ПРИГЛАШЕНИЯ — позванный становится участником ТОГО ЖЕ
  // вечера (17.09, закон о договоре, шаг 1)
  // ------------------------------------------------------------------
  // ЗАЧЕМ ЭТИ ВЕРДИКТЫ СУЩЕСТВУЮТ. Шаг 1 выложен БЕЗ выкладки правил, и
  // основанием тому было ЧТЕНИЕ правил, а не замер: ветвь владельца в
  // `allow update` перечисления ключей не имеет, `namesCancelDeed()` запрещает
  // четыре имени отмены, `edited` среди них нет. Чтение — не доказательство
  // (закон переписывания, шаг 2), поэтому здесь оно заменено прогоном.
  //
  // НАБОР ПРАВИЛ БЕРЁТСЯ ИЗ ФАЙЛА `firestore.rules`, И ЭТО ТОТ ЖЕ ТЕКСТ, ЧТО
  // ЖИВЁТ В ПРОДЕ. Проверено 17.09 живым снимком через Rules API: набор
  // `759f4a64-…` против файла — **0 расходящихся строк при 1629**, канарейкой
  // тот же `diff` против предыдущего набора `af22ba3c-…` — **145 строк**.
  // Значит зелёный ниже означает «выкладка не нужна», а не «у нас локально
  // сходится».
  //
  // ПАРНО, как и весь файл: у каждого разрешения — свой запрет. Проверка
  // «владельцу можно» в одиночку не отличила бы работающее правило от
  // правила, пропускающего всё.
  describe("зов своих: позванный — участник того же вечера", () => {
    // Ровно та карта, что пишет `FirestoreService.callPeopleToEvent`. Список
    // ключей здесь — не украшение: правило судит по `changedKeys()`, и лишний
    // ключ меняет вердикт, а недостающий делает прогон проверкой другого хода.
    const callPayload = (extra: Record<string, unknown> = {}) => ({
      musicians: [OWNER, GUEST, OTHER, STRANGER],
      [`answers.${STRANGER}`]: "waiting",
      answersWrittenByOwner: true,
      lineup: [{ uid: STRANGER, name: "Səid", invited: true, reason: null }],
      lastActionBy: OWNER,
      lastActionType: "edited",
      lastActionAt: serverTimestamp(),
      ...extra,
    });

    it("ВЛАДЕЛЕЦ ЗОВЁТ: состав, ответы, шаблон и подпись — одной записью", async () => {
      await seed(env, { [GUEST]: "waiting", [OTHER]: "waiting" });
      const db = env.authenticatedContext(OWNER).firestore();
      await assertSucceeds(
        updateDoc(doc(db, `personalEvents/${EVENT}`), callPayload()),
      );
    });

    it("ПОЗВАННЫЙ ОТВЕЧАЕТ waiting→going НА ТОМ ЖЕ ВЕЧЕРЕ", async () => {
      // ГЛАВНЫЙ ВЕРДИКТ ВСЕЙ РАБОТЫ. Прежде позванный отвечал в СВОЁМ
      // документе, где владельцем был зовущий; теперь — в общем, где владелец
      // тот же, а состав чужой. Правило `answersForSelf()` не менялось, и
      // вопрос ровно один: пускает ли оно его здесь.
      await seed(env, { [GUEST]: "waiting", [STRANGER]: "waiting" }, [
        OWNER,
        GUEST,
        STRANGER,
      ]);
      const db = env.authenticatedContext(STRANGER).firestore();
      await assertSucceeds(
        updateDoc(doc(db, `personalEvents/${EVENT}`), {
          [`answers.${STRANGER}`]: "going",
        }),
      );
    });

    it("позванный отвечает «не могу» и «вышел» — тем же ходом", async () => {
      // Уход из вечера — это ответ человека, а не поступок над документом
      // (N121). У позванного он обязан работать так же, как у любого другого
      // участника: иначе выйти из чужого вечера станет нечем.
      await seed(env, { [STRANGER]: "waiting" }, [OWNER, STRANGER]);
      const db = env.authenticatedContext(STRANGER).firestore();
      await assertSucceeds(
        updateDoc(doc(db, `personalEvents/${EVENT}`), {
          [`answers.${STRANGER}`]: "cant",
        }),
      );
      await assertSucceeds(
        updateDoc(doc(db, `personalEvents/${EVENT}`), {
          [`answers.${STRANGER}`]: "left",
        }),
      );
    });

    it("ПОЗВАННЫЙ ЧИТАЕТ ВЕЧЕР ЦЕЛИКОМ — он в составе, значит `isParty()`", async () => {
      // Это и есть расширение видимости, названное владельцу до работы
      // (решение 17.09): позванный видит состав, чужие ответы и шаблон.
      // Вердикт стоит затем, чтобы расширение было ЗАПИСАНО прогоном, а не
      // только словами: молчаливое согласие выглядит как согласие со
      // стандартным (I69).
      await seed(env, { [STRANGER]: "waiting" }, [OWNER, GUEST, STRANGER]);
      const db = env.authenticatedContext(STRANGER).firestore();
      await assertSucceeds(getDoc(doc(db, `personalEvents/${EVENT}`)));
    });

    // --- ЗАПРЕТЫ: у каждого разрешения выше свой ---

    it("ЗАПРЕТ: непозванный посторонний вечер не читает", async () => {
      // Канарейка к вердикту чтения выше: зелёный там — про состав, а не про
      // то, что документ открыт всем подряд.
      await seed(env, { [GUEST]: "waiting" }, [OWNER, GUEST]);
      const db = env.authenticatedContext(STRANGER).firestore();
      await assertFails(getDoc(doc(db, `personalEvents/${EVENT}`)));
    });

    it("ЗАПРЕТ: зов не может назваться именем отмены", async () => {
      // `namesCancelDeed()` — единственное, что ветвь владельца запрещает по
      // имени. Ошибись имя здесь — зов получал бы отказ по правам, и человек
      // видел бы «не ушло никому» без объяснения.
      await seed(env, { [GUEST]: "waiting" });
      const db = env.authenticatedContext(OWNER).firestore();
      await assertFails(
        updateDoc(
          doc(db, `personalEvents/${EVENT}`),
          callPayload({ lastActionType: "cancelRequested" }),
        ),
      );
    });

    it("ЗАПРЕТ: зов не может тронуть повод состояния", async () => {
      // `serverOwnsUnsettledReason()` запрещает поле клиенту ЦЕЛИКОМ, включая
      // владельца: по нему `restoresEvent()` решает, открывать ли выход
      // наверх.
      await seed(env, { [GUEST]: "waiting" });
      const db = env.authenticatedContext(OWNER).firestore();
      await assertFails(
        updateDoc(
          doc(db, `personalEvents/${EVENT}`),
          callPayload({ unsettledReason: "memberLeft" }),
        ),
      );
    });

    it("ЗАПРЕТ: зов не может подписаться чужим именем", async () => {
      // `stampsSelf()`. Сервер берёт из `lastActionBy` автора уведомления и
      // доверяет ему без проверки (I54) — подделай его, и «{Ad} sizi tədbirə
      // əlavə etdi» назовёт не того человека.
      await seed(env, { [GUEST]: "waiting" });
      const db = env.authenticatedContext(OWNER).firestore();
      await assertFails(
        updateDoc(
          doc(db, `personalEvents/${EVENT}`),
          callPayload({ lastActionBy: OTHER }),
        ),
      );
    });

    it("ЗАПРЕТ: позванный не может позвать дальше — состав не его", async () => {
      // Он участник, а не владелец: `answersForSelf()` пускает ровно
      // `answers`, и `musicians` через него не пройдёт.
      await seed(env, { [STRANGER]: "waiting" }, [OWNER, STRANGER]);
      const db = env.authenticatedContext(STRANGER).firestore();
      await assertFails(
        updateDoc(doc(db, `personalEvents/${EVENT}`), {
          musicians: [OWNER, STRANGER, GUEST],
          [`answers.${GUEST}`]: "waiting",
        }),
      );
    });
  });

  // ------------------------------------------------------------------
  // ЗОВ ВЫШЕДШЕГО — решение владельца 17.09
  // ------------------------------------------------------------------
  // ПОВОД, СЛОВАМИ ВЛАДЕЛЬЦА: Рафаэль видит вышедшего и жмёт «позвать» — это
  // естественное действие. Приложение молчит, ошибки нет, объяснения нет. Он
  // думает, что позвал, а человек ничего не получил, и узнают об этом на
  // свадьбе. Что надо сперва удалить, а потом звать, нигде не сказано и само
  // по себе странно: зачем удалять того, кого зовёшь.
  //
  // ЧТО ЭТИ ВЕРДИКТЫ ПРОВЕРЯЮТ И ЧЕГО НЕ ПРОВЕРЯЮТ. Они про ПРАВА, и только:
  // пропускают ли выложенные правила переход `left → waiting`, сделанный
  // владельцем, и уносит ли он причину той же рукой. Они НЕ говорят, что зов
  // это делает — кода ещё нет. Прогнаны ДО кода нарочно: если правила
  // откажут, работа пойдёт иначе, и узнать это надо раньше, а не после.
  //
  // НАБОР ПРАВИЛ — ТОТ ЖЕ ТЕКСТ, ЧТО В ПРОДЕ: `git hash-object firestore.rules`
  // → `7c8cbbaf…`, совпадает с выложенным (замер 17.09, живой набор
  // `759f4a64…` побайтно равен файлу).
  describe("зов вышедшего: владелец возвращает его в ожидание", () => {
    it("ВЛАДЕЛЕЦ ПЕРЕВОДИТ left → waiting", async () => {
      // ГЛАВНЫЙ ВЕРДИКТ. Ветвь владельца в `allow update` перечисления ключей
      // не имеет; запрещены ей только имена отмены и повод состояния. Значит
      // перезапись карты ответов ему открыта — та же дорога, какой идёт
      // обычная правка состава.
      await seed(env, { [GUEST]: "left", [OTHER]: "going" });
      const db = env.authenticatedContext(OWNER).firestore();
      await assertSucceeds(
        updateDoc(doc(db, `personalEvents/${EVENT}`), {
          [`answers.${GUEST}`]: "waiting",
          answersWrittenByOwner: true,
          lastActionBy: OWNER,
          lastActionType: "edited",
          lastActionAt: serverTimestamp(),
        }),
      );
    });

    it("ВЛАДЕЛЕЦ УНОСИТ ПРИЧИНУ ВЫХОДА того, кого зовёт заново", async () => {
      // Устаревшая причина под заново позванным — ложь на экране: человек
      // сказал «не могу» про прошлый раз, а висит она под новым вопросом.
      // Правило `allow delete` в подколлекции даёт это ровно владельцу вечера.
      await seed(env, { [GUEST]: "left" });
      await env.withSecurityRulesDisabled(async (context) => {
        await setDoc(
          doc(context.firestore(), `personalEvents/${EVENT}/leaveNotes/${GUEST}`),
          { text: "не могу в этот раз", hasVoice: true },
        );
      });
      const db = env.authenticatedContext(OWNER).firestore();
      await assertSucceeds(
        deleteDoc(doc(db, `personalEvents/${EVENT}/leaveNotes/${GUEST}`)),
      );
    });

    it("ЗАПРЕТ: участник не возвращает в ожидание ЧУЖОЙ выход", async () => {
      // Пара к первому вердикту. Без неё «владельцу можно» не отличить от
      // «можно всем», и вердикт выше не значил бы ничего.
      await seed(env, { [GUEST]: "left", [OTHER]: "going" });
      const db = env.authenticatedContext(OTHER).firestore();
      await assertFails(
        updateDoc(doc(db, `personalEvents/${EVENT}`), {
          [`answers.${GUEST}`]: "waiting",
        }),
      );
    });

    it("ЗАПРЕТ: участник не уносит ЧУЖУЮ причину выхода", async () => {
      // Пара ко второму. Причину стирает владелец — крестиком либо зовом;
      // сосед по составу к ней не подходит вовсе.
      await seed(env, { [GUEST]: "left", [OTHER]: "going" });
      await env.withSecurityRulesDisabled(async (context) => {
        await setDoc(
          doc(context.firestore(), `personalEvents/${EVENT}/leaveNotes/${GUEST}`),
          { text: "не могу", hasVoice: true },
        );
      });
      const db = env.authenticatedContext(OTHER).firestore();
      await assertFails(
        deleteDoc(doc(db, `personalEvents/${EVENT}/leaveNotes/${GUEST}`)),
      );
    });
  });
});
