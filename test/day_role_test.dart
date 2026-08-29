import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/day_role.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ЧЕМ ВЕЧЕР ЯВЛЯЕТСЯ ЧЕЛОВЕКУ — правило `dayRoleOf`.
//
// Заведено 12.08 вместе с самим правилом, после N126: сетка месяца помечала
// день занятым и на приглашении, и на отказе.
//
// СОБЫТИЕ СТРОИТСЯ ЧЕРЕЗ `fromFirestore`, А НЕ КОНСТРУКТОРОМ, и это не
// придирка к стилю: карта ответов у модели закрыта (`_answers`), параметр
// конструктора закрыт тем же именем, и передать карту снаружи `models.dart`
// НЕЛЬЗЯ ВОВСЕ. Единственная дорога внутрь — документ, то есть ровно тот
// путь, которым ответы приходят в проде (I55: портить и проверять надо тот
// путь, которым идёт прод, а не ближайшую удобную точку входа).

void main() {
  const absent = Object();

  PersonalEvent make({
    String owner = 'owner',
    List<String> musicians = const [],
    Object? answers = absent,
    bool writtenByOwner = true,
  }) =>
      PersonalEvent.fromFirestore('e', {
        'ownerUid': owner,
        'date': '2026-08-14T20:00:00',
        'musicians': musicians,
        if (!identical(answers, absent)) 'answers': answers,
        'answersWrittenByOwner': writtenByOwner,
      });

  group('dayRoleOf — три ответа, а не два', () {
    test('иду — день занят', () {
      final e = make(
        musicians: const ['owner', 'guest'],
        answers: const {'owner': kAnswerGoing, 'guest': kAnswerGoing},
      );
      expect(dayRoleOf(e, 'guest'), DayRole.occupied);
    });

    test('ЖДУТ ОТВЕТА — приглашён, и день НЕ занят', () {
      // Первая половина N126: приглашение помечало день занятым.
      final e = make(
        musicians: const ['owner', 'guest'],
        answers: const {'owner': kAnswerGoing, 'guest': kAnswerWaiting},
      );
      expect(dayRoleOf(e, 'guest'), DayRole.invited);
      expect(dayRoleOf(e, 'guest'), isNot(DayRole.occupied));
    });

    test('ОТКАЗАЛСЯ — свой ответ, а не «пусто»', () {
      // Вторая половина N126, и она хуже первой: отказ выглядел согласием.
      // Человек уже совершил поступок, и приложение показывало обратное.
      //
      // ПОПРАВЛЕНО 12.08 по виду на трубке: сперва отказ давал `free`, то
      // есть день становился неотличим от пустого. Автор потребовал, чтобы
      // след оставался: день свободен, но серая точка говорит «здесь был
      // вопрос, и я его разобрал».
      final e = make(
        musicians: const ['owner', 'guest'],
        answers: const {'owner': kAnswerGoing, 'guest': kAnswerCant},
      );
      expect(dayRoleOf(e, 'guest'), DayRole.declined);
      expect(dayRoleOf(e, 'guest'), isNot(DayRole.occupied),
          reason: 'отказ день не занимает');
      expect(dayRoleOf(e, 'guest'), isNot(DayRole.free),
          reason: 'отказ отличим от пустого дня');
    });

    test('вышел — СВОЯ роль, а не «свободен»', () {
      // ЗДЕСЬ СТОЯЛО `DayRole.free`, И ЭТО БЫЛО ВЕРНО ДО 29.08. Пока писать
      // `left` было некому (N121), «я ушёл» и «меня не звали» на экране
      // выглядели одинаково, и разницы не существовало. С появлением
      // писателя она видна: у вышедшего вечер ЕСТЬ и он в его составе, у
      // незваного вечера нет вовсе, — и показывать их надо по-разному (I47).
      final e = make(
        musicians: const ['owner', 'guest'],
        answers: const {'owner': kAnswerGoing, 'guest': kAnswerLeft},
      );
      expect(dayRoleOf(e, 'guest'), DayRole.left);
      expect(dayRoleOf(e, 'guest'), isNot(DayRole.free),
          reason: 'вышедший отличим от того, кого не звали');
      expect(dayRoleOf(e, 'guest'), isNot(DayRole.occupied),
          reason: 'выход освобождает день — ради этого ход и есть');
      expect(dayRoleOf(e, 'guest'), isNot(DayRole.declined),
          reason: 'вышедший ничего не отклонял: приглашение он принял');
    });
  });

  // ПОКАЗЫВАТЬ ЛИ ВЕЧЕР ВООБЩЕ — правило `showsInCalendarOf`, заведено 29.08
  // шагом 2 работы N121.
  //
  // Утверждение здесь ДВОЙНОЕ и потому само себе канарейка (I31): у одних
  // «да», у других «нет». Ослепни разбор — обе половины сойдутся в один
  // ответ, и любая из двух проверок покраснеет.
  group('showsInCalendarOf — вечер, из которого вышли, не показывается', () {
    test('вышедшему НЕ показывается, остальным показывается', () {
      final e = make(
        musicians: const ['owner', 'guest', 'other'],
        answers: const {
          'owner': kAnswerGoing,
          'guest': kAnswerLeft,
          'other': kAnswerCant,
        },
      );
      expect(showsInCalendarOf(e, 'guest'), isFalse,
          reason: 'обещание окна конфликта — «yalnız sizin təqvimdən '
              'silinəcək»; не спрячь мы вечер здесь, приложение соврало бы '
              'в том самом месте, где обещало');
      // ТРИ СОСЕДКИ, И ОНИ ЖЕ ГРАНИЦА ПРАВИЛА. Без них «не показывается»
      // подтвердилось бы и правилом, которое прячет вечер у всех подряд.
      expect(showsInCalendarOf(e, 'owner'), isTrue,
          reason: 'владельцу его собственный вечер виден всегда');
      expect(showsInCalendarOf(e, 'other'), isTrue,
          reason: '«не могу» — не уход: человек в составе, и дорога назад '
              'ему нужна, чтобы передумать');
      expect(showsInCalendarOf(e, ''), isTrue,
          reason: 'неизвестный смотрящий видит ЛИШНЕЕ, а не теряет своё: '
              'пустой экран прочитался бы как хорошая новость (I14)');
    });

    test('это ДРУГОЙ вопрос, чем «показать строкой или карточкой»', () {
      // Отказавшийся отвечает «показывать, и строкой»; вышедший — «не
      // показывать вовсе». Слейся эти два правила, отказавшийся потерял бы
      // дорогу назад, а вышедший получил бы строку приглашения на вечер, из
      // которого ушёл.
      final e = make(
        musicians: const ['owner', 'guest', 'other'],
        answers: const {
          'owner': kAnswerGoing,
          'guest': kAnswerLeft,
          'other': kAnswerCant,
        },
      );
      expect(showsAsInvitation(e, 'other'), isTrue);
      expect(showsInCalendarOf(e, 'other'), isTrue);
      expect(showsAsInvitation(e, 'guest'), isFalse);
      expect(showsInCalendarOf(e, 'guest'), isFalse);
    });

    test('вышедший не оставляет серой точки на дне', () {
      // След означает «здесь был вопрос ко мне, и я его разобрал». У
      // вышедшего вопроса не было — он принял приглашение и ушёл из дела.
      final e = make(
        musicians: const ['owner', 'guest'],
        answers: const {'owner': kAnswerGoing, 'guest': kAnswerLeft},
      );
      expect(hasHandledInvitationOn([e], 'guest', const {}), isFalse);
      // Соседка: у отказавшегося след ЕСТЬ, тем же вызовом. Без неё «следа
      // нет» подтвердилось бы и разбором, который следа не видит вовсе.
      final otkaz = make(
        musicians: const ['owner', 'guest'],
        answers: const {'owner': kAnswerGoing, 'guest': kAnswerCant},
      );
      expect(hasHandledInvitationOn([otkaz], 'guest', const {}), isTrue);
    });
  });

  group('границы, каждая куплена разбором', () {
    test('ВЛАДЕЛЕЦ ЗАНЯТ ВСЕГДА — даже когда карта объявила его ждущим', () {
      // N112: `answersForParticipants` ставит `waiting` всем новым в составе,
      // а у договоров владелец в составе есть. Без этой ветви правка состава
      // молча освобождала бы календарь владельца на его же вечере.
      final e = make(
        owner: 'owner',
        musicians: const ['owner', 'guest'],
        answers: const {'owner': kAnswerWaiting, 'guest': kAnswerWaiting},
      );
      expect(dayRoleOf(e, 'owner'), DayRole.occupied);
    });

    test('ПУСТОЙ uid — «занят», а не «свободен»', () {
      // I14: «свободен» тихо выключил бы ВСЕ предупреждения о конфликтах —
      // пустой вывод, прочитанный как хорошая новость. «Занят» на каждом
      // вечере — ложная тревога, и её видно в тот же миг.
      final e = make(musicians: const ['owner', 'guest']);
      expect(dayRoleOf(e, ''), DayRole.occupied);
    });

    test('НЕ ПОЗВАЛИ (notAsked) — свободен, а НЕ приглашён', () {
      // Ключа нет, но карту заполнял владелец → `notAsked`. Действовать
      // должен ВЛАДЕЛЕЦ (позвать по-настоящему), а не человек. Показать ему
      // приглашение значило бы позвать от чужого имени.
      final e = make(
        musicians: const ['owner', 'guest'],
        answers: const {'owner': kAnswerGoing},
        writtenByOwner: true,
      );
      expect(e.answerFor('guest'), kAnswerNotAsked);
      expect(dayRoleOf(e, 'guest'), DayRole.free);
      expect(dayRoleOf(e, 'guest'), isNot(DayRole.invited));
    });

    test('человека нет в составе — свободен', () {
      final e = make(musicians: const ['owner']);
      expect(e.answerFor('stranger'), isNull);
      expect(dayRoleOf(e, 'stranger'), DayRole.free);
    });
  });

  group('СТАРЫЕ ДОКУМЕНТЫ — «занят», и это верно, а не дырка', () {
    test('карты нет вовсе — человек в составе занят', () {
      // До разделения смыслов «есть в `musicians`» и ОЗНАЧАЛО «идёт», поэтому
      // запасной путь — честный перевод старого смысла, а не заглушка.
      //
      // Перепись прода 12.08: так читаются 72 человека в 38 документах из 78,
      // из них будущих документов 3. Множество ЗАМКНУТО — mugam-v2 мёртв,
      // других писателей мимо нас нет, значит расти ему нечем.
      final e = make(musicians: const ['owner', 'guest'], writtenByOwner: false);
      expect(e.answerFor('guest'), kAnswerGoing);
      expect(dayRoleOf(e, 'guest'), DayRole.occupied);
    });
  });

  // --- СТРОКА ПРИГЛАШЕНИЯ ПОД СЕТКОЙ (найдено на трубке 12.08) ---
  group('showsAsInvitation — приглашение остаётся им и после ответа «нет»', () {
    PersonalEvent withAnswer(String answer) => make(
          musicians: const ['owner', 'guest'],
          answers: {'owner': kAnswerGoing, 'guest': answer},
        );

    test('ждут ответа — строкой приглашения', () {
      expect(showsAsInvitation(withAnswer(kAnswerWaiting), 'guest'), isTrue);
    });

    test('ОТКАЗАЛСЯ — ВСЁ РАВНО строкой приглашения', () {
      // Тот самый случай с трубки: строка «Rafael səni çağırır» пропадала
      // сразу после «Bacarmıram», и день показывался обычной карточкой
      // вечера — то есть человеку записывали чужую работу как свою, при том
      // что он от неё отказался.
      expect(showsAsInvitation(withAnswer(kAnswerCant), 'guest'), isTrue);
    });

    test('СОГЛАСИЛСЯ — карточкой вечера, а не строкой', () {
      // Согласие превращает чужой зов в моё дело: туда я иду.
      expect(showsAsInvitation(withAnswer(kAnswerGoing), 'guest'), isFalse);
    });

    test('ВЛАДЕЛЕЦ — карточкой, приглашать себя некому', () {
      expect(showsAsInvitation(withAnswer(kAnswerWaiting), 'owner'), isFalse);
    });

    test('вышел из состава — не приглашение', () {
      expect(showsAsInvitation(withAnswer(kAnswerLeft), 'guest'), isFalse);
    });
  });

  // --- ЧИСЛО НЕПРОСМОТРЕННЫХ (решение автора 12.08) ---
  group('unseenInvitationsOn — сколько приглашений ждёт меня', () {
    PersonalEvent inv(String id, String answer) =>
        PersonalEvent.fromFirestore(id, {
          'ownerUid': 'owner',
          'date': '2026-08-14T20:00:00',
          'musicians': const ['owner', 'guest'],
          'answers': {'owner': kAnswerGoing, 'guest': answer},
          'answersWrittenByOwner': true,
        });

    test('три приглашения, ни одного не смотрел — три', () {
      final day = [
        inv('a', kAnswerWaiting),
        inv('b', kAnswerWaiting),
        inv('c', kAnswerWaiting),
      ];
      expect(unseenInvitationsOn(day, 'guest', const {}), 3);
    });

    test('одно просмотрено — два', () {
      final day = [
        inv('a', kAnswerWaiting),
        inv('b', kAnswerWaiting),
        inv('c', kAnswerWaiting),
      ];
      expect(unseenInvitationsOn(day, 'guest', const {'b'}), 2);
    });

    test('все просмотрены — ноль', () {
      final day = [inv('a', kAnswerWaiting), inv('b', kAnswerWaiting)];
      expect(unseenInvitationsOn(day, 'guest', const {'a', 'b'}), 0);
    });

    test('ОТВЕЧЕННЫЕ НЕ СЧИТАЮТСЯ, даже если в «просмотренных» их нет', () {
      // Ответить, не увидев, нельзя — значит отвеченное разобрано по самому
      // факту ответа, и ждать формальной отметки о просмотре незачем.
      final day = [
        inv('a', kAnswerCant),
        inv('b', kAnswerGoing),
        inv('c', kAnswerWaiting),
      ];
      expect(unseenInvitationsOn(day, 'guest', const {}), 1);
    });

    test('ВЛАДЕЛЕЦ не считает себе приглашений', () {
      final day = [inv('a', kAnswerWaiting), inv('b', kAnswerWaiting)];
      expect(unseenInvitationsOn(day, 'owner', const {}), 0);
    });

    test('посторонний — ноль', () {
      expect(
        unseenInvitationsOn([inv('a', kAnswerWaiting)], 'stranger', const {}),
        0,
      );
    });

    test('пустой uid — ноль, а не «все»', () {
      // Пустой uid значит «неизвестно, кто спрашивает». `dayRoleOf` отвечает
      // на него «занято», и приглашением это не является — счёт обязан быть
      // нулевым, а не показать чужие вопросы неизвестно кому.
      expect(
        unseenInvitationsOn([inv('a', kAnswerWaiting)], '', const {}),
        0,
      );
    });

    test('СОСЕДКА-КАНАРЕЙКА: тот же вход при пустом наборе даёт НЕ ноль', () {
      // Все проверки выше утверждают «столько-то НЕ ждёт», а такое ломается
      // молча: ослепший счёт вернул бы ноль и был бы зелёным. Здесь
      // утверждается НАЛИЧИЕ на том же входе.
      final day = [inv('a', kAnswerWaiting)];
      expect(unseenInvitationsOn(day, 'guest', const {}), 1);
      expect(unseenInvitationsOn(day, 'guest', const {'a'}), 0);
    });
  });

  group('hasHandledInvitationOn — остался ли след', () {
    PersonalEvent inv(String id, String answer) =>
        PersonalEvent.fromFirestore(id, {
          'ownerUid': 'owner',
          'date': '2026-08-14T20:00:00',
          'musicians': const ['owner', 'guest'],
          'answers': {'owner': kAnswerGoing, 'guest': answer},
          'answersWrittenByOwner': true,
        });

    test('отказ — след есть', () {
      expect(
        hasHandledInvitationOn([inv('a', kAnswerCant)], 'guest', const {}),
        isTrue,
      );
    });

    test('просмотрено, но не отвечено — след есть', () {
      expect(
        hasHandledInvitationOn(
            [inv('a', kAnswerWaiting)], 'guest', const {'a'}),
        isTrue,
      );
    });

    test('не смотрел и не отвечал — следа нет, там ЧИСЛО', () {
      expect(
        hasHandledInvitationOn([inv('a', kAnswerWaiting)], 'guest', const {}),
        isFalse,
      );
    });

    test('согласился — следа нет, день просто занят', () {
      expect(
        hasHandledInvitationOn([inv('a', kAnswerGoing)], 'guest', const {}),
        isFalse,
      );
    });
  });

  group('СОСЕДКА-КАНАРЕЙКА (I31)', () {
    test('правило вообще различает случаи, а не отвечает одним значением', () {
      // Утверждение «такое-то не занимает день» ломается МОЛЧА: ослепшее
      // правило, отвечающее `free` на всё, оставило бы половину проверок выше
      // зелёными. Здесь утверждается НАЛИЧИЕ всех трёх ответов сразу — такая
      // проверка сама себе канарейка и краснеет от ослепления.
      // ПЯТЫЙ ДОПИСАН 29.08 НЕ РУКАМИ, А ПО ЕЁ ЖЕ КРАСНОМУ: добавив
      // `DayRole.left`, я прогнал набор — и упала ровно эта проверка,
      // «ожидалось 5, получено 4». То есть она сделала то, ради чего
      // заведена: новое значение перечисления не может тихо остаться
      // недостижимым. Случай стоит помнить как образец — сравнение с
      // `DayRole.values.length` дешевле любого сторожа по тексту.
      final e = make(
        musicians: const [
          'owner', 'going', 'waiting', 'cant', 'left', 'notasked',
        ],
        answers: const {
          'owner': kAnswerGoing,
          'going': kAnswerGoing,
          'waiting': kAnswerWaiting,
          'cant': kAnswerCant,
          'left': kAnswerLeft,
        },
      );
      final seen = {
        dayRoleOf(e, 'going'),
        dayRoleOf(e, 'waiting'),
        dayRoleOf(e, 'cant'),
        dayRoleOf(e, 'left'),
        dayRoleOf(e, 'notasked'),
      };
      expect(seen, {
        DayRole.occupied,
        DayRole.invited,
        DayRole.declined,
        DayRole.left,
        DayRole.free,
      });
      expect(seen.length, DayRole.values.length,
          reason: 'сколько ответов в перечислении, столько и обязано '
              'различаться — иначе один из них недостижим');
    });
  });
}
