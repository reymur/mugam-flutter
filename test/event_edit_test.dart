import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_edit.dart';

// Два правила, найденные глазами на устройстве и не имевшие теста вовсе.
//
// N40 — «Əvəz et» обещала замену, а делала удаление с созданием нового
// документа. Проверяется не поведением экрана, а АРИФМЕТИКОЙ: 8
// переписываемых плюс 13 сохраняемых обязаны дать ровно 21 ключ
// документа и ни одним больше. Пока сумма сходится, поле не может тихо
// выпасть из рассмотрения — ни новое, ни перенесённое из одной половины в
// другую.
//
// СЧЁТ ИЗМЕНИЛСЯ 10.08 — 7→8 и 20→21, `answers` (шаг 1 работы «договоры и
// мероприятия — одна сущность», `docs/plan.md`). И арифметика показала себя
// ровно так, как задумана: поле было добавлено в код ДО правки этих чисел, и
// три проверки покраснели сами — «переписываемых ровно 7», «объединение
// ровно 20» и «пишет ровно 7 ключей». То есть новое поле физически нельзя
// внести молча: оно обязано быть объявлено в одной из двух половин.
//
// N39 — при правке окно конфликта предлагало снести постороннее
// мероприятие. Проверяется одной строкой: при правке ни один допустимый
// ответ не пишет в чужой документ.

const _actor = 'actor-uid';

