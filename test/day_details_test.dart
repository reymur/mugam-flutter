import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/day_details.dart';

// КОПИРОВАНИЕ ДЕТАЛЕЙ — САМОЕ ОПАСНОЕ МЕСТО ЛИСТА, и потому проверено
// первым, до всякой разметки.
//
// Опасность не в том, что копирование сломается заметно, а в том, что оно
// СРАБОТАЕТ ЛИШНЕГО: пустое поле источника затрёт вписанное в другом дне.
// Поле выглядит одинаково пустым и до, и после — заметить потерю не по
// чему. Такую тихую потерю в этом проекте чинили пять раз.

const d14 = '2026-08-14';
const d15 = '2026-08-15';
const d20 = '2026-08-20';

void main() {
  group('копирование деталей в остальные дни', () {
    test('заполненные поля переносятся', () {
      final out = copyDetailsToDays(
        details: {
          d14: const DayDetails(
            time: '20:00',
            location: 'İnci Qarayev',
            dress: 'Qara kostyum',
          ),
        },
        fromDay: d14,
        selectedDays: [d14, d15, d20],
      );
      expect(out[d15]!.time, '20:00');
      expect(out[d20]!.location, 'İnci Qarayev');
      expect(out[d20]!.dress, 'Qara kostyum');
    });

    // ГЛАВНАЯ ПРОВЕРКА ФАЙЛА, и требование записано в коде словами:
    // копируется то, что человек ВПИСАЛ, а не то, чего он не вписал.
    //
    // Случай ровно тот, ради которого кнопка и нужна: время общее, место у
    // каждого своё.
    test('ПУСТОЕ поле источника НЕ затирает вписанное в другом дне', () {
      final out = copyDetailsToDays(
        details: {
          // У источника есть время и НЕТ места.
          d14: const DayDetails(time: '20:00'),
          // А у 20-го уже вписан свой зал.
          d20: const DayDetails(location: 'Şəhriyar'),
        },
        fromDay: d14,
        selectedDays: [d14, d15, d20],
      );
      expect(out[d20]!.time, '20:00', reason: 'время должно прийти');
      expect(
        out[d20]!.location,
        'Şəhriyar',
        reason: 'чужой зал стёрт пустотой источника — это и есть тихая потеря',
      );
    });

    test('день-источник не трогается', () {
      final out = copyDetailsToDays(
        details: {d14: const DayDetails(time: '20:00')},
        fromDay: d14,
        selectedDays: [d14, d15],
      );
      expect(out[d14]!.time, '20:00');
    });

    test('невыбранные дни не трогаются', () {
      final out = copyDetailsToDays(
        details: {d14: const DayDetails(time: '20:00')},
        fromDay: d14,
        selectedDays: [d14, d15],
      );
      expect(out.containsKey(d20), isFalse);
    });

    test('пустой источник не делает ничего', () {
      final before = {d20: const DayDetails(location: 'Şəhriyar')};
      final out = copyDetailsToDays(
        details: before,
        fromDay: d14,
        selectedDays: [d14, d20],
      );
      expect(out[d20]!.location, 'Şəhriyar');
      expect(out[d14], isNull);
    });

    test('голосовое переносится вместе с волной', () {
      final out = copyDetailsToDays(
        details: {
          d14: const DayDetails(voicePath: '/tmp/v1.m4a', voiceWaveform: [1, 2]),
        },
        fromDay: d14,
        selectedDays: [d14, d15],
      );
      expect(out[d15]!.voicePath, '/tmp/v1.m4a');
      expect(out[d15]!.voiceWaveform, [1, 2]);
    });

    test('отсутствие голоса у источника не стирает чужой голос', () {
      final out = copyDetailsToDays(
        details: {
          d14: const DayDetails(time: '20:00'),
          d20: const DayDetails(voicePath: '/tmp/own.m4a'),
        },
        fromDay: d14,
        selectedDays: [d14, d20],
      );
      expect(out[d20]!.voicePath, '/tmp/own.m4a');
    });
  });

  group('число дней для вопроса', () {
    // Человек видит цифру ДО нажатия: «Bu detallar N günə köçürüləcək».
    test('считает все выбранные, кроме источника', () {
      expect(
        copyTargetCount(selectedDays: [d14, d15, d20], fromDay: d14),
        2,
      );
    });

    test('один выбранный день — копировать некуда', () {
      expect(copyTargetCount(selectedDays: [d14], fromDay: d14), 0);
    });
  });

  group('временные файлы записей', () {
    // Множеством: после копирования один файл принадлежит нескольким дням,
    // а удалять его дважды незачем.
    test('одна запись на нескольких днях считается один раз', () {
      final files = voiceFilesIn({
        d14: const DayDetails(voicePath: '/tmp/a.m4a'),
        d15: const DayDetails(voicePath: '/tmp/a.m4a'),
        d20: const DayDetails(voicePath: '/tmp/b.m4a'),
      });
      expect(files, {'/tmp/a.m4a', '/tmp/b.m4a'});
    });

    test('дни без записи ничего не добавляют', () {
      expect(voiceFilesIn({d14: const DayDetails(time: '20:00')}), isEmpty);
    });
  });

  group('пустота дня', () {
    test('день без единого поля пуст', () {
      expect(const DayDetails().isEmpty, isTrue);
    });

    // От этого зависит, раскроется ли «Ətraflı» сразу: день с деталями
    // открыт, пустой — свёрнут.
    test('любое одно поле делает день непустым', () {
      expect(const DayDetails(time: '20:00').isNotEmpty, isTrue);
      expect(const DayDetails(location: 'x').isNotEmpty, isTrue);
      expect(const DayDetails(dress: 'x').isNotEmpty, isTrue);
      expect(const DayDetails(voicePath: '/tmp/a').isNotEmpty, isTrue);
    });
  });
}
