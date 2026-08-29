import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ОТВЕТ УЧАСТНИКА — шаг 1 работы «договоры и мероприятия — одна сущность»
// (`docs/plan.md`).
//
// ЧТО ЗДЕСЬ ПРОВЕРЯЕТСЯ И ПОЧЕМУ ИМЕННО ЭТО. На шаге 1 поле НИКТО НЕ ЧИТАЕТ:
// оно пишется рядом с `musicians` и на поведение не влияет ничем. Значит
// проверять поведение нечего — проверяется ЗАПИСЬ: какой `answers`
// соответствует какому составу, и что читатель, когда он появится, поймёт
// старые записи так же, как новые.
//
// ПРОВЕРКА ВОЗВРАТОМ (I10, правкой на месте, не через git) — проделана
// 10.08, и имена упавших записаны ПО ФАКТУ, а не по замыслу:
//
//   • `kAnswerGoing` → `kAnswerWaiting` — падают ТРИ: «все, кто в составе, —
//     идут», «повтор в списке не даёт двух ключей» и «ключи answers
//     совпадают с musicians ПОИМЁННО» в event_edit_test;
//   • убрать `if (uid.isEmpty) continue` — падает ОДНА: «пустой uid не
//     человек»;
//   • в `answerOf` убрать `participantUids.contains(uid)` — падает ОДНА:
//     «ключ вне состава не считается».
//
// ПЕРВОНАЧАЛЬНО ЗДЕСЬ БЫЛО НАПИСАНО ДРУГОЕ, и это стоит оставить записанным.
// Обещалось, что от первой порчи упадёт «правка ведёт ответы за составом» —
// она НЕ упала: та проверка смотрит только на ключи, а порча меняет
// значения. То есть предсказание было правдоподобным и неверным, и разошлось
// оно ровно в ту сторону, в какую опаснее — я считал покрытие шире, чем оно
// есть. Проверка возвратом на то и нужна: она называет, что на самом деле
// сторожит эти строки, а не что мы думали, когда их писали.

