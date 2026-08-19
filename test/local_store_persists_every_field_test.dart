import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// СТОРОЖ НА КЛАСС: СООБЩЕНИЕ, ПЕРЕСОБИРАЕМОЕ ПО РУКОПИСНОМУ СПИСКУ, НЕ
// ДОЛЖНО ТЕРЯТЬ ПОЛЕЙ.
//
// 19.08 `offerId` потерялся дважды за день: сперва по дороге в память
// телефона, потом — в четырёх местах, где `Message` пересобирает сам себя
// (N140). Оба раза молча: поле, забытое в списке, не роняет ни сборку, ни
// анализатор, ни один из 696 тестов.
//
// --- ЧТО ЭТОТ СТОРОЖ ПОКРЫВАЕТ — ЧИСЛОМ, А НЕ СЛОВАМИ ---
//
// Мест, где `Message` пересобирается целиком по рукописному списку, —
// **ВОСЕМЬ** (обход 19.08 по всему `lib`: вызовы конструктора со счётом
// скобок плюс карты-литералы с ключом `senderId`; места, СОЗДАЮЩИЕ новое
// сообщение, в счёт не входят — у нового поля и не должно быть).
//
// Сторож проверяет **ШЕСТЬ из восьми**:
//
//   1. `_toJson`                    (local_message_store) — да
//   2. `_fromJson`                  (local_message_store) — да
//   3. `withConfirmedSeq`           (models)              — да
//   4. `withLocalStatus`            (models)              — да
//   5. `withUploadProgress`         (models)              — да
//   6. `_reconciledPreservingLocal` (models)              — да
//   7. `_reencode`                  (local_message_store) — **НЕТ**
//   8. `Message.fromFirestore`      (models)              — **НЕТ**
//
// **Почему седьмое и восьмое не покрыты, а не забыты.** Оба говорят на
// языке Firestore, где имена другие и вложенные: `replyToSenderName` лежит
// там как `replyTo.senderName`, `timestamp` — как есть, а часть полей не
// существует вовсе. Сверка по имени поля дала бы ложную тревогу на каждом
// поле цитаты, а ложная тревога дешевле пропуска ровно до дня, когда по
// ней начнут чинить исправное. Эти двое держатся круговыми тестами
// (`local_store_keeps_offer_link_test`, `message_rebuild_keeps_offer_link_test`)
// и чтением.
//
// **ГРАНИЦА ЗАПИСАНА ЗДЕСЬ ИМЕННО ПОТОМУ, ЧТО СТОРОЖ, ПОКРЫВАЮЩИЙ ЧАСТЬ
// ДОРОГИ, МОЛЧИТ ТАК ЖЕ, КАК ИСПРАВНЫЙ КОД.** Написанный час назад, он
// смотрел только на хранилище — три списка из восьми — и второго случая за
// тот же день не поймал. Зелёный сторож без записанной границы читается как
// «дорога проверена вся».
//
// --- ЧЕГО ОН НЕ ЛОВИТ ДАЖЕ ТАМ, ГДЕ СМОТРИТ ---
//
// Он проверяет НАЛИЧИЕ ИМЕНИ, а не то, что значение доехало: поле,
// перепутанное с соседним (`offerId: chatId`), он пропустит. Это ловится
// круговыми тестами, и они стоят рядом.
//
// --- ПОЧЕМУ РАЗБОР ИСХОДНИКА, А НЕ КРУГ ЖИВОГО ОБЪЕКТА ---
//
// Круг объекта был бы честнее, но **перечислить поля объекта в Flutter
// нечем**: отражения (`dart:mirrors`) в нём нет, и список пришлось бы
// писать рукой — то есть у сторожа была бы ровно та болезнь, которую он
// сторожит. Поэтому список полей берётся ИЗ САМОГО `Message`. Дописал поле
// в модель — сторож потребует его во всех шести местах сам.

/// Поля, которые в память телефона класть НЕ НАДО. У каждого — довод.
const _notPersisted = <String, String>{
  'localUploadProgress':
      'ход загрузки: возобновлённая отправка грузит файл заново, поэтому '
          'хранить старый процент значит показать несуществующее',
  'localPreviewBytes':
      'картинка предпросмотра в памяти: тяжёлая и восстановимая, место в '
          'постоянной памяти занимать не должна',
};

/// Поля, которые хранятся под ДРУГИМ ключом. Не пропуск, а перевод имени.
const _storedAs = <String, String>{'timestamp': 'timestampMillis'};

/// Законные пропуски В МЕТОДАХ ПЕРЕСБОРКИ, с доводом у каждой строки.
///
/// Список маленький и таким должен остаться: каждая запись здесь — это
/// место, где сторож молчит по нашему же решению.
const _legalOmissions = <String, Map<String, String>>{
  // Отправка подтверждена сервером — местная группа СБРАСЫВАЕТСЯ нарочно:
  // сообщение больше не «в очереди», и переносить её значило бы оставить
  // подтверждённое сообщение навсегда помеченным как неотправленное.
  'withConfirmedSeq': {
    'localFilePath': 'файл очереди больше не нужен — отправка состоялась',
    'localSendStatus': 'состояние очереди снимается: сообщение подтверждено',
    'localUploadProgress': 'загрузка завершена, ход не имеет смысла',
    'localPreviewBytes': 'предпросмотр очереди больше не показывается',
    'attemptCount': 'счётчик попыток обнуляется вместе с очередью',
    'uploadedUrl': 'адрес загруженного уже переехал в синхронизируемое поле',
    'videoHd': 'признак очереди на перекодирование, к подтверждённому не '
        'относится',
  },
};

String _read(String path) => File(path).readAsStringSync();

