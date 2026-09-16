// ВРЕМЕННАЯ ПРОБА — УДАЛИТЬ ПОСЛЕ ЗАМЕРА. Не часть приложения.
//
// ВОПРОС ОДИН: ОТКАЗЫВАЕТ ЛИ SDK-СКАЧИВАНИЕ (`writeToFile`) ЧУЖОМУ ПО
// `storage.rules` В ПРОДЕ. Путь В (решение владельца 16.09) целиком стоит на
// «да»: известно только, что своего пускает. Эмуляторные тесты правил
// доказывают текст правила, но не то, что прод применяет его к SDK (I50).
//
// ПОЧЕМУ ЧАТ, А НЕ ПРИЧИНА ВЫХОДА (переразбор 17.09, перепись прода):
// все 9 файлов `event_leave_notes/` записаны ОДНИМ человеком (Теймур) в
// вечерах ОДНОГО владельца (Рафаэль). Звонящего «в составе, не владелец, не
// автор» среди двух трубок нет ни для одного файла — строка 2 не собиралась
// бы вовсе. Зато правило чата (`chats/{chatId}/{fileName}` → участник чата)
// даёт чужой файл на каждой трубке. Вопрос пробы — «применяет ли прод правила
// к SDK-скачиванию», и форма пути его не меняет; все четыре строки идут по
// ОДНОМУ правилу, чтобы канарейки стояли на той же ветви, что вопрос.
//
// ПУТИ НЕ НАХОДЯТСЯ НА ТРУБКЕ: чужой чат звонящему не виден ни в Firestore,
// ни в хранилище. Они задаются при сборке и взяты переписью с Mac:
//
//     flutter run --release -t tool/probe_storage_read.dart \
//       --dart-define=PROBE_EXPECT_UID=<uid трубки> \
//       --dart-define=PROBE_OWN=<файл своего чата> \
//       --dart-define=PROBE_FOREIGN=<файл чужого чата> \
//       --dart-define=PROBE_MISSING=<несуществующее имя в своём чате>
//
// КАНАРЕЙКА НА УЧЁТКУ — ОБЯЗАТЕЛЬНА: вошедший не тот (скажем, участник
// «чужого» чата) дал бы в строке 2 успех, и он прочёлся бы как «правила не
// применяются». Поэтому при несовпадении uid строки не запускаются.
//
// ЧЕТЫРЕ СТРОКИ:
//   1. файл своего чата — канарейка «скачивание работает вообще»;
//   2. файл чужого чата — САМ ВОПРОС, ждём `unauthorized`;
//   3. несуществующее имя в своём чате — канарейка «отказ ≠ нет файла»,
//      ждём `object-not-found`;
//   4. путь строки 2 В АВИАРЕЖИМЕ — канарейка «не дошло до сервера», ждём
//      НЕ `unauthorized`.
//
// Вердикт здесь НЕ вычисляется: на экране сырой код и размер, рядом
// ожидание; читает таблица исходов в `docs/plan.md` (I14).
//
// ПОСЛЕ ЗАМЕРА ПРИЛОЖЕНИЕ НА ТРУБКЕ ЗАМЕНЕНО ПРОБОЙ — обычную сборку
// поставить обратно.

import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:mugam_flutter/firebase_options.dart';
import 'package:path_provider/path_provider.dart';

const _expectUid = String.fromEnvironment('PROBE_EXPECT_UID');
const _own = String.fromEnvironment('PROBE_OWN');
const _foreign = String.fromEnvironment('PROBE_FOREIGN');
const _missing = String.fromEnvironment('PROBE_MISSING');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // По умолчанию SDK повторяет скачивание до 10 минут — строка 4 в
  // авиарежиме висела бы всё это время вместо ответа.
  FirebaseStorage.instance
      .setMaxDownloadRetryTime(const Duration(seconds: 20));
  runApp(const MaterialApp(home: _ProbeScreen()));
}

class _Row {
  _Row(this.title, this.path, this.expected);
  final String title;
  final String path;
  final String expected;
  String? result;
  bool running = false;
}

class _ProbeScreen extends StatefulWidget {
  const _ProbeScreen();

  @override
  State<_ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<_ProbeScreen> {
  final _rows = [
    _Row('1. Файл своего чата — канарейка «работает»', _own,
        'УСПЕХ, размер = gsutil stat'),
    _Row('2. Файл чужого чата — ВОПРОС', _foreign,
        'ОТКАЗ, код "unauthorized", файла на диске нет или 0 байт'),
    _Row('3. Нет такого файла в своём чате — канарейка «отказ ≠ нет файла»',
        _missing, 'ОТКАЗ, код "object-not-found"'),
    _Row('4. Путь строки 2 В АВИАРЕЖИМЕ — канарейка «не дошло»', _foreign,
        'ОТКАЗ, код НЕ "unauthorized"'),
  ];

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  bool get _accountOk => _expectUid.isNotEmpty && _uid == _expectUid;

  Future<void> _run(_Row row) async {
    setState(() {
      row.running = true;
      row.result = null;
    });
    final dir = await getTemporaryDirectory();
    final dest =
        File('${dir.path}/probe_${DateTime.now().microsecondsSinceEpoch}');
    final sw = Stopwatch()..start();
    String outcome;
    try {
      await FirebaseStorage.instance.ref(row.path).writeToFile(dest);
      outcome = 'УСПЕХ';
    } on FirebaseException catch (e) {
      outcome = 'ОТКАЗ, код "${e.code}": ${e.message}';
    } catch (e) {
      outcome = 'ИНОЕ ИСКЛЮЧЕНИЕ ${e.runtimeType}: $e';
    }
    sw.stop();
    final exists = await dest.exists();
    final size = exists ? await dest.length() : null;
    if (exists) await dest.delete();
    setState(() {
      row.running = false;
      row.result = '$outcome\n'
          'файл на диске: ${exists ? '$size байт' : 'нет'}\n'
          'за ${sw.elapsedMilliseconds} мс, ${DateTime.now().toIso8601String()}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = _uid.isEmpty
        ? 'НЕ ВОШЁЛ — строки не запускаются'
        : _accountOk
            ? 'вошёл: $_uid — совпадает с ожидаемым'
            : 'ВОШЁЛ НЕ ТОТ: $_uid, ожидался "$_expectUid" — строки не запускаются';
    return Scaffold(
      appBar: AppBar(title: const Text('Проба: отказ writeToFile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SelectableText(account),
          const SizedBox(height: 16),
          for (final row in _rows)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.title,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    SelectableText(
                        row.path.isEmpty ? 'путь НЕ ЗАДАН при сборке' : row.path),
                    Text('ожидание: ${row.expected}'),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed:
                          !_accountOk || row.path.isEmpty || row.running
                              ? null
                              : () => _run(row),
                      child: Text(row.running ? 'идёт…' : 'Запустить'),
                    ),
                    if (row.result != null) SelectableText(row.result!),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