void main() {
  group('шаг 1 · какой answers соответствует составу', () {
    test('ШАГ 4: новым ставится «ждём», а не «идёт»', () {
      // До шага 4 здесь стояло `going` у всех, и это было верно: добавление
      // и означало согласие. С шага 4 добавление — приглашение.
      expect(answersForParticipants(const ['a', 'b'], previousParticipants: null), {
        'a': 'waiting',
        'b': 'waiting',
      });
    });

    test('ШАГ 4: прежний ответ переносится, а не стирается правкой', () {
      // Иначе первая же правка места объявила бы ответивших заново ждущими:
      // человек сказал «не могу», владелец поправил адрес — ответ пропал.
      // Ответ принадлежит человеку, а не документу.
      final out = answersForParticipants(
        const ['a', 'b', 'c'],
        previous: const {'a': 'cant', 'b': 'going'},
        previousParticipants: null,
      );
      expect(out, {'a': 'cant', 'b': 'going', 'c': 'waiting'});
    });

    test('ШАГ 4: незнакомый прежний ответ НЕ наследуется', () {
      // Чужая строка — мусор, а не ответ (I49: значение гарантирует не поле,
      // а писатель, и писателей у документа было трое). Наследовать её
      // значило бы разносить порчу по документу.
      //
      // ГРАНИЦА, ИЗМЕРЕННАЯ ПОРЧЕЙ 11.08 (I46): сама по себе эта проверка
      // СЛАБА. Отключи перенос целиком — она останется зелёной, потому что
      // ждёт `waiting`, а отключённый перенос даёт `waiting` всем. Она не
      // отличает «мусор не унаследован» от «не переносится ничего».
      //
      // Её пара — «прежний ответ переносится» выше: та падает от такой
      // порчи. Врозь они не значат ничего, вместе закрывают обе стороны.
      // Предсказание перед порчей было «упадут три», упали две — промах в
      // сторону завышенного покрытия, и вот его причина.
      final out = answersForParticipants(
        const ['a', 'b'],
        previous: const {'a': 'нечто', 'b': 'cant'},
        previousParticipants: null,
      );
      // Знакомый ответ рядом с мусором — так проверка различает случаи сама.
      expect(out, {'a': 'waiting', 'b': 'cant'});
    });

    test('N112: владелец в составе получает «идёт», а не «ждём»', () {
      // Владелец согласия не даёт — он вечер создал. У договоров он лежит в
      // составе (`onChatUpdated` кладёт обе стороны), и без этого различения
      // правка состава спрашивала бы его, идёт ли он туда, куда сам позвал.
      final out = answersForParticipants(
        const ['owner', 'guest'],
        ownerUid: 'owner',
        previousParticipants: null,
      );
      expect(out, {'owner': 'going', 'guest': 'waiting'});
    });

    test('N112: СОБСТВЕННЫЙ ответ владельца переносится, а не затирается', () {
      // Умолчание владельца — «идёт», но не безусловная запись «идёт».
      // Когда у владельца появится своя дверь выхода (N108), безусловное
      // значение стирало бы его ответ при каждой правке места — ровно тот
      // дефект, от которого перенос и заводился.
      final out = answersForParticipants(
        const ['owner', 'guest'],
        previous: const {'owner': 'cant'},
        ownerUid: 'owner',
        previousParticipants: null,
      );
      expect(out, {'owner': 'cant', 'guest': 'waiting'});
    });

    test('N112: владельца не назвали — прежнее поведение, ждут все', () {
      // Пустой `ownerUid` не совпадает ни с одним uid состава, потому что
      // пустые из состава отброшены. Отдельной ветки на это нет, и проверка
      // стоит, чтобы её не завели «на всякий случай».
      expect(answersForParticipants(const ['a', 'b'], previousParticipants: null), {
        'a': 'waiting',
        'b': 'waiting',
      });
    });

    test('N114: ВЫШЕДШИЙ, приглашённый заново, отвечает ЗАНОВО', () {
      // Его ключ остался в карте после выхода — `leavesEvent` к `answers` не
      // пускает. Без учёта прежнего состава прежний `going` переносится
      // поверх выхода, и человек возвращается согласившимся, ничего не
      // нажимая. Выход — самое сильное «нет», какое участник может сказать.
      final out = answersForParticipants(
        const ['guest'],
        previous: const {'guest': 'going'},
        previousParticipants: const ['someone-else'],
      );
      expect(out, {'guest': 'waiting'});
    });

    test('N114: НЕ уходивший свой ответ сохраняет', () {
      // Вторая половина того же правила, и без неё первая ничего не значит:
      // «всем waiting» тоже прошло бы проверку выше.
      final out = answersForParticipants(
        const ['guest', 'other'],
        previous: const {'guest': 'going', 'other': 'cant'},
        previousParticipants: const ['guest', 'other'],
      );
      expect(out, {'guest': 'going', 'other': 'cant'});
    });

    // N173 — ДВА НЕЗНАНИЯ ПОД ОДНИМ ОТВЕТОМ, И ЛЕЧЕНИЯ У НИХ ПРОТИВОПОЛОЖНЫЕ.
    //
    // До 28.08 прежний состав приходил `List<String>` с умолчанием `const []`,
    // и пустота значила «не знаем» — переносим. Но пустым он бывает и по
    // ДРУГОЙ причине: из состава вышел последний участник. Тогда перенос
    // возвращал согласие, которого человек не давал.
    //
    // Доказательство было документом прода: `pcop3dUyviw2v28AZKmb` —
    // `musicians` пусто, `answers: Rafael = going`. Согласие лежало у того,
    // кого в составе нет.
    //
    // Две проверки ниже — пара, и врозь ни одна ничего не значит: первая
    // прошла бы и на «переносим всегда», вторая — на «сбрасываем всегда».
    test('N173: состав БЫЛ ПУСТ — согласие НЕ воскресает', () {
      final out = answersForParticipants(
        const ['guest'],
        previous: const {'guest': 'going'},
        previousParticipants: const [],
      );
      expect(out, {'guest': 'waiting'});
    });

    test('N173: состав НЕИЗВЕСТЕН — ответ переносится', () {
      // Старый документ, чужой писатель, вызывающий без сведений. Сбрось мы
      // здесь — правка места объявила бы ждущими всех разом, и починка стала
      // бы дефектом шире исходного.
      final out = answersForParticipants(
        const ['guest'],
        previous: const {'guest': 'going'},
        previousParticipants: null,
      );
      expect(out, {'guest': 'going'});
    });

    test('N173: тот же вход, разные ответы — значит различие живо', () {
      // Соседка к паре выше (I31): она утверждает НАЛИЧИЕ различия и падает,
      // если `null` и `[]` снова сольются в один ответ — как они и были слиты
      // до 28.08.
      const people = ['guest'];
      const prev = {'guest': 'going'};
      expect(
        answersForParticipants(people, previous: prev, previousParticipants: null),
        isNot(answersForParticipants(people,
            previous: prev, previousParticipants: const [])),
      );
    });

    test('N114: прежний состав НЕ НАЗВАН — переносим по-старому', () {
      // Пустой список означает «сведений нет», а не «никого не было». Иначе
      // правка от вызывающего, который прежний состав не передал, объявила бы
      // ждущими всех разом — починка N114 стала бы дефектом шире исходного.
      final out = answersForParticipants(
        const ['guest'],
        previous: const {'guest': 'going'},
        previousParticipants: null,
      );
      expect(out, {'guest': 'going'});
    });

    test('состав ключей — РОВНО musicians, ни больше ни меньше', () {
      // Состав, а не количество (I13). Лишний ключ — ответ за того, кого в
      // составе нет; недостающий — участник без ответа, то есть дырка,
      // которую следующий читатель заполнит догадкой.
      final out = answersForParticipants(const ['x', 'y', 'z'], previousParticipants: null);
      expect(out.keys.toSet(), {'x', 'y', 'z'});
    });

    test('пустой состав даёт пустую карту, а не null и не отсутствие', () {
      expect(answersForParticipants(const [], previousParticipants: null), isEmpty);
    });

    test('пустой uid не человек — ключа из него не делается', () {
      // Ключ из пустой строки — запись, которую некому сопоставить.
      expect(answersForParticipants(const ['a', '', 'b'], previousParticipants: null).keys.toSet(),
          {'a', 'b'});
    });

    test('повтор в списке не даёт двух ключей', () {
      expect(answersForParticipants(const ['a', 'a'], previousParticipants: null), {'a': 'waiting'});
    });

    test('значения — только из известного набора', () {
      final out = answersForParticipants(const ['a', 'b', 'c'], previousParticipants: null);
      for (final v in out.values) {
        expect(kEventAnswers.contains(v), isTrue, reason: 'чужое значение $v');
      }
    });
  });

  group('шаг 2 · КРУГОВАЯ: чтение сходится с записью', () {
    // ПОЧЕМУ КРУГОВАЯ, А НЕ ПРИМЕР. Обычная проверка сверяет вывод с тем,
    // что мы ОЖИДАЛИ, — то есть с нашим же представлением, и удачный пример
    // проходит её, ничего не доказав. Здесь сверяются друг с другом ЗАПИСЬ
    // и ЧТЕНИЕ: `answersForParticipants` кладёт, `answerOf` достаёт, и
    // разойтись они могут только по-настоящему. Ожидание в этой проверке не
    // участвует вовсе, и подогнать её под себя нечем.
    //
    // ЧЕГО ОНА СЕГОДНЯ НЕ ЛОВИТ — измерено порчей 10.08, а не оценено
    // (I46: перед порчей названо, что упадёт; предсказание сошлось).
    // Заставил `answerOf` игнорировать карту целиком — **круговая осталась
    // зелёной**. Причина в данных, а не в проверке: на шагах 1–2 записанное
    // значение ОДНО на всех, `going`, и «взял из карты» неотличимо от
    // «вернул умолчание». Упала только соседка «ответ из карты берётся как
    // есть» — та, где в карте стоит `cant`.
    //
    // **Круговая станет сильной на шаге 4**, когда появятся `waiting` и
    // `cant`: тогда игнорирование карты разойдётся с записью на первом же
    // человеке. До тех пор она сторожит СОСТАВ ключей, а не значения, и
    // полагаться на неё шире нельзя.
    void roundTrip(List<String> people) {
      final written =
          answersForParticipants(people, previousParticipants: null);
      for (final uid in people.where((u) => u.isNotEmpty)) {
        expect(
          answerOf(uid: uid, participantUids: people, answers: written),
          written[uid],
          reason: 'чтение разошлось с записью на $uid при составе $people',
        );
      }
    }

    test('один человек', () => roundTrip(const ['a']));
    test('двое', () => roundTrip(const ['a', 'b']));
    test('пятеро', () => roundTrip(const ['a', 'b', 'c', 'd', 'e']));
    test('с повтором', () => roundTrip(const ['a', 'a', 'b']));
    test('с пустым uid', () => roundTrip(const ['a', '', 'b']));
    test('пустой состав — сверять нечего, и это не отказ', () {
      expect(answersForParticipants(const [], previousParticipants: null), isEmpty);
    });
  });

  group('шаг 2 · расхождение записи с составом — для переписи, не для экрана', () {
    test('поля НЕТ — это не расхождение, а отсутствие сведений', () {
      // Так писали до шага 1, так пишет mugam-v2, так пишут старые сборки.
      final m = answersMismatch(participantUids: const ['a', 'b']);
      expect(m.isClean, isTrue);
      expect(m.emptyWithPeople, isFalse);
    });

    test('карта ПУСТА при непустом составе — расхождение, и тревожное', () {
      // Ни один известный писатель так не делает: и клиент, и сервер пишут
      // карту целиком по составу. Значит это противоречие, а не незнание.
      final m = answersMismatch(
        participantUids: const ['a', 'b'],
        answers: const {},
      );
      expect(m.emptyWithPeople, isTrue);
      expect(m.missing, ['a', 'b']);
      expect(m.isClean, isFalse);
    });

    test('пустая карта при пустом составе — согласие, а не расхождение', () {
      final m = answersMismatch(participantUids: const [], answers: const {});
      expect(m.isClean, isTrue);
      expect(m.emptyWithPeople, isFalse);
    });

    test('НЕДОСТАЧА: в составе есть, в карте нет — ожидаемо (шаг 3)', () {
      // Источники названы заранее: старые сборки и mugam-v2 правят состав,
      // не зная про поле. На шаге 3 это не находка, а ожидаемое.
      final m = answersMismatch(
        participantUids: const ['a', 'b'],
        answers: const {'a': 'going'},
      );
      expect(m.missing, ['b']);
      expect(m.extra, isEmpty);
      expect(m.emptyWithPeople, isFalse);
    });

    test('ИЗБЫТОК: ключ вне состава — ожидаемо от выхода из состава', () {
      // `leavesEvent()` разрешает трогать только `musicians`, `lastActionBy`
      // и `lastActionType`; ключ ушедшего в карте остаётся.
      final m = answersMismatch(
        participantUids: const ['a'],
        answers: const {'a': 'going', 'ушедший': 'going'},
      );
      expect(m.extra, ['ушедший']);
      expect(m.missing, isEmpty);
    });

    test('своя же запись расхождения не даёт — при любом составе', () {
      for (final people in const [
        <String>[],
        ['a'],
        ['a', 'b'],
        ['a', 'a', 'b'],
        ['a', '', 'b'],
      ]) {
        final m = answersMismatch(
          participantUids: people,
          answers:
              answersForParticipants(people, previousParticipants: null),
        );
        expect(m.isClean, isTrue, reason: 'состав $people');
      }
    });
  });

  group('шаг 3 · модель отдаёт ОТВЕТ, а не карту', () {
    // Событие строится через `fromFirestore`, а не конструктором, и это не
    // прихоть теста: поле и параметр приватны (`_answers`), значит передать
    // карту снаружи `models.dart` НЕЛЬЗЯ вовсе. Единственная дорога внутрь —
    // документ, ровно как в проде.
    // Сторожевой объект, а не `null`: нам нужно различать «поля нет» и
    // «поле есть и равно null», а `null` сам по себе этого не умеет —
    // тот же I47, только в сигнатуре теста.
    //
    // И не `Symbol`: `#нет` не собирается вовсе — имена в Dart обязаны быть
    // ASCII (проверено этим заходом, ошибка компиляции). Тот же
    // ASCII-предрассудок, что в I16, третьим носителем.
    const absent = Object();
    PersonalEvent make({
      required List<String> musicians,
      Object? answers = absent,
      // N115: отметка «карту заполнял тот, кто пишет её целиком». Идёт через
      // документ, а не параметром модели, — тем же путём, что в проде.
      bool writtenByOwner = false,
    }) =>
        PersonalEvent.fromFirestore('id', {
          'ownerUid': 'owner',
          'musicians': musicians,
          if (!identical(answers, absent)) 'answers': answers,
          'answersWrittenByOwner': writtenByOwner,
        });

    test('карта наружу не отдаётся — у модели её нет в открытом виде', () {
      // Проверяется составом открытого API: если поле когда-нибудь станет
      // публичным, эта проверка не заметит, а вот компилятор соседей —
      // заметит. Здесь же утверждается то, что проверить можно: модель
      // отвечает МЕТОДОМ.
      final e = make(musicians: const ['a']);
      expect(e.answerFor('a'), 'going');
    });

    test('поля нет — человек в составе идёт (75 записей прода)', () {
      expect(make(musicians: const ['a', 'b']).answerFor('b'), 'going');
    });

    test('ответ из карты доходит как есть', () {
      final e = make(
        musicians: const ['a'],
        answers: const {'a': 'cant'},
      );
      expect(e.answerFor('a'), 'cant');
    });

    test('не в составе — null, даже если ключ в карте есть', () {
      final e = make(
        musicians: const ['a'],
        answers: const {'ушедший': 'going'},
      );
      expect(e.answerFor('ушедший'), isNull);
    });

    test('ШАГ 4: пустая карта при непустом составе — «не спрашивали»', () {
      // До шага 4 пустая карта и отсутствие поля давали ОДИН ответ, и это
      // было решением (I47: различать в данных, не различать в ответе). С
      // шага 4 они дают разные ответы, потому что различие стало
      // содержательным: нет поля — старый документ, все идут; поле есть и
      // пусто — карту писали, а человека в неё не внесли.
      // N115: пустая карта говорит «в составе никого» только если её писал
      // тот, кто пишет целиком. Пустая карта без отметки — след писателя,
      // который про состав ничего не утверждал.
      final e = make(
          musicians: const ['a'], answers: const {}, writtenByOwner: true);
      expect(e.answerFor('a'), 'notAsked');
    });

    test('ШАГ 4: у документа без карты модель отдаёт «идёт»', () {
      final e = make(musicians: const ['a', 'b']);
      expect(e.answerFor('a'), 'going');
      expect(e.answerFor('b'), 'going');
    });
  });

  group('шаг 1 · чтение, которое появится на шаге 3', () {
    test('поля нет — человек в составе читается как «идёт»', () {
      // Запасной путь обязателен и переживёт шаг 1: у 75 записей прода поля
      // нет вовсе (перепись 10.08), и появится оно только у тех, что создадут
      // или правят после выкладки. Читать их иначе значило бы показать один
      // и тот же вечер с двумя разными ответами.
      expect(answerOf(uid: 'a', participantUids: const ['a', 'b']), 'going');
    });

    test('ответ из карты берётся как есть', () {
      expect(
        answerOf(
          uid: 'a',
          participantUids: const ['a'],
          answers: const {'a': 'cant'},
        ),
        'cant',
      );
    });

    test('КЛЮЧ ВНЕ СОСТАВА НЕ СЧИТАЕТСЯ — решение 10.08, не находка', () {
      // Вышедший из состава свой ключ в карте ОСТАВЛЯЕТ: правило
      // `leavesEvent()` разрешает трогать только `musicians`, `lastActionBy`
      // и `lastActionType`, а `answers` в этот набор не входит. Значит
      // лишний ключ — мусор, и спрашивать надо сначала состав.
      expect(
        answerOf(
          uid: 'ушедший',
          participantUids: const ['a'],
          answers: const {'ушедший': 'going', 'a': 'going'},
        ),
        isNull,
      );
    });

    test('ШАГ 4: карта есть, ключа нет — «не спрашивали», а не «идёт»', () {
      // ТА САМАЯ СТРОКА, с которой назад дороги нет. До шага 4 это читалось
      // как going, потому что карта писалась целиком и недостача означала
      // старую сборку; с шага 4 недостача означает «человека добавил тот,
      // кто про ответы не знает» — то есть его НЕ СПРАШИВАЛИ.
      // ПОПРАВЛЕНО 11.08 ПО N115: одной карты для этого мало. «Ключа нет»
      // значит «не спрашивали» только тогда, когда карту заполнял тот, кто
      // пишет её ЦЕЛИКОМ по составу. Без отметки та же карта могла быть
      // начата участником — и тогда про остальных она не говорит ничего.
      expect(
        answerOf(
          uid: 'b',
          participantUids: const ['a', 'b'],
          answers: const {'a': 'going'},
          answersWrittenByOwner: true,
        ),
        'notAsked',
      );
    });

    test('«не спрошен» и «ждём» — РАЗНЫЕ (N99 в данных, I47)', () {
      // У них разный адресат следующего хода: у первого действовать должен
      // владелец (позвать), у второго — приглашённый (ответить).
      final notAsked = answerOf(
        uid: 'b',
        participantUids: const ['a', 'b'],
        answers: const {'a': 'going'},
        answersWrittenByOwner: true,
      );
      final waiting = answerOf(
        uid: 'b',
        participantUids: const ['a', 'b'],
        answers: const {'a': 'going', 'b': 'waiting'},
        answersWrittenByOwner: true,
      );
      expect(notAsked, isNot(waiting));
      expect(notAsked, 'notAsked');
      expect(waiting, 'waiting');
    });

    test('незнакомое значение — «не спрашивали», и чтение не падает', () {
      // Мусор читается как отсутствие ключа — значит и здесь решает отметка
      // (N115). Без неё то же значение прочтётся как «идёт», и это проверено
      // отдельно в группе N115.
      expect(
        answerOf(
          uid: 'a',
          participantUids: const ['a'],
          answers: const {'a': 'нечто'},
          answersWrittenByOwner: true,
        ),
        'notAsked',
      );
    });

    test('значение не строки — то же самое', () {
      expect(
        answerOf(
            uid: 'a',
            participantUids: const ['a'],
            answers: const {'a': 7},
            answersWrittenByOwner: true),
        'notAsked',
      );
    });

    test('СТАРЫЕ 75 ДОКУМЕНТОВ НЕ ТРОНУТЫ: карты нет — все идут', () {
      // Главная гарантия шага 4. Задним числом никого в ждущие не переводим:
      // у 75 записей прода карты нет вовсе, и для них «в составе» по-прежнему
      // значит «идёт». Сломай это — и все прежние составы разом станут
      // неподтверждёнными.
      expect(answerOf(uid: 'a', participantUids: const ['a', 'b']), 'going');
      expect(answerOf(uid: 'b', participantUids: const ['a', 'b']), 'going');
    });
  });

  // N115 — ПЕРЕКЛЮЧАТЕЛЬ ЧИТАЕТ ПИСАТЕЛЯ, А НЕ НАЛИЧИЕ КАРТЫ.
  //
  // Три строки таблицы из `answerOf`, и каждая своим тестом. Средняя — самая
  // дорогая: сломай её, и 73 документа без карты (замер прода 11.08) задним
  // числом переведутся из согласившихся в ждущие.
  group('N115: что значит «ключа нет» — решает, кто заполнял карту', () {
    test('ключ ЕСТЬ — читается его значение, отметка ни при чём', () {
      for (final mark in [true, false]) {
        expect(
          answerOf(
            uid: 'a',
            participantUids: const ['a', 'b'],
            answers: const {'a': 'cant'},
            answersWrittenByOwner: mark,
          ),
          'cant',
          reason: 'отметка $mark не должна менять прочтение своего ключа',
        );
      }
    });

    test('СРЕДНЯЯ СТРОКА: ключа нет, отметки нет — «идёт», а не «не спрошен»',
        () {
      // Ровно случай N115: карту начал участник своим ответом, и про
      // остальных она не утверждает ничего. Для них верен старый смысл.
      expect(
        answerOf(
          uid: 'owner',
          participantUids: const ['owner', 'guest'],
          answers: const {'guest': 'cant'},
        ),
        'going',
      );
    });

    test('ключа нет, отметка СТОИТ — «не спрошен»', () {
      // Карту заполнял владелец, она полна по составу, значит человека в неё
      // не включили намеренно.
      expect(
        answerOf(
          uid: 'newcomer',
          participantUids: const ['owner', 'newcomer'],
          answers: const {'owner': 'going'},
          answersWrittenByOwner: true,
        ),
        'notAsked',
      );
    });

    test('карты нет вовсе — отметка не спасает и не мешает', () {
      // Первая строка старше всех: нет карты — нет и разговора о том, кто её
      // заполнял. Проверяется с отметкой, потому что документ без карты, но с
      // отметкой — это порча, и читаться она обязана безопасно.
      expect(
        answerOf(
          uid: 'a',
          participantUids: const ['a'],
          answersWrittenByOwner: true,
        ),
        'going',
      );
    });

    test('МУСОР в своём ключе читается как отсутствие ключа, по обеим дорогам',
        () {
      expect(
        answerOf(
          uid: 'a',
          participantUids: const ['a'],
          answers: const {'a': 7},
        ),
        'going',
        reason: 'без отметки мусор не должен объявлять человека неспрошенным',
      );
      expect(
        answerOf(
          uid: 'a',
          participantUids: const ['a'],
          answers: const {'a': 7},
          answersWrittenByOwner: true,
        ),
        'notAsked',
      );
    });
  });

  // ШАГ 4, ПУНКТ 2 — ПОКАЗ СОСТАВА.
  //
  // Проверка утверждает НАЛИЧИЕ («такой ответ называется так»), значит она
  // сама себе канарейка и соседки не требует (I31): ослепни она — ярлыки
  // станут пустыми, и она покраснеет в тот же заход.
  group('шаг 4 · показ состава различает ПЯТЬ ответов', () {
    // ЗАГОЛОВОК ГОВОРИЛ «четыре», А СОСТОЯНИЙ ПЯТЬ — поправлено 29.08 при
    // шаге 2 работы N121 (`AUDIT_TODO.md`). Это I39 в чистом виде: шапка
    // утверждает про весь набор, а проверялись четыре из пяти, и пятое —
    // `left` — не упоминалось во всём файле ни разу
    // (`grep -c "kAnswerLeft" test/event_answers_test.dart` давало 0).
    // Пятое при этом не «новое»: константа заведена 12.08, ярлык написан
    // тогда же. Не хватало не кода, а доказательства.
    test('у каждого ответа своё слово, и все пять РАЗНЫЕ', () {
      final labels = <String>[
        participantAnswerLabel(kAnswerGoing),
        participantAnswerLabel(kAnswerWaiting),
        participantAnswerLabel(kAnswerCant),
        participantAnswerLabel(kAnswerLeft),
        participantAnswerLabel(kAnswerNotAsked),
      ];
      // Состав, а не количество (I13): пять непустых и пять различных.
      // Совпади любые два — экран слил бы два разных состояния в одно, и
      // счёт «их пять» этого бы не заметил.
      expect(labels.where((s) => s.isEmpty), isEmpty);
      expect(labels.toSet().length, 5);
    });

    test('вышедший назван «İşdən çıxdı» — та самая пометка шага 2', () {
      // УСЛОВИЕ ВЛАДЕЛЬЦА 28.08 ЗВУЧИТ «пометка обязана РАБОТАТЬ к моменту
      // снятия unsettledAfterMemberLeft», и до 29.08 её не подтверждало
      // ничто: слово было написано в `event_answers.dart` и не прочитано ни
      // одной проверкой. Слово закреплено здесь дословно, потому что по нему
      // владелец и узнаёт об уходе после того, как строка «что случилось»
      // про уход замолчит (N182, цена 1).
      expect(participantAnswerLabel(kAnswerLeft), 'İşdən çıxdı');
    });

    test('«вышел» и «не может» названы РАЗНО — это не один отказ', () {
      // `cant` — «я не приду», человек в вечере, изменения ему идут.
      // `left` — «меня в этом вечере больше нет», ему не идёт ничего
      // (`recipientsOf`, шаг 1). Слить их на экране значило бы показать
      // владельцу отказ там, где человек ушёл насовсем.
      expect(participantAnswerLabel(kAnswerLeft),
          isNot(participantAnswerLabel(kAnswerCant)));
    });

    test('«не спрошен» и «ждём» названы РАЗНО — это I47 на экране', () {
      // Показать неспрошенного как ждущего значит соврать владельцу, что он
      // свою часть уже сделал: у этих двух разный адресат следующего хода.
      expect(participantAnswerLabel(kAnswerNotAsked),
          isNot(participantAnswerLabel(kAnswerWaiting)));
    });

    test('нет в составе — ярлыка нет вовсе, а не «ждём»', () {
      // `answerFor` отдаёт `null` тому, кого в составе нет. Ярлык по
      // умолчанию был бы ответом за человека, которого никто не звал.
      expect(participantAnswerLabel(null), '');
    });

    test('незнакомое значение ярлыка не получает', () {
      // Поле пишут трое, и значение гарантирует не поле, а писатель (I49).
      // Мусор обязан остаться без слова, а не притвориться ответом.
      expect(participantAnswerLabel('нечто'), '');
    });

    test('показ идёт через answerFor, значит знает запасной путь', () {
      // Круговая: у документа без карты человек в составе «идёт», и ярлык
      // обязан сказать именно это. Проверяется связка правило → показ, а не
      // ярлык сам по себе.
      final old = PersonalEvent.fromFirestore('e', {
        'ownerUid': 'owner',
        'date': '2026-08-08T19:00:00',
        'musicians': ['owner', 'guest'],
      });
      expect(participantAnswerLabel(old.answerFor('guest')),
          participantAnswerLabel(kAnswerGoing));
    });

    test('документ, каким его напишет уход, даёт «İşdən çıxdı»', () {
      // КРУГОВАЯ, И ОНА ГЛАВНАЯ ИЗ ТРЁХ ПРО `left` (I55: портить и
      // проверять надо путь, которым идёт ПРОД, а не ближайшую точку
      // входа). Проверка выше берёт значение готовым; здесь оно проходит
      // весь путь: карта в документе → `fromFirestore` → `answerFor` →
      // ярлык. Ровно этим путём слово и появится на экране, когда
      // `leavePersonalEvent` начнёт писать ключ.
      //
      // ВЫШЕДШИЙ ОСТАЁТСЯ В СОСТАВЕ, и это половина смысла новой схемы:
      // `answerFor` отдаёт `null` тому, кого в `musicians` нет, и пропади
      // человек из состава — ярлыка не было бы вовсе, а строки в блоке
      // состава не было бы тем более. Старый уход вычёркивал его отсюда
      // (N121), потому и показывать было нечего.
      final afterLeave = PersonalEvent.fromFirestore('e-left', {
        'ownerUid': 'owner',
        'date': '2026-09-14T20:00:00.000',
        'musicians': ['owner', 'guest'],
        'answers': {'owner': kAnswerGoing, 'guest': kAnswerLeft},
        'answersWrittenByOwner': true,
      });
      expect(afterLeave.answerFor('guest'), kAnswerLeft);
      expect(participantAnswerLabel(afterLeave.answerFor('guest')),
          'İşdən çıxdı');
      // Соседка к утверждению выше: у второго человека в том же документе
      // слово ДРУГОЕ. Без неё «İşdən çıxdı» подтвердилось бы и разбором,
      // который отдаёт один ярлык всем подряд.
      expect(participantAnswerLabel(afterLeave.answerFor('owner')),
          isNot('İşdən çıxdı'));
    });
  });
}
