import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/shared/widgets/event_notes_picker.dart';

// Заметки события (форма одежды + свободный текст) хранятся ОДНОЙ строкой,
// склеенной через `', '`. Пишет её лист предложения работы, а разбирает
// карточка договора в календаре — то есть склейка и разбор живут в разных
// экранах и обязаны сходиться.
//
// Проверяется здесь именно СХОДИМОСТЬ, а не отдельно склейка и отдельно
// разбор: сломать их можно только вместе, и заметно это станет не ошибкой,
// а тем, что выбранная галочка молча уедет в свободный текст. Ровно то,
// что случилось бы, скопируй мы список пунктов вместо общего виджета.
void main() {
  group('склейка и разбор сходятся', () {
    test('пустая строка — пустое значение в обе стороны', () {
      const v = EventNotesValue();
      expect(v.joined, '');
      expect(EventNotesValue.parse('').joined, '');
      expect(EventNotesValue.parse('').options, isEmpty);
    });

    test('только галочки — разбираются обратно ровно в те же', () {
      const v = EventNotesValue(
        options: ['Qalstuk', 'Baboçka'],
      );
      final back = EventNotesValue.parse(v.joined);
      expect(back.options, ['Qalstuk', 'Baboçka']);
      expect(back.freeNote, '');
      expect(back.joined, v.joined);
    });

    test('все пункты разом переживают круг', () {
      final v = EventNotesValue(options: List.of(dressCodeChoices));
      final back = EventNotesValue.parse(v.joined);
      expect(back.options, dressCodeChoices);
      expect(back.freeNote, '');
    });

    test('галочка плюс свободный текст — не путаются местами', () {
      const v = EventNotesValue(
        options: ['Qara kostyum və ağ köynək'],
        freeNote: 'saat 19-da gəlin',
      );
      final back = EventNotesValue.parse(v.joined);
      expect(back.options, ['Qara kostyum və ağ köynək']);
      expect(back.freeNote, 'saat 19-da gəlin');
    });

    test('свободный текст с запятой переживает круг целиком', () {
      // Разделитель тот же, что внутри текста, поэтому строка при разборе
      // распадается — и собирается обратно тем же разделителем. Свойство
      // зафиксировано намеренно: оно неочевидно, и «починка» разделителя
      // сломала бы уже сохранённые заметки.
      const v = EventNotesValue(freeNote: 'əvvəl bir mahnı, sonra rəqs');
      final back = EventNotesValue.parse(v.joined);
      expect(back.freeNote, 'əvvəl bir mahnı, sonra rəqs');
      expect(back.options, isEmpty);
    });

    test('текст из «Digər…» при разборе становится свободной заметкой', () {
      // Различить их обратно нечем — в базе лежит одна строка без пометок
      // о происхождении частей. Человеку важен свой текст, а не поле, куда
      // он его когда-то ввёл.
      const v = EventNotesValue(
        options: ['Qalstuk'],
        otherExpanded: true,
        otherNote: 'ağ əlcək',
      );
      final back = EventNotesValue.parse(v.joined);
      expect(back.options, ['Qalstuk']);
      expect(back.freeNote, 'ağ əlcək');
      expect(back.otherExpanded, isFalse);
      // Строка при этом не изменилась — повторное сохранение без правок
      // ничего не переставляет.
      expect(back.joined, v.joined);
    });

    test('невыбранное «Digər…» в строку не попадает', () {
      const v = EventNotesValue(
        options: ['Qalstuk'],
        otherExpanded: false,
        otherNote: 'этого в базе быть не должно',
      );
      expect(v.joined, 'Qalstuk');
    });
  });

  group('строка из предложения работы читается календарём', () {
    test('то, что отправил лист, карточка узнаёт как галочки', () {
      // Именно этот случай ломается молча при копии списка вместо общего
      // виджета: договор создаётся ИЗ предложения, а правится в календаре.
      const fromOffer = EventNotesValue(
        options: ['Qara köynək sərbəst', 'Baboçka'],
        freeNote: 'restoranda',
      );
      final stored = fromOffer.joined;

      final inCalendar = EventNotesValue.parse(stored);
      expect(inCalendar.options, ['Qara köynək sərbəst', 'Baboçka']);
      expect(inCalendar.freeNote, 'restoranda');
      // И обратно — правка в календаре читается предложением так же.
      expect(EventNotesValue.parse(inCalendar.joined).options,
          inCalendar.options);
    });

    test('неизвестный пункт не теряется, а падает в свободный текст', () {
      // Страховка на случай, если список пунктов когда-нибудь всё же
      // сократят: сохранённое значение обязано остаться видимым человеку,
      // пусть и не галочкой.
      final back = EventNotesValue.parse('Смокинг, Qalstuk');
      expect(back.options, ['Qalstuk']);
      expect(back.freeNote, 'Смокинг');
      expect(back.joined, 'Qalstuk, Смокинг');
    });
  });
}
