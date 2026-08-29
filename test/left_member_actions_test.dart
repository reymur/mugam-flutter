import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/core/agreements/left_member_actions.dart';

// КНОПКА «?» У ВЫШЕДШЕГО УЧАСТНИКА — таблица «состояние × роль → какие
// действия предложены» (I32).
//
// I32 сказано прямо: сторожа на порядок ветвей в разметке нет и быть не может.
// Выразимо СЛЕДСТВИЕ — вот эта таблица. Она утверждает наличие, значит сама
// себе канарейка (I31): ослепни правило, список станет пустым, а пустой не
// равен ожидаемым двум.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46):
//   • снять `viewerUid == ownerUid` — упадёт «участнику не показывается»,
//     один тест;
//   • снять `viewerUid != memberUid` — упадёт «на самом себе не
//     показывается», один тест;
//   • заменить `kAnswerLeft` на `kAnswerCant` — упадут «вышедшему
//     показывается» и «у остальных четырёх ответов», два теста;
//   • выбросить второе действие из списка — упадут «действий ровно два» и
//     «удаление названо своим последствием», два теста.

const _owner = 'owner-uid';
const _member = 'member-uid';

void main() {
  group('кому и когда предложено окошко', () {
    test('владельцу у ВЫШЕДШЕГО — да', () {
      expect(
        offersLeftMemberRemoval(
          viewerUid: _owner,
          memberUid: _member,
          ownerUid: _owner,
          answer: kAnswerLeft,
        ),
        isTrue,
      );
    });

    test('участнику у вышедшего — НЕТ, состав правит владелец', () {
      // Ход необратим и меняет ОБЩИЙ список. Дай его любому смотрящему, и
      // вечер потеряет человека по нажатию того, кто его не звал.
      expect(
        offersLeftMemberRemoval(
          viewerUid: 'someone-else',
          memberUid: _member,
          ownerUid: _owner,
          answer: kAnswerLeft,
        ),
        isFalse,
      );
    });

    test('НА САМОМ СЕБЕ — нет, даже владельцу и даже с ответом left', () {
      // Владелец лежит в составе собственного вечера (18 документов из 75,
      // перепись 10.08 — N112), значит строка с его именем там есть. Без
      // этого условия «Dəqiqləşdir» открыл бы чат с самим собой, а
      // «Siyahıdan sil» вычеркнул бы владельца из его же вечера.
      expect(
        offersLeftMemberRemoval(
          viewerUid: _owner,
          memberUid: _owner,
          ownerUid: _owner,
          answer: kAnswerLeft,
        ),
        isFalse,
      );
    });

    test('пустые uid не считаются совпадением', () {
      // Незалогиненный смотрящий и вечер без владельца дали бы `'' == ''`,
      // то есть «я владелец» и «это не я» разом. Пустая строка не человек.
      expect(
        offersLeftMemberRemoval(
          viewerUid: '',
          memberUid: _member,
          ownerUid: '',
          answer: kAnswerLeft,
        ),
        isFalse,
      );
    });

    test('владельцу у ОСТАЛЬНЫХ ЧЕТЫРЁХ ответов — нет, поимённо', () {
      // Поимённо, а не одним «прочее»: недосчитать список незаметно нельзя,
      // он сам называет, кого не хватает (I13 — состав, а не количество).
      for (final answer in [
        kAnswerGoing,
        kAnswerWaiting,
        kAnswerCant,
        kAnswerNotAsked,
        null,
      ]) {
        expect(
          offersLeftMemberRemoval(
            viewerUid: _owner,
            memberUid: _member,
            ownerUid: _owner,
            answer: answer,
          ),
          isFalse,
          reason: 'ответ $answer — не выход из состава',
        );
      }
    });
  });

  group('что предложено в окошке', () {
    test('действий ровно ДВА, и оба названы', () {
      final actions = leftMemberActions(name: 'Teymur');
      expect(actions.length, 2);
      expect(actions.map((a) => a.deed), [
        kLeftActionClarify,
        kLeftActionRemove,
      ]);
      expect(actions.map((a) => a.label), ['Dəqiqləşdir', 'Siyahıdan sil']);
    });

    test('РАЗГОВОР ПЕРВЫЙ, удаление второе', () {
      // Порядок не косметика: удаление отнимает доступ к мероприятию, после
      // него спросить уже не выйдет — собеседник перестанет видеть предмет
      // разговора. Обратимое стоит раньше необратимого.
      expect(leftMemberActions().first.deed, kLeftActionClarify);
    });

    test('удаление названо своим ПОСЛЕДСТВИЕМ, а не пересказом надписи', () {
      // Состав и право видеть — одно поле в базе. Приписка, повторяющая
      // кнопку, была бы N109 в миниатюре: место занято, сообщено ничего.
      final remove = leftMemberActions(
        name: 'Teymur',
      ).firstWhere((a) => a.deed == kLeftActionRemove);
      expect(remove.note, contains('Teymur'));
      expect(remove.note, isNot(contains(remove.label)));
    });

    test('без имени — безлично, а не «null»', () {
      for (final name in [null, '']) {
        final remove = leftMemberActions(
          name: name,
        ).firstWhere((a) => a.deed == kLeftActionRemove);
        expect(remove.note, isNot(contains('null')));
        expect(remove.note.isNotEmpty, isTrue);
      }
    });

    test('у КАЖДОГО действия последствие сказано до нажатия', () {
      for (final a in leftMemberActions(name: 'Teymur')) {
        expect(a.note.isNotEmpty, isTrue, reason: 'у ${a.deed} нет приписки');
      }
    });
  });
}
