import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// СТОРОЖ НА КЛАСС, А НЕ НА ПОЛЕ.
//
// 19.08 `offerId` потерялся по дороге в память телефона и не потерял
// ничего больше: круг перекладывания собран из РУКОПИСНЫХ списков полей, и
// поле, забытое в них, пропадает молча (N140). Починка одного `offerId`
// оставила бы ту же яму открытой для следующего поля.
//
// --- ПОЧЕМУ РАЗБОР ИСХОДНИКА, А НЕ КРУГ ЖИВОГО ОБЪЕКТА ---
//
// Круг объекта был бы честнее: положили сообщение со всеми полями,
// достали, сверили. **Но перечислить поля объекта в Flutter нечем** —
// отражения (`dart:mirrors`) в нём нет, и список пришлось бы писать рукой.
// Тогда у сторожа была бы ровно та болезнь, которую он сторожит: забыл
// поле в списке хранилища — забудешь и в списке теста, и оба смолчат.
//
// Поэтому список полей берётся ИЗ САМОГО `Message`, разбором `models.dart`.
// Дописал поле в модель — сторож потребует его в хранилище **сам**, без
// чьей-либо памяти. Это и есть то единственное, что здесь выразимо
// механически.
//
// --- ЧЕГО ЭТОТ СТОРОЖ НЕ ЛОВИТ (читать обязательно) ---
//
// 1. **`_reencode` он не проверяет.** Тот список — карта ФОРМЫ FIRESTORE, и
//    имена в нём другие: `replyToSenderName` лежит там как вложенное
//    `replyTo.senderName`. Сверка по имени поля дала бы ложную тревогу на
//    каждом поле цитаты. Эта треть круга держится тестом
//    `local_store_keeps_offer_link_test.dart` и чтением, а не сторожем.
// 2. **Он проверяет НАЛИЧИЕ ИМЕНИ, а не то, что значение доехало.** Поле,
//    записанное с опечаткой в ключе по обе стороны, он пропустит: имя-то
//    есть в обоих списках.
// 3. **Он не знает, какие поля хранить НЕ НАДО.** Такие перечислены ниже
//    руками, с доводом у каждого, и этот перечень — единственное место,
//    которое требует поддержки. Он маленький и растёт редко.
//
// Цена названа честно: сторож на список слабее круга живого объекта и
// сильнее, чем ничего. Он ловит ровно ту ошибку, которая уже случилась, —
// поле есть в модели и забыто в хранилище.

/// Поля, которые в память телефона класть НЕ НАДО. У каждого — довод, иначе
/// перечень превратится в свалку для всего, что мешает сторожу краснеть.
const _notPersisted = <String, String>{
  'localUploadProgress':
      'ход загрузки: возобновлённая отправка грузит файл заново, '
          'поэтому хранить старый процент значит показать несуществующее',
  'localPreviewBytes':
      'картинка предпросмотра в памяти: тяжёлая и восстановимая, '
          'место в постоянной памяти она занимать не должна',
};

/// Поля, которые хранятся под ДРУГИМ ключом. Не исключение из правила, а
/// перевод имени: значение доезжает, зовётся иначе.
const _storedAs = <String, String>{
  'timestamp': 'timestampMillis',
};

String _read(String path) => File(path).readAsStringSync();

/// Имена полей класса `Message`, снятые с самого класса.
List<String> _messageFields() {
  final src = _read('lib/firebase/models.dart');
  final start = src.indexOf('\nclass Message {');
  if (start < 0) {
    throw StateError('класс Message не найден в models.dart — разбор ослеп');
  }

  // До начала следующего класса верхнего уровня.
  final after = src.indexOf('\nclass ', start + 1);
  final body = after == -1 ? src.substring(start) : src.substring(start, after);

  final names = <String>[];
  for (final line in body.split('\n')) {
    if (!line.startsWith('  final ')) continue;
    // Отрезаем хвостовой комментарий и точку с запятой, берём последнее
    // слово: тип бывает составным (`Map<String, List<String>>`).
    final decl = line.split(';').first.trim();
    final name = decl.split(RegExp(r'\s+')).last;
    if (name.isNotEmpty) names.add(name);
  }
  return names;
}

