import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_deed_line.dart';

// ЧТО СЛУЧИЛОСЬ С ВЕЧЕРОМ ПОСЛЕДНИМ — `eventDeedLine`.
//
// ПРОВЕРЯЕТСЯ КАЖДОЕ ЗНАЧЕНИЕ ПОИМЁННО, А НЕ ВЫБОРОЧНО. Их пятнадцать, из
// них четыре обязаны молчать, и молчание — такой же ответ, как фраза: у него
// есть довод, и его можно сломать, не заметив. Проверка «на паре примеров»
// зазеленела бы при любой из четырёх ошибок.
//
// ОТДЕЛЬНО — ТЕ, У КОГО ПИСАТЕЛЯ НЕТ ВОВСЕ (`deleted`, `workCancelled`).
// Их проверяют не «на всякий случай»: у обоих есть будущее, и оно разное.
// `deleted` не получит писателя никогда — документа после удаления не
// существует; `workCancelled` получит его в Части 6. Значит один обязан
// молчать навсегда, а второй уже отвечает, и записать это надо сейчас, пока
// довод помнится.

void main() {
  const me = 'viewer-uid';
  const other = 'other-uid';

  EventDeed? deed(
    String? type, {
    String? by = other,
    String name = 'Rafael',
    String viewer = me,
  }) => eventDeedLine(
        lastActionType: type,
        lastActionBy: by,
        viewerUid: viewer,
        actorName: name,
      );

  // Текст отдельно от тона: почти все проверки ниже про слова, и тащить в них
  // `.text` значило бы двадцать раз написать одно и то же.
  String? line(
    String? type, {
    String? by = other,
    String name = 'Rafael',
    String viewer = me,
  }) => deed(type, by: by, name: name, viewer: viewer)?.text;

  group('чужой поступок — третье лицо', () {
    // Пятнадцать значений, и здесь их одиннадцать говорящих. Проверяется не
    // только «непусто», но и сам текст: фраза — это то, что человек прочтёт,
    // и «непусто» прошло бы на любой строке, включая неверную.
    final expected = <String, String>{
      kDeedCreated: 'Rafael tədbiri yaratdı',
      kDeedReplaced: 'Rafael tədbiri əvəz etdi',
      kDeedLeft: 'Rafael ayrıldı',
      kDeedMemberLeft: 'Rafael ayrıldı',
      kDeedCancelRequested: 'Rafael ləğv etməyi təklif edir',
      kDeedCancelConfirmed: 'Rafael ləğvi təsdiqlədi',
      kDeedCancelWithdrawn: 'Rafael təklifini geri götürdü',
      kDeedCancelDeclined: 'Rafael ləğvdən imtina etdi',
      kDeedOwnerFirm: 'Rafael «dəqiq» işarələdi',
      kDeedOwnerDoubt: 'Rafael şübhə bildirdi',
      kDeedOwnerCancelled: 'Rafael tədbiri ləğv etdi',
      kDeedRestored: 'Rafael tədbiri qaytardı',
    };

    expected.forEach((deed, text) {
      test('$deed → «$text»', () => expect(line(deed), text));
    });
  });

  group('свой поступок — второе лицо, и глагол ДРУГОЙ', () {
    // ЭТО ГЛАВНАЯ ГРУППА ФАЙЛА, и вот почему. В азербайджанском лицо выражено
    // окончанием глагола: «ayrıldın» против «ayrıldı». Подставь мы имя в общий
    // шаблон — своё действие читалось бы третьим лицом, то есть человек читал
    // бы о себе как о постороннем. Поэтому подставляется ФРАЗА целиком, и
    // проверять надо, что вторая фраза не равна первой с заменённым именем.
    final expected = <String, String>{
      kDeedCreated: 'Tədbiri sən yaratdın',
      kDeedReplaced: 'Tədbiri sən əvəz etdin',
      kDeedLeft: 'Sən ayrıldın',
      kDeedMemberLeft: 'Sən ayrıldın',
      kDeedCancelRequested: 'Ləğv etməyi sən təklif etdin',
      kDeedCancelConfirmed: 'Ləğvi sən təsdiqlədin',
      kDeedCancelWithdrawn: 'Təklifini sən geri götürdün',
      kDeedCancelDeclined: 'Ləğvdən sən imtina etdin',
      kDeedOwnerFirm: 'Sən «dəqiq» işarələdin',
      kDeedOwnerDoubt: 'Sən şübhə bildirdin',
      kDeedOwnerCancelled: 'Tədbiri sən ləğv etdin',
      kDeedRestored: 'Tədbiri sən qaytardın',
    };

    expected.forEach((deed, text) {
      test('$deed → «$text»', () => expect(line(deed, by: me), text));
    });

    test('ни одна своя фраза не совпадает с чужой', () {
      // Соседка ко всем двенадцати выше разом: совпади они — значит лицо
      // потерялось, и проверка «текст такой-то» этого бы не показала, если
      // ошибиться сразу в обеих таблицах.
      for (final deed in expected.keys) {
        expect(line(deed, by: me), isNot(line(deed)), reason: deed);
      }
    });
  });

  group('молчание — четыре разных случая, один ответ', () {
    test('edited молчит: что изменилось, документ не помнит', () {
      // Правка, добавление в состав и исключение пишут ОДИН `edited`
      // (`event_edit.dart` кладёт `musicians` и имя поступка одной записью).
      // «Rafael dəyişdi» не сказало бы ничего, «tarixi dəyişdi» — выдумка.
      expect(line(kDeedEdited), isNull);
      expect(line(kDeedEdited, by: me), isNull);
    });

    test('deleted молчит — и писателя у него не будет никогда', () {
      // Документа после удаления не существует, открыть его карточку нечем.
      // Значение живёт только в союзе типов на сервере.
      expect(line('deleted'), isNull);
    });

    test('незнакомое значение молчит, а не гадает', () {
      // mugam-v2, правка руками в консоли, будущий ход (I49: писателей трое).
      expect(line('нечто'), isNull);
      expect(line(''), isNull);
    });

    test('поля нет вовсе — молчит', () {
      // 58 вечеров из 103 в проде, замер 28.08 (N178).
      expect(line(null), isNull);
    });

    test('поступок есть, а автора нет — молчит там, где нужно лицо', () {
      expect(line(kDeedLeft, by: null), isNull);
      expect(line(kDeedLeft, by: ''), isNull);
    });
  });

  group('безличные — говорят и БЕЗ автора', () {
    // Обе фразы решаются до проверки автора, и это не мелочь: откажи им
    // пустой `lastActionBy` — строка промолчала бы там, где сказать есть что.
    test('agreed говорит о факте, не называя лица', () {
      // Имя поступка пишут ДВОЕ, и «кто» у них разное: клиент кладёт
      // инициатора (принял работодатель), сервер — получателя (согласился
      // музыкант). Назвать действующего значило бы назвать разных людей одним
      // словом в зависимости от того, каким путём родился вечер.
      expect(line(kDeedAgreed), 'Tədbir razılaşma ilə yarandı');
      expect(line(kDeedAgreed, by: null), 'Tədbir razılaşma ilə yarandı');
      expect(line(kDeedAgreed, by: me), 'Tədbir razılaşma ilə yarandı');
    });

    test('workCancelled отвечает уже сейчас, хотя писателя ещё нет', () {
      // Писатель придёт в Части 6 вместе с приглашениями своих. Фраза стоит
      // заранее по тому же доводу, по которому заведено имя поступка: заведи
      // один — он определит форму, а второй придётся подгонять.
      expect(line(kDeedWorkCancelled), 'İş ləğv olundu');
      expect(line(kDeedWorkCancelled, by: null), 'İş ləğv olundu');
    });
  });

  group('имя действующего', () {
    test('пустое имя даёт «Naməlum», а не пустоту в строке', () {
      // То же слово и по той же причине, что в `offerAuthorLine`: строка
      // «‌ ayrıldı» выглядела бы поломкой.
      expect(line(kDeedLeft, name: '   '), '$kUnknownActorName ayrıldı');
    });

    test('пробелы вокруг имени срезаются', () {
      expect(line(kDeedLeft, name: '  Rafael  '), 'Rafael ayrıldı');
    });

    test('своё действие имени не спрашивает вовсе', () {
      // Даже с пустым именем своя фраза остаётся целой: в ней имени нет.
      expect(line(kDeedLeft, by: me, name: ''), 'Sən ayrıldın');
    });
  });

  group('тон — громко только про участника', () {
    // Требование владельца 28.08: «чтобы голым глазом было видно, что
    // произошло с участником». Тон — вторая половина сообщения, и проверять
    // его надо отдельно от слов: текст может быть верным при неверном тоне,
    // и наоборот.

    test('уход — единственный громкий, обеими фразами', () {
      expect(deed(kDeedLeft)?.tone, DeedTone.memberGone);
      expect(deed(kDeedLeft, by: me)?.tone, DeedTone.memberGone);
      expect(deed(kDeedMemberLeft)?.tone, DeedTone.memberGone);
      expect(deed(kDeedMemberLeft, by: me)?.tone, DeedTone.memberGone);
    });

    test('ОТМЕНА ВЕЧЕРА НЕ громкая, и это решение, а не пропуск', () {
      // Отмена — тоже потеря, но потеря ДРУГОГО: вечера, а не человека.
      // Покрась и её — тон перестанет что-либо означать, и глаз привыкнет к
      // кирпичному ровно там, где он должен останавливать. Плюс в палитре
      // проекта красный уже занят отменой (N110), и два красных смысла на
      // одном экране не различить.
      expect(deed(kDeedOwnerCancelled)?.tone, DeedTone.plain);
      expect(deed(kDeedCancelConfirmed)?.tone, DeedTone.plain);
      expect(deed(kDeedWorkCancelled)?.tone, DeedTone.plain);
    });

    test('всё остальное — тихое', () {
      for (final d in <String>[
        kDeedCreated, kDeedReplaced, kDeedAgreed, kDeedCancelRequested,
        kDeedCancelWithdrawn, kDeedCancelDeclined, kDeedOwnerFirm,
        kDeedOwnerDoubt, kDeedRestored,
      ]) {
        expect(deed(d)?.tone, DeedTone.plain, reason: d);
      }
    });

    // СОСЕДКА (I31): без неё «всё тихое» прошло бы и на функции, вернувшей
    // `plain` вообще всегда, — то есть на сломанном тоне.
    test('соседка: громкий тон вообще встречается', () {
      final tones = <DeedTone>{
        for (final d in <String>[kDeedCreated, kDeedLeft, kDeedOwnerCancelled])
          deed(d)!.tone,
      };
      expect(tones.length, 2, reason: 'тон свёлся к одному значению');
    });
  });

  group('своё или чужое — признак для крестика', () {
    // Крестик прячет НОВОСТЬ, а собственное действие новостью не является:
    // человек его только что совершил. Признак решается в правиле, а не в
    // разметке, потому что тот же вопрос уже решён здесь ради лица глагола, и
    // второй ответ на него разошёлся бы с первым (N49).

    // ВСЕ ПОСТУПКИ РАЗОМ, А НЕ ВЫБОРОЧНО (I64: проверять не наличие правила, а
    // каждого, кто под него подпадает). Признак дописывался в одиннадцать
    // ветвей, и в трёх из них его сперва не оказалось — недостача прошла бы
    // молча, будь здесь проверено два примера.
    const withFace = <String>[
      kDeedCreated, kDeedReplaced, kDeedLeft, kDeedMemberLeft,
      kDeedCancelRequested, kDeedCancelConfirmed, kDeedCancelWithdrawn,
      kDeedCancelDeclined, kDeedOwnerFirm, kDeedOwnerDoubt,
      kDeedOwnerCancelled, kDeedRestored,
    ];

    test('свой поступок помечен своим — все двенадцать', () {
      for (final d in withFace) {
        expect(deed(d, by: me)?.own, isTrue, reason: d);
      }
    });

    test('чужой поступок своим не помечен — все двенадцать', () {
      for (final d in withFace) {
        expect(deed(d)?.own, isFalse, reason: d);
      }
    });

    test('безличные не бывают своими — им некого называть', () {
      expect(deed(kDeedAgreed, by: me)?.own, isFalse);
      expect(deed(kDeedWorkCancelled, by: me)?.own, isFalse);
    });
  });

  group('ключ, по которому строка прячется', () {
    // Крестик справа убирает КОНКРЕТНУЮ новость, а не вечер: убравший
    // «Rafael ayrıldı» обязан увидеть следующее сообщение об этом же вечере.

    test('разные поступки одного вечера — разные ключи', () {
      final a = deedDismissKey(
          eventId: 'ev1', lastActionType: kDeedLeft, lastActionBy: other);
      final b = deedDismissKey(
          eventId: 'ev1',
          lastActionType: kDeedOwnerCancelled,
          lastActionBy: other);
      expect(a, isNot(b));
    });

    test('один поступок разных людей — разные ключи', () {
      expect(
        deedDismissKey(
            eventId: 'ev1', lastActionType: kDeedLeft, lastActionBy: other),
        isNot(deedDismissKey(
            eventId: 'ev1', lastActionType: kDeedLeft, lastActionBy: me)),
      );
    });

    test('один поступок разных вечеров — разные ключи', () {
      expect(
        deedDismissKey(
            eventId: 'ev1', lastActionType: kDeedLeft, lastActionBy: other),
        isNot(deedDismissKey(
            eventId: 'ev2', lastActionType: kDeedLeft, lastActionBy: other)),
      );
    });

    test('тот же поступок — тот же ключ, иначе скрытие не удержится', () {
      expect(
        deedDismissKey(
            eventId: 'ev1', lastActionType: kDeedLeft, lastActionBy: other),
        deedDismissKey(
            eventId: 'ev1', lastActionType: kDeedLeft, lastActionBy: other),
      );
    });

    test('пустые части не роняют ключ и не сливают разные вечера', () {
      expect(
        deedDismissKey(eventId: 'ev1', lastActionType: null, lastActionBy: null),
        isNot(deedDismissKey(
            eventId: 'ev2', lastActionType: null, lastActionBy: null)),
      );
    });
  });

  // КАНАРЕЙКА КО ВСЕМУ ФАЙЛУ (I31, I13).
  //
  // Без неё правило, сведённое к одному ответу, прошло бы часть проверок и
  // выглядело бы работающим: верни функция `null` на всё — зазеленели бы пять
  // проверок молчания; верни она одну и ту же фразу на всё — зазеленели бы
  // совпадения там, где фразы и так одинаковы (`left` и `memberLeft`).
  // Здесь сказано вслух, СКОЛЬКО РАЗНЫХ ответов она даёт.
  test('КАНАРЕЙКА: функция не сводится к одному ответу', () {
    const all = <String>[
      kDeedCreated, kDeedReplaced, kDeedAgreed, kDeedLeft, kDeedMemberLeft,
      kDeedCancelRequested, kDeedCancelConfirmed, kDeedCancelWithdrawn,
      kDeedCancelDeclined, kDeedOwnerFirm, kDeedOwnerDoubt,
      kDeedOwnerCancelled, kDeedWorkCancelled, kDeedRestored, kDeedEdited,
    ];
    expect(all.length, 15, reason: 'значений поступка стало другое число');

    final answers = <String?>{
      for (final d in all) line(d),
      for (final d in all) line(d, by: me),
    };
    // РАЗБИЕНИЕ СЛОЖЕНО ВСЛУХ (I13), и складывать пришлось дважды: первый
    // счёт дал 27 и был неверен. `left` и `memberLeft` — один поступок под
    // двумя именами, их фразы совпадают, поэтому в каждом проходе не
    // двенадцать различных, а одиннадцать.
    //
    //   11 чужих фраз + 11 своих + 2 безличные (в обоих проходах те же)
    //   + `null` от `edited` = 25.
    //
    // Ошибка нашлась счётом до прогона, а не прогоном: результат был ещё
    // неизвестен, и потому подгонять было не подо что.
    expect(answers.length, 25);
    expect(answers.contains(null), isTrue, reason: 'edited обязан молчать');
  });
}
