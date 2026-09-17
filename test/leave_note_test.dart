import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/core/agreements/leave_note.dart';

// ПРИЧИНА ВЫХОДА — СВОЙ ДОКУМЕНТ ПРИ ВЕЧЕРЕ, ТОЛЬКО ВЛАДЕЛЬЦУ (13.09; 17.09).
//
// Таблица утверждает НАЛИЧИЕ, поэтому сама себе канарейка (I31): ослепни
// разбор или правило, список ожидаемого не совпадёт и тест покраснеет.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46; сверяется поимённо):
//   • `offersLeaveNote` без `viewerUid == ownerUid` — «участнику состава
//     знак не показывается», один тест;
//   • `leaveEventWrites` отдаёт `note: null` всегда — «выход с причиной —
//     пачка из двух: ответ в вечер, причина в свой документ», один тест.
//     «Без причины — только ответ» при этом ЗЕЛЁНЫЙ: он и ждёт `null`;
//   • `LeaveNote.fromMap` снова читает `voiceUrl` как голос — «старая форма
//     voiceUrl голосом НЕ считается», один тест;
//   • `removedLeaveNoteUids` возвращает оставшихся вместо убранных —
//     «правка состава удаляет документы причин только у убранных» здесь и
//     «крестик удаляет документ причины удалённого, оставшегося не трогает»
//     в `event_edit_test.dart`. ДВА теста: правило зовут оба.
//
// ЧЕГО НЕ ЛОВИТ: показывает ли разметка знак по этому правилу (сторож на
// проводку — `source_invariants_test.dart`), дошла ли пачка до базы и
// пускают ли её правила (`functions/test/leave-notes-rules.test.ts`).

const _owner = 'owner';
const _leaver = 'leaver';
const _other = 'other';