/// Тело названного метода хранилища — от его заголовка до конца списка.
String _storeBlock(String methodSignature) {
  final src = _read('lib/core/store/local_message_store.dart');
  final start = src.indexOf(methodSignature);
  if (start < 0) {
    throw StateError(
      'не найден $methodSignature — разбор ослеп, числа ниже бессмысленны',
    );
  }
  final end = src.indexOf('\n  };', start);
  final close = src.indexOf('\n  );', start);
  final stop = [
    end,
    close,
  ].where((i) => i > start).fold<int>(src.length, (a, b) => a < b ? a : b);
  return src.substring(start, stop);
}

bool _mentions(String block, String field) {
  final escaped = RegExp.escape(field);
  // Либо ключ в карте (`'offerId':`), либо именованный параметр
  // (`offerId:`) — две формы, в которых поле называется по обе стороны
  // круга.
  return RegExp("'$escaped'").hasMatch(block) ||
      RegExp('\\b$escaped:').hasMatch(block);
}

void main() {
  group('память телефона хранит каждое поле сообщения (N140)', () {
    // Считается ВНУТРИ тестов, а не при сборке группы: разбор читает файлы
    // и может бросить, а бросок на сборке группы валит весь набор целиком —
    // и выглядит это как «проверка не запускалась», а не как находка.
    late List<String> fields;
    setUp(() => fields = _messageFields());

    // КАНАРЕЙКА, БЕЗ КОТОРОЙ ВЕСЬ НАБОР — ЗЕЛЁНАЯ ПУСТОТА.
    //
    // Сторож утверждает ОТСУТСТВИЕ пропусков, а такое утверждение ломается
    // молча: ослепший разбор находит ноль полей, проверять становится
    // нечего, и все проверки проходят. Поэтому число полей называется
    // вслух и сверяется с порогом, а несколько имён — поимённо.
    test('разбор видит поля Message', () {
      expect(
        fields.length,
        greaterThanOrEqualTo(45),
        reason: 'разбор models.dart нашёл слишком мало полей — он ослеп, '
            'и «пропусков нет» ниже означало бы «проверять было нечего»',
      );
      expect(fields, contains('senderId'));
      expect(fields, contains('offerId'));
      expect(fields, contains('timestamp'));
    });

    test('разбор видит оба списка хранилища', () {
      expect(_storeBlock('Map<String, dynamic> _toJson(').length, greaterThan(500));
      expect(_storeBlock('Message _fromJson(').length, greaterThan(500));
    });

    test('каждое поле кладётся на диск', () {
      final block = _storeBlock('Map<String, dynamic> _toJson(');
      final missing = <String>[];
      for (final f in fields) {
        if (_notPersisted.containsKey(f)) continue;
        if (!_mentions(block, _storedAs[f] ?? f)) missing.add(f);
      }
      expect(
        missing,
        isEmpty,
        reason: 'эти поля модели не кладутся в память телефона и пропадут '
            'молча: $missing. Либо дописать их в _toJson, либо внести в '
            '_notPersisted с доводом',
      );
    });

    test('каждое поле читается с диска обратно', () {
      final block = _storeBlock('Message _fromJson(');
      final missing = <String>[];
      for (final f in fields) {
        if (_notPersisted.containsKey(f)) continue;
        if (!_mentions(block, f)) missing.add(f);
      }
      expect(
        missing,
        isEmpty,
        reason: 'эти поля лежат на диске, но обратно не читаются: $missing',
      );
    });

    // Перечень исключений — тоже список, и он тоже устаревает. Проверяем,
    // что в нём не осталось имён, которых в модели уже нет: иначе он тихо
    // разрешает пропуск поля, которое давно переименовали.
    test('перечень нехранимых полей не устарел', () {
      for (final name in _notPersisted.keys) {
        expect(
          fields,
          contains(name),
          reason: 'в перечне нехранимых стоит $name, а такого поля в Message '
              'больше нет — перечень надо чистить',
        );
      }
      for (final name in _storedAs.keys) {
        expect(fields, contains(name));
      }
    });
  });
}