void main() {
  group('N40 · арифметика полей', () {
    test('переписываемых ровно 8', () {
      expect(kEventEditWrites.length, 8);
    });

    test('сохраняемых ровно 13', () {
      expect(kEventEditPreserves.length, 13);
    });

    test('пересечение пусто — ни одно поле не в обеих половинах', () {
      expect(kEventEditWrites.intersection(kEventEditPreserves), isEmpty);
    });

    test('объединение — ровно 21 ключ документа, без лишних и без дыр', () {
      final union = {...kEventEditWrites, ...kEventEditPreserves};
      expect(union.length, 21);
      expect(kEventDocKeys.length, 21);
      expect(union, kEventDocKeys);
    });

    test('поимённо: что правка переписывает', () {
      // Список назван ЦЕЛИКОМ, как и у сохраняемых ниже: из «8
      // переписываемых» не следует, что среди них именно `answers`, а
      // равенство множеств само называет, кого не хватает (I13 — состав, а
      // не количество).
      //
      // Заведена 10.08 вместе с `answers`. Первая редакция была написана
      // как `contains('answers')` — и её отверг сторож над сторожами
      // (`guards_are_guards_test`): проверка, довольная одним УПОМИНАНИЕМ
      // имени, слаба по построению. Он прав, и правка вышла сильнее
      // замысла: вместо одного поля теперь сторожатся все восемь.
      expect(kEventEditWrites, {
        'date',
        'type',
        'location',
        'notes',
        'musicians',
        'answers',
        'lastActionBy',
        'lastActionType',
      });
    });

    test('поимённо: что правка обязана сохранить', () {
      // Список назван целиком, а не проверен счётчиком: у каждого поля
      // здесь своя поломка, и «13 штук» не то же самое, что «эти 13».
      expect(kEventEditPreserves, {
        'ownerUid',
        'isAgree',
        'agreementChatId',
        'partnerUid',
        'partnerName',
        'status',
        'jobOfferAt',
        'cancelRequestedBy',
        'cancelRequestedAt',
        'cancelConfirmedBy',
        'cancelledAt',
        'replacedEventId',
        'createdAt',
      });
    });
  });

  group('N40 · сама запись', () {
    Map<String, dynamic> update() => eventEditUpdate(
          date: '2026-08-09T19:00:00.000',
          type: 'Toy',
          location: 'Bakı',
          notes: 'Qara kostyum',
          musicians: const ['a', 'b'],
          actorUid: _actor,
        );

    test('пишет ровно 8 ключей и ровно тех', () {
      final data = update();
      expect(data.length, 8);
      expect(data.keys.toSet(), kEventEditWrites);
    });

    test('ключи answers совпадают с musicians ПОИМЁННО, а не по счёту', () {
      // Состав, а не количество (I13): «столько же ответов, сколько людей»
      // истинно и тогда, когда один человек потерян, а вместо него записан
      // посторонний. Равенство множеств само называет, кого не хватает.
      final data = update();
      final answers = data['answers'] as Map<String, String>;
      expect(answers.keys.toSet(), {'a', 'b'});
      // ШАГ 4: без прежних ответов новые — «ждём». До шага 4 здесь стояло
      // `going`, и это было верно, пока добавление означало согласие.
      expect(answers.values.toSet(), {'waiting'});
    });

    test('правка ведёт ответы за составом, а не оставляет от прошлого', () {
      // Тот самый случай, ради которого `answers` стоит в переписываемых:
      // человек убран, другой добавлен — ответы обязаны поехать следом.
      final data = eventEditUpdate(
        date: '2026-08-09T19:00:00.000',
        type: 'Toy',
        location: 'Bakı',
        notes: '',
        musicians: const ['b', 'c'],
        actorUid: _actor,
      );
      final answers = data['answers'] as Map<String, String>;
      expect(answers.keys.toSet(), {'b', 'c'});
      expect(answers.containsKey('a'), isFalse,
          reason: 'убранный из состава не может остаться с ответом');
      // ЗНАЧЕНИЯ — тоже. Дописано 10.08 после проверки возвратом: эта
      // проверка смотрела ТОЛЬКО на ключи, и порча `going` → `waiting` её
      // не роняла, хотя я предсказывал обратное (I46). Два разных свойства
      // — кто в карте и что про него сказано, — и покрыто было одно.
      expect(answers.values.toSet(), {'waiting'});
    });

    test('ШАГ 4: правка НЕ стирает уже данные ответы', () {
      // Первая же правка места объявила бы ответивших заново ждущими, а
      // ответ принадлежит человеку, не документу.
      final data = eventEditUpdate(
        date: '2026-08-09T19:00:00.000',
        type: 'Toy',
        location: 'Bakı',
        notes: '',
        musicians: const ['a', 'b', 'c'],
        actorUid: _actor,
        previousAnswers: const {'a': 'cant', 'b': 'going'},
      );
      expect(data['answers'], {'a': 'cant', 'b': 'going', 'c': 'waiting'});
    });

    test('ни одного сохраняемого ключа в записи нет', () {
      final data = update();
      for (final key in kEventEditPreserves) {
        expect(
          data.containsKey(key),
          isFalse,
          reason: 'правка не должна трогать $key',
        );
      }
    });

    test('ключ состава зовётся musicians, а не participantUids', () {
      // Имя из модели (`participantUids`) в базе не существует. Запись под
      // ним оставила бы обе стороны без доступа к мероприятию: правило
      // чтения смотрит на `musicians`, и отказа при этом не возникло бы —
      // документ просто перестал бы находиться.
      final data = update();
      expect(data.containsKey('musicians'), isTrue);
      expect(data.containsKey('participantUids'), isFalse);
      expect(kEventDocKeys.contains('participantUids'), isFalse);
    });

    test('имя поступка — edited, не replaced', () {
      expect(update()['lastActionType'], 'edited');
      expect(kEventEdited, 'edited');
    });

    test('автор — тот, кто правит', () {
      expect(update()['lastActionBy'], _actor);
    });

    test('состав — копия, а не тот же список', () {
      final source = <String>['a'];
      final data = eventEditUpdate(
        date: '2026-08-09T19:00:00.000',
        type: 'Toy',
        location: '',
        notes: '',
        musicians: source,
        actorUid: _actor,
      );
      source.add('b');
      expect(data['musicians'], ['a']);
    });
  });

  group('N39 · при правке разрушительного ответа нет как случая', () {
    test('ИНВАРИАНТ: при правке ни один ответ не пишет в чужой документ', () {
      for (final exactTime in [true, false]) {
        for (final targetIsMine in [true, false]) {
          final answers = conflictAnswers(
            isEditing: true,
            exactTime: exactTime,
            targetIsMine: targetIsMine,
          );
          expect(
            answers.intersection(kAnswersTouchingOtherDoc),
            isEmpty,
            reason: 'правка, exactTime=$exactTime, targetIsMine=$targetIsMine',
          );
        }
      }
    });

    test('правка, занят день — 1 ответ, сохранить молча', () {
      final answers = conflictAnswers(
        isEditing: true,
        exactTime: false,
        targetIsMine: true,
      );
      expect(answers.length, 1);
      expect(answers, {ConflictAnswer.saveSilently});
      expect(conflictAsksHuman(answers), isFalse);
    });

    test('правка, минута в минуту — 1 ответ, запрет до сдвига', () {
      final answers = conflictAnswers(
        isEditing: true,
        exactTime: true,
        targetIsMine: true,
      );
      expect(answers.length, 1);
      expect(answers, {ConflictAnswer.blockUntilMoved});
      expect(conflictAsksHuman(answers), isFalse);
    });

    test('правка не зависит от того, чьё мешающее мероприятие', () {
      // Владение мешающего к правке отношения не имеет вовсе — именно
      // подмена этого вопроса и давала N39.
      for (final exactTime in [true, false]) {
        expect(
          conflictAnswers(
            isEditing: true,
            exactTime: exactTime,
            targetIsMine: true,
          ),
          conflictAnswers(
            isEditing: true,
            exactTime: exactTime,
            targetIsMine: false,
          ),
        );
      }
    });
  });

  group('N39 · при создании вопрос остаётся, ответов три', () {
    test('создание на своём — 3 ответа, в чужой документ пишет ровно 1', () {
      final answers = conflictAnswers(
        isEditing: false,
        exactTime: false,
        targetIsMine: true,
      );
      expect(answers.length, 3);
      expect(answers, {
        ConflictAnswer.view,
        ConflictAnswer.editExisting,
        ConflictAnswer.saveAnyway,
      });
      expect(answers.intersection(kAnswersTouchingOtherDoc).length, 1);
      expect(conflictAsksHuman(answers), isTrue);
    });

    test('создание на чужом — 3 ответа, «изменить существующее» нет', () {
      final answers = conflictAnswers(
        isEditing: false,
        exactTime: false,
        targetIsMine: false,
      );
      expect(answers.length, 3);
      expect(answers, {
        ConflictAnswer.view,
        ConflictAnswer.leaveForeign,
        ConflictAnswer.saveAnyway,
      });
      // Переписать чужое нельзя по правам: `update` в personalEvents
      // разрешён только владельцу. Кнопка, обещающая это, обещала бы
      // несделанное.
      expect(answers.contains(ConflictAnswer.editExisting), isFalse);
      expect(answers.intersection(kAnswersTouchingOtherDoc).length, 1);
    });

    test('при создании точная минута не меняет НАБОР ответов', () {
      for (final targetIsMine in [true, false]) {
        expect(
          conflictAnswers(
            isEditing: false,
            exactTime: true,
            targetIsMine: targetIsMine,
          ),
          conflictAnswers(
            isEditing: false,
            exactTime: false,
            targetIsMine: targetIsMine,
          ),
        );
      }
    });
  });

  group('имя совпадает с поступком', () {
    test('три имени — три разных действия', () {
      expect(
        conflictAnswerLabel(ConflictAnswer.editExisting),
        'Mövcud tədbiri dəyiş',
      );
      expect(
        conflictAnswerLabel(ConflictAnswer.leaveForeign),
        'Təqvimimdən sil',
      );
      expect(conflictAnswerLabel(ConflictAnswer.saveAnyway), 'Yeni tədbir');
    });

    test('«Əvəz et» не осталось ни на одном ответе', () {
      for (final answer in ConflictAnswer.values) {
        expect(conflictAnswerLabel(answer), isNot('Əvəz et'));
      }
    });

    test('у каждого ответа своё имя — одинаковых нет', () {
      final labels = ConflictAnswer.values.map(conflictAnswerLabel).toSet();
      expect(labels.length, ConflictAnswer.values.length);
    });
  });
}
