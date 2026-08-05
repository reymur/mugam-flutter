import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_edit.dart';

// Два правила, найденные глазами на устройстве и не имевшие теста вовсе.
//
// N40 — «Əvəz et» обещала замену, а делала удаление с созданием нового
// документа. Проверяется не поведением экрана, а АРИФМЕТИКОЙ: 7
// переписываемых плюс 13 сохраняемых обязаны дать ровно 20 ключей
// документа и ни одним больше. Пока сумма сходится, поле не может тихо
// выпасть из рассмотрения — ни новое, ни перенесённое из одной половины в
// другую.
//
// N39 — при правке окно конфликта предлагало снести постороннее
// мероприятие. Проверяется одной строкой: при правке ни один допустимый
// ответ не пишет в чужой документ.

const _actor = 'actor-uid';

void main() {
  group('N40 · арифметика полей', () {
    test('переписываемых ровно 7', () {
      expect(kEventEditWrites.length, 7);
    });

    test('сохраняемых ровно 13', () {
      expect(kEventEditPreserves.length, 13);
    });

    test('пересечение пусто — ни одно поле не в обеих половинах', () {
      expect(kEventEditWrites.intersection(kEventEditPreserves), isEmpty);
    });

    test('объединение — ровно 20 ключей документа, без лишних и без дыр', () {
      final union = {...kEventEditWrites, ...kEventEditPreserves};
      expect(union.length, 20);
      expect(kEventDocKeys.length, 20);
      expect(union, kEventDocKeys);
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

    test('пишет ровно 7 ключей и ровно тех', () {
      final data = update();
      expect(data.length, 7);
      expect(data.keys.toSet(), kEventEditWrites);
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