void main() {
  group('форма причины: текст и голос лежат рядом', () {
    test('текст и голос вместе переживают запись и чтение', () {
      const note = LeaveNote(
        text: 'Toyum var o gün',
        hasVoice: true,
        voiceWaveform: [3, 50, 100],
      );
      final back = LeaveNote.fromMap(note.toMap());
      expect(back, isNotNull);
      expect(back!.text, 'Toyum var o gün');
      expect(back.hasVoice, isTrue);
      expect(back.voiceWaveform, [3, 50, 100]);
    });

    test('только голос — без ключа текста; только текст — без ключей голоса',
        () {
      expect(
        const LeaveNote(hasVoice: true, voiceWaveform: [1]).toMap().keys.toSet(),
        {'hasVoice', 'voiceWaveform'},
      );
      expect(const LeaveNote(text: 'söz').toMap().keys.toSet(), {'text'});
    });

    test('пробелы причиной не считаются', () {
      expect(const LeaveNote(text: '   ').isEmpty, isTrue);
      expect(LeaveNote.fromMap({'text': '  '}), isNull);
    });

    test('чужой тип внутри причины читается как отсутствие, а не падение', () {
      expect(LeaveNote.fromMap({'text': 42, 'hasVoice': 'да'}), isNull);
      expect(LeaveNote.fromMap('строка'), isNull);
    });

    // ЗАПАСНОЙ ХОД СНЯТ 17.09. Здесь стояли три вердикта «старая форма
    // `voiceUrl` читается как голос» — ради записей переходного периода N236.
    // По закону стройки их стирают, а правило такую форму больше не пускает.
    // Этот вердикт — обратный: вернись чтение ссылки, и в показ снова начнут
    // приходить записи с токеном.
    test('старая форма voiceUrl голосом НЕ считается — запасной ход снят', () {
      expect(
        LeaveNote.fromMap({
          'voiceUrl': 'https://firebasestorage.googleapis.com/v0/b/x?token=y',
          'voiceWaveform': [3, 50],
        }),
        isNull,
      );
      // Канарейка (I31): тот же разбор видит голос новой формы — значит
      // `null` выше означает «ссылку не читаем», а не «разбор ослеп».
      expect(
        LeaveNote.fromMap({'hasVoice': true, 'voiceWaveform': [3, 50]})?.hasVoice,
        isTrue,
      );
    });
  });

  group('запись выхода', () {
    test('выход с причиной — пачка из двух: ответ в вечер, причина в свой '
        'документ', () {
      final writes = leaveEventWrites(
        uid: _leaver,
        note: const LeaveNote(text: 'Maşın xarab oldu'),
      );
      expect(writes.eventUpdate, {'answers.$_leaver': kAnswerLeft});
      expect(writes.note, {'text': 'Maşın xarab oldu'});
      // В документ вечера причина не пишется больше ни ключом, ни полем.
      expect(
        writes.eventUpdate.keys.where((k) => k.startsWith('leaveNotes')),
        isEmpty,
      );
    });

    test('без причины — только ответ, документа причины нет', () {
      for (final note in [null, const LeaveNote(text: ' ')]) {
        final writes = leaveEventWrites(uid: _leaver, note: note);
        expect(writes.eventUpdate, {'answers.$_leaver': kAnswerLeft});
        expect(writes.note, isNull);
      }
    });
  });

  group('кому показывается знак «?»', () {
    const note = LeaveNote(text: 'səbəb');

    test('владельцу у вышедшего с причиной — показывается', () {
      expect(
        offersLeaveNote(
          viewerUid: _owner,
          memberUid: _leaver,
          ownerUid: _owner,
          answer: kAnswerLeft,
          note: note,
        ),
        isTrue,
      );
    });

    test('участнику состава знак не показывается', () {
      expect(
        offersLeaveNote(
          viewerUid: _other,
          memberUid: _leaver,
          ownerUid: _owner,
          answer: kAnswerLeft,
          note: note,
        ),
        isFalse,
      );
    });

    test('самому вышедшему знак не показывается', () {
      expect(
        offersLeaveNote(
          viewerUid: _leaver,
          memberUid: _leaver,
          ownerUid: _leaver,
          answer: kAnswerLeft,
          note: note,
        ),
        isFalse,
      );
    });

    test('у не вышедшего и без причины знака нет', () {
      for (final a in [kAnswerGoing, kAnswerWaiting, kAnswerCant, null]) {
        expect(
          offersLeaveNote(
            viewerUid: _owner,
            memberUid: _leaver,
            ownerUid: _owner,
            answer: a,
            note: note,
          ),
          isFalse,
          reason: 'ответ $a',
        );
      }
      expect(
        offersLeaveNote(
          viewerUid: _owner,
          memberUid: _leaver,
          ownerUid: _owner,
          answer: kAnswerLeft,
          note: null,
        ),
        isFalse,
      );
    });
  });

  group('причины читаются прод-путём — из документов подколлекции (I55)', () {
    // `FirestoreService.watchLeaveNotes` отдаёт документы именно так: id —
    // uid автора, данные — карта документа. Разбор тот же, что у прода.
    test('причина читается прод-путём — из документа подколлекции', () {
      final notes = leaveNotesFromDocs([
        const MapEntry(_leaver, {
          'text': 'Toyum var',
          'hasVoice': true,
          'voiceWaveform': [10, 20],
        }),
        const MapEntry(_other, {'text': '   '}),
        const MapEntry('', {'text': 'ничья'}),
        const MapEntry('broken', 'не карта'),
      ]);
      expect(notes.keys.toSet(), {_leaver},
          reason: 'пустая причина, документ без id и чужой тип — не причины');
      final n = notes[_leaver]!;
      expect(n.text, 'Toyum var');
      expect(n.hasVoice, isTrue);
      expect(n.voiceWaveform, [10, 20]);
    });

    test('запрашивает причины только владелец', () {
      expect(requestsLeaveNotes(viewerUid: _owner, ownerUid: _owner), isTrue);
      expect(requestsLeaveNotes(viewerUid: _leaver, ownerUid: _owner), isFalse);
      expect(requestsLeaveNotes(viewerUid: '', ownerUid: ''), isFalse);
    });
  });

  group('путь записи и правка состава', () {
    test('запись голоса лежит в своей папке вечера, а не в папке чата', () {
      expect(leaveNoteVoicePath(eventId: 'ev1', uid: 'u1'),
          'event_leave_notes/ev1/u1');
    });

    test('правка состава удаляет документы причин только у убранных', () {
      // Крестик: убранный уносит свою причину той же пачкой. Оставшихся
      // правка не касается вовсе — ни чтением, ни перезаписью. Здесь стояли
      // вердикты N237 «правка не теряет голос новой формы»: правка больше не
      // пересобирает причины, и терять ей нечем.
      expect(
        removedLeaveNoteUids(
          previousParticipants: const [_leaver, _other],
          participants: const [_other],
        ),
        [_leaver],
      );
      // Добавленный — не убранный; неизменный состав — удалять некого.
      expect(
        removedLeaveNoteUids(
          previousParticipants: const [_other],
          participants: const [_other, _leaver],
        ),
        isEmpty,
      );
    });
  });
}
