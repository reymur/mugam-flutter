import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/core/agreements/leave_note.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ПРИЧИНА ВЫХОДА — В САМОМ ВЕЧЕРЕ, ТОЛЬКО ВЛАДЕЛЬЦУ (решение 13.09).
//
// Таблица утверждает НАЛИЧИЕ, поэтому сама себе канарейка (I31): ослепни
// разбор или правило, список ожидаемого не совпадёт и тест покраснеет.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46; сверяется поимённо):
//   • `offersLeaveNote` без `viewerUid == ownerUid` — «участнику состава
//     знак не показывается», один тест;
//   • `leaveEventUpdate` без ключа причины — «выход с причиной — одна
//     запись, два ключа», один тест;
//   • `PersonalEvent.fromFirestore` читает не то поле — «вечер отдаёт
//     причину по uid», один тест. «Чужой тип в поле» при этом ЗЕЛЁНЫЙ: он
//     ждёт `null`, и слепое чтение отдаёт ему ровно `null`. Первая редакция
//     этой строки обещала два — пересчитано до порчи (I46).
//
// ЧЕГО НЕ ЛОВИТ: показывает ли разметка знак по этому правилу (сторож на
// проводку — `source_invariants_test.dart`), дошла ли запись до базы и
// пускают ли её правила (`functions/test`).

const _owner = 'owner';
const _leaver = 'leaver';
const _other = 'other';

PersonalEvent _event(Map<String, dynamic> extra) =>
    PersonalEvent.fromFirestore('ev', {
      'ownerUid': _owner,
      'musicians': [_leaver, _other],
      'date': '2026-09-20T19:00:00.000',
      'type': 'Toy',
      'location': '',
      'notes': '',
      ...extra,
    });

void main() {
  group('форма причины: текст и голос лежат рядом', () {
    test('текст и голос вместе переживают запись и чтение', () {
      const note = LeaveNote(
        text: 'Toyum var o gün',
        voiceUrl: 'https://example/voice',
        voiceWaveform: [3, 50, 100],
      );
      final back = LeaveNote.fromMap(note.toMap());
      expect(back, isNotNull);
      expect(back!.text, 'Toyum var o gün');
      expect(back.voiceUrl, 'https://example/voice');
      expect(back.voiceWaveform, [3, 50, 100]);
    });

    test('только голос — без ключа текста; только текст — без ключей голоса',
        () {
      expect(
        const LeaveNote(voiceUrl: 'u', voiceWaveform: [1]).toMap().keys.toSet(),
        {'voiceUrl', 'voiceWaveform'},
      );
      expect(const LeaveNote(text: 'söz').toMap().keys.toSet(), {'text'});
    });

    test('пробелы причиной не считаются', () {
      expect(const LeaveNote(text: '   ').isEmpty, isTrue);
      expect(LeaveNote.fromMap({'text': '  '}), isNull);
    });

    test('чужой тип внутри причины читается как отсутствие, а не падение', () {
      expect(LeaveNote.fromMap({'text': 42, 'voiceUrl': 7}), isNull);
      expect(LeaveNote.fromMap('строка'), isNull);
    });
  });

  group('запись выхода', () {
    test('выход с причиной — одна запись, два ключа', () {
      final data = leaveEventUpdate(
        uid: _leaver,
        note: const LeaveNote(text: 'Maşın xarab oldu'),
      );
      expect(data, {
        'answers.$_leaver': kAnswerLeft,
        'leaveNotes.$_leaver': {'text': 'Maşın xarab oldu'},
      });
    });

    test('без причины — только ответ, ключ причины не заводится', () {
      expect(leaveEventUpdate(uid: _leaver, note: null),
          {'answers.$_leaver': kAnswerLeft});
      expect(
          leaveEventUpdate(uid: _leaver, note: const LeaveNote(text: ' ')),
          {'answers.$_leaver': kAnswerLeft});
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

  group('вечер читает причину — прод-путём, через fromFirestore (I55)', () {
    test('вечер отдаёт причину по uid', () {
      final e = _event({
        'answers': {_leaver: kAnswerLeft},
        'leaveNotes': {
          _leaver: {
            'text': 'Toyum var',
            'voiceUrl': 'https://example/v',
            'voiceWaveform': [10, 20],
          },
        },
      });
      final n = e.leaveNoteFor(_leaver);
      expect(n, isNotNull);
      expect(n!.text, 'Toyum var');
      expect(n.voiceUrl, 'https://example/v');
      expect(n.voiceWaveform, [10, 20]);
      expect(e.leaveNoteFor(_other), isNull);
    });

    test('чужой тип в поле не роняет вечер', () {
      final e = _event({'leaveNotes': 'не карта'});
      expect(e.leaveNoteFor(_leaver), isNull);
      expect(e.leaveNotesForRewrite(), isNull);
    });
  });

  group('путь записи и правка состава', () {
    test('запись голоса лежит в своей папке вечера, а не в папке чата', () {
      expect(leaveNoteVoicePath(eventId: 'ev1', uid: 'u1'),
          'event_leave_notes/ev1/u1');
    });

    test('правка оставляет причины только оставшимся', () {
      final kept = leaveNotesForParticipants(
        const [_other],
        {
          _leaver: const LeaveNote(text: 'getdim'),
          _other: const LeaveNote(text: 'qalıram'),
        },
      );
      expect(kept, {
        _other: {'text': 'qalıram'},
      });
      expect(leaveNotesForParticipants(const [_other], null), isNull);
    });
  });
}
