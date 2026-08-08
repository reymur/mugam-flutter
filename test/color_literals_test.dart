import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// N66 / работа 5б — цвет, написанный числом, не связан ни с чем.
//
// `Color(0xFF1A0E00)` — тёмно-коричневый текст НА ЗОЛОТОЙ кнопке — жил
// 64 копиями россыпью, и ни одной в `colors.dart`. Он обязан меняться
// ВМЕСТЕ с золотом: уедет `kGold` — и на новой заливке останется старый
// коричневый, причём **пятнами**: там, где копию пропустили. Каждая копия
// по отдельности выглядит правильной.
//
// 08.08 он сведён в `kOnGold` (60 замен плюс четыре приватных дубля).
// Осталось 39 мест с другими значениями, они разбираются следующими
// шагами.
//
// ЧТО ЭТОТ СТОРОЖ ДЕЛАЕТ. Он держит СОСТАВ остатка, а не его количество:
// новый литерал не пройдёт, и снятый тоже не пройдёт молча — список надо
// будет поправить. «Стало на один меньше» обязано быть видно в diff, а не
// раствориться в счётчике (I13: сверять состав, а не число).
//
// СУЖЕН ДО КОДА С ПЕРВОГО РАЗА (I12). Разбор этой самой находки —
// и здесь, и в `colors.dart`, и в `AUDIT_TODO.md` — состоит из тех же
// сочетаний, которые он запрещает. Сторож, сравнивающий текст целиком,
// первым делом отказал бы объяснению самого себя. Поэтому комментарии
// снимаются до разбора.

/// Остаток на 08.08: `путь|значение` → сколько раз.
///
/// Ключ — путь и ЗНАЧЕНИЕ, а не номер строки: правка выше по файлу
/// сдвигает строки, и список начал бы врать сам по себе. Хуже того, на
/// освободившийся номер съезжает соседняя строка и молча получает чужое
/// разрешение (урок из `guards_are_guards_test`).
const _known = <String, int>{
  'features/agreements/screens/agreements_screen.dart|Color(0xFFFF3B30)': 1,
  'features/chat/screens/about_contact_screen.dart|Color(0xFF4CAF50)': 1,
  'features/chat/screens/chat_screen.dart|Color(0xFF2196F3)': 2,
  'features/chat/screens/chat_screen.dart|Color(0xFF43A047)': 1,
  'features/chat/screens/chat_screen.dart|Color(0xFF4CAF50)': 1,
  'features/chat/screens/file_message_widgets.dart|Color(0xFF2196F3)': 1,
  'features/chat/screens/file_message_widgets.dart|Color(0xFF43A047)': 1,
  'features/chat/screens/file_message_widgets.dart|Color(0xFFE53935)': 1,
  'features/chat/screens/file_message_widgets.dart|Color(0xFFFB8C00)': 1,
  'features/chat/screens/location_message_widgets.dart|Color(0xFF007AFF)': 1,
  'features/chat/screens/location_message_widgets.dart|Color(0xFF33CCFF)': 1,
  'features/chat/screens/location_message_widgets.dart|Color(0xFFEA4335)': 2,
  'features/profile/screens/profile_screen.dart|Color(0x99000000)': 1,
  'features/status/screens/create_status_screen.dart|Color(0xFF2196F3)': 1,
  'shared/widgets/event_conflict_dialog.dart|Color(0xCC000000)': 1,
  'shared/widgets/topbar.dart|Color(0xFF8B5A00)': 1,
};

Map<String, int> _found() {
  final out = <String, int>{};
  final rx = RegExp(r'Color\(0x[0-9A-Fa-f]+\)');
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    if (f.path.endsWith('core/theme/colors.dart')) continue;
    for (final line in f.readAsStringSync().split('\n')) {
      // Комментарии снимаются ДО разбора — I12.
      if (line.trimLeft().startsWith('//')) continue;
      for (final m in rx.allMatches(line)) {
        final key = '${f.path.replaceFirst('lib/', '')}|${m.group(0)}';
        out[key] = (out[key] ?? 0) + 1;
      }
    }
  }
  return out;
}

void main() {
  group('цвет числом живёт только в colors.dart (N66, работа 5б)', () {
    test('kOnGold сведён: копий 0xFF1A0E00 в коде не осталось', () {
      final left = _found().keys.where((k) => k.contains('0xFF1A0E00'));
      expect(
        left,
        isEmpty,
        reason: 'Тёмно-коричневый на золотом снова написан числом. Он обязан '
            'меняться ВМЕСТЕ с kGold, а копия останется прежней и разойдётся '
            'пятнами: ${left.join(", ")}',
      );
    });

    test('состав остатка не изменился молча', () {
      final found = _found();

      // I13: если разбор перестанет находить что бы то ни было, сравнение
      // ниже сойдётся на двух пустых множествах и промолчит.
      expect(
        found,
        isNotEmpty,
        reason: 'разбор не нашёл ни одного литерала во всём lib/ — '
            'сломался он, а не исчезли литералы',
      );

      final added = found.keys.toSet().difference(_known.keys.toSet());
      final gone = _known.keys.toSet().difference(found.keys.toSet());
      expect(
        added,
        isEmpty,
        reason: 'Новый цвет написан числом мимо colors.dart:\n'
            '${added.join("\n")}',
      );
      expect(
        gone,
        isEmpty,
        reason: 'Литерал убран — это хорошо, но список в тесте надо '
            'поправить, чтобы убыль была видна в diff, а не растворилась:\n'
            '${gone.join("\n")}',
      );
      for (final e in _known.entries) {
        expect(
          found[e.key],
          e.value,
          reason: 'изменилось число вхождений для ${e.key}',
        );
      }
    });
  });
}
