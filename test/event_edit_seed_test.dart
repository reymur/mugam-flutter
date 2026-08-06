import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_edit.dart';

// N46 — чем заполняется форма правки, открытая ответом «Mövcud tədbiri
// dəyiş».
//
// Найдено 06.08 на устройстве: ответ писал в цель содержимым формы
// СОЗДАНИЯ, которая о цели не знает ничего. У договора стёрлись заметки
// «Qalstuk, Qara kostyum və ağ köynək» — пустотой, которую никто не вводил.
//
// Здесь проверяется правило засева. Тестов на каждое поле по два: что
// нетронутое приходит из цели и что тронутое приходит из формы. Второй
// нужен не меньше первого — правило «всегда брать из цели» прошло бы
// первую половину и сделало бы форму нередактируемой.

const targetPeople = ['teymur', 'ramil'];
const formPeople = ['sevgi'];

final _picked = DateTime(2026, 8, 9, 21, 0);
final _targetDate = DateTime(2026, 8, 10, 17, 20);

EventEditSeed seed({EventFormTouched touched = EventFormTouched.none}) =>
    seedForEdit(
      pickedDate: _picked,
      targetType: 'Konsert',
      targetLocation: 'Neon',
      targetNotes: 'Qalstuk, Qara kostyum və ağ köynək',
      targetParticipantUids: targetPeople,
      formType: 'Toy',
      formLocation: '',
      formNotes: '',
      formParticipantUids: formPeople,
      touched: touched,
    );

void main() {
  group('ВТОРОЙ ИНВАРИАНТ: ключ, которого человек не трогал, равен цели', () {
    // Тот самый инвариант, ради которого правило и вынесено. Проверяется
    // разом по всем четырём полям: правка, забывшая одно из них, обязана
    // ронять именно этот тест, а не «какой-нибудь».
    test('не тронуто ничего — всё, кроме даты, приходит из цели', () {
      final s = seed();
      expect(s.type, 'Konsert');
      expect(s.location, 'Neon');
      expect(s.notes, 'Qalstuk, Qara kostyum və ağ köynək');
      expect(s.participantUids, targetPeople);
    });

    test('пустая форма НЕ затирает непустую цель — это и есть находка', () {
      // Дословно сегодняшний случай: в форме создания заметки пусты,
      // потому что человек их не открывал. До починки эта пустота
      // уезжала в договор.
      expect(seed().notes, isNotEmpty);
      expect(seed().location, isNotEmpty);
    });
  });

  group('дата — всегда из колеса, правило «тронул» на неё не действует', () {
    test('нетронутая форма всё равно отдаёт дату колеса, а не цели', () {
      // Дата не одно из полей, а сам повод для хода: «перенеси стоящее
      // СЮДА». Возьми мы её из цели — ход перестал бы что-либо делать.
      expect(seed().date, _picked);
      expect(seed().date, isNot(_targetDate));
    });
  });

  group('тронутое приходит из формы — по одному полю за тест', () {
    test('тип', () {
      final s = seed(touched: const EventFormTouched(type: true));
      expect(s.type, 'Toy');
      // Соседи при этом не сдвинулись: признаки раздельные, а не общий
      // «форму трогали».
      expect(s.location, 'Neon');
      expect(s.notes, isNotEmpty);
      expect(s.participantUids, targetPeople);
    });

    test('место, в том числе стёртое намеренно', () {
      // Пустая строка от человека — законное значение: место у
      // мероприятия можно и убрать. Отличить её от «не трогал» способен
      // только явный признак, и в этом весь смысл его существования.
      final s = seed(touched: const EventFormTouched(location: true));
      expect(s.location, '');
      expect(s.notes, isNotEmpty);
    });

    test('заметки', () {
      final s = seed(touched: const EventFormTouched(notes: true));
      expect(s.notes, '');
      expect(s.location, 'Neon');
    });

    test('состав', () {
      final s = seed(touched: const EventFormTouched(participants: true));
      expect(s.participantUids, formPeople);
      expect(s.type, 'Konsert');
    });
  });

  group('состав — соглашение цели сохраняется само (N30, вариант «а»)', () {
    test('владелец, лежащий в составе договора, не выпадает', () {
      // Договор из согласованного предложения кладёт в musicians владельца
      // И вторую сторону; форма живёт по календарному соглашению
      // «выбранные, без себя». Правка нетронутого состава обязана
      // оставить соглашение цели, а не подменить его своим.
      final s = seedForEdit(
        pickedDate: _picked,
        targetType: 'Toy',
        targetLocation: '',
        targetNotes: '',
        targetParticipantUids: const ['rafael-owner', 'teymur'],
        formType: 'Toy',
        formLocation: '',
        formNotes: '',
        formParticipantUids: const ['teymur'],
        touched: EventFormTouched.none,
      );
      expect(s.participantUids, ['rafael-owner', 'teymur']);
    });
  });

  test('список — копия, а не ссылка на состояние закрывшейся формы', () {
    final live = <String>['teymur'];
    final s = seedForEdit(
      pickedDate: _picked,
      targetType: 'Toy',
      targetLocation: '',
      targetNotes: '',
      targetParticipantUids: const [],
      formType: 'Toy',
      formLocation: '',
      formNotes: '',
      formParticipantUids: live,
      touched: const EventFormTouched(participants: true),
    );
    live.add('kto-to-eshcho');
    expect(s.participantUids, ['teymur']);
  });
}