/// Имена полей класса `Message`, снятые с самого класса.
List<String> _messageFields() {
  final src = _read('lib/firebase/models.dart');
  final start = src.indexOf('\nclass Message {');
  if (start < 0) {
    throw StateError('класс Message не найден в models.dart — разбор ослеп');
  }
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

/// Тело перечисления полей — от объявления до закрывающей его строки.
///
/// **Границы берутся по ОБЪЯВЛЕНИЮ, а не по упоминанию имени.** Первая
/// редакция этого разбора искала имя и попадала в комментарий ПЕРЕД
/// методом; блок обрывался на самом объявлении, и разбор докладывал, что
/// не перечислено ни одного поля из сорока девяти. Вторая дотягивала блок
/// до соседнего метода и подхватывала чужие поля. Оба раза число выглядело
/// правдоподобно.
String _block(String path, String declaration) {
  final src = _read(path);
  final start = src.indexOf(declaration);
  if (start < 0) {
    throw StateError('не найдено «$declaration» в $path — разбор ослеп');
  }
  // Перечисление полей всегда закрывается строкой ровно из двух пробелов
  // и `);` либо `};` — это уровень члена класса, глубже отступы больше.
  final endParen = src.indexOf('\n  );', start);
  final endBrace = src.indexOf('\n  };', start);
  final candidates = [endParen, endBrace].where((i) => i > start);
  if (candidates.isEmpty) {
    throw StateError('не найден конец «$declaration» в $path');
  }
  final end = candidates.reduce((a, b) => a < b ? a : b);
  return src.substring(start, end);
}

bool _mentions(String block, String field) {
  final escaped = RegExp.escape(field);
  // Либо ключ карты (`'offerId':`), либо именованный параметр (`offerId:`).
  return RegExp("'$escaped'").hasMatch(block) ||
      RegExp('\\b$escaped:').hasMatch(block);
}

const _store = 'lib/core/store/local_message_store.dart';
const _models = 'lib/firebase/models.dart';

/// Шесть покрытых мест: как их найти и по какому имени они зовутся.
const _covered = <String, List<String>>{
  'кладём на диск (_toJson)': [_store, 'Map<String, dynamic> _toJson('],
  'читаем с диска (_fromJson)': [_store, 'Message _fromJson('],
  'withConfirmedSeq': [_models, 'Message withConfirmedSeq('],
  'withLocalStatus': [_models, 'Message withLocalStatus('],
  'withUploadProgress': [_models, 'Message withUploadProgress('],
  '_reconciledPreservingLocal': [
    _models,
    'Message _reconciledPreservingLocal(',
  ],
};

void main() {
  group('пересборка сообщения не теряет полей (N140)', () {
    // Считается ВНУТРИ тестов: разбор читает файлы и может бросить, а
    // бросок на сборке группы валит весь набор и выглядит как «проверка не
    // запускалась», а не как находка.
    late List<String> fields;
    setUp(() => fields = _messageFields());

    // КАНАРЕЙКА, БЕЗ КОТОРОЙ ВЕСЬ НАБОР — ЗЕЛЁНАЯ ПУСТОТА.
    //
    // Сторож утверждает ОТСУТСТВИЕ пропусков, а такое утверждение ломается
    // молча: ослепший разбор находит ноль полей, проверять нечего, и всё
    // проходит. Поэтому число полей называется вслух, а несколько имён —
    // поимённо. Проверено порчей 19.08: при ослеплённом разборе обе
    // проверки «пропусков нет» остались ЗЕЛЁНЫМИ, и покраснела только эта.
    test('разбор видит поля Message', () {
      expect(
        fields.length,
        greaterThanOrEqualTo(45),
        reason: 'разбор models.dart нашёл слишком мало полей — он ослеп, и '
            '«пропусков нет» ниже означало бы «проверять было нечего»',
      );
      expect(fields, contains('senderId'));
      expect(fields, contains('offerId'));
      expect(fields, contains('timestamp'));
    });

    test('разбор видит все шесть перечислений', () {
      for (final entry in _covered.entries) {
        final block = _block(entry.value[0], entry.value[1]);
        expect(
          block.length,
          greaterThan(400),
          reason: 'перечисление «${entry.key}» разобрано в ${block.length} '
              'знаков — это не список полей, разбор промахнулся мимо границ',
        );
      }
      // Число названо вслух: покрыто шесть мест из восьми (I13).
      expect(_covered.length, 6);
    });

    for (final entry in _covered.entries) {
      test('«${entry.key}» перечисляет каждое поле', () {
        final block = _block(entry.value[0], entry.value[1]);
        final legal = _legalOmissions[entry.key] ?? const {};
        final onDisk = entry.key.contains('диск');

        final missing = <String>[];
        for (final f in fields) {
          if (legal.containsKey(f)) continue;
          if (onDisk && _notPersisted.containsKey(f)) continue;
          if (!_mentions(block, onDisk ? (_storedAs[f] ?? f) : f)) {
            missing.add(f);
          }
        }

        expect(
          missing,
          isEmpty,
          reason: 'в «${entry.key}» не перечислены поля $missing — они '
              'пропадут МОЛЧА. Либо дописать их, либо внести в перечень '
              'законных пропусков с доводом',
        );
      });
    }

    // Перечни исключений — тоже списки, и они тоже устаревают. Проверяем,
    // что в них не осталось имён, которых в модели уже нет: иначе они тихо
    // разрешают пропуск поля, которое давно переименовали.
    test('перечни исключений не устарели', () {
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
      for (final entry in _legalOmissions.entries) {
        expect(
          _covered.containsKey(entry.key),
          isTrue,
          reason: 'законные пропуски записаны для «${entry.key}», а такого '
              'места сторож не проверяет вовсе',
        );
        for (final name in entry.value.keys) {
          expect(fields, contains(name));
        }
      }
    });
  });
}
