import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/leave_note.dart';
import 'package:mugam_flutter/core/agreements/leave_note_voice.dart';

// ГОЛОС ПРИЧИНЫ ЧИТАЕТСЯ С ДИСКА, А НЕ ПО ССЫЛКЕ (N232, шаг 2).
//
// Набор стоит на политике хранения, а не на Firebase: скачивание приходит
// сюда подставным, и его вызовы считаются. Настоящая дорога
// (`FirestoreService.downloadLeaveNoteVoice` → `writeToFile`) этим набором НЕ
// проверяется и проверена быть не может — она живёт в SDK.
//
// ЧТО УПАДЁТ ПРИ ПОРЧЕ (называется ДО порчи — I46):
//   • снять проверку «файл уже есть» — «второй раз не качаем», один тест;
//   • качать прямо в итоговый файл вместо `.part` — «обрыв не оставляет
//     обрезанного файла», один тест;
//   • сменить имя файла в `leaveNoteVoiceFileName` — «имя файла выводится из
//     вечера и человека», один тест, и он же в `leave_note_test.dart` про
//     адрес в хранилище.
//
// ЧЕГО НЕ ЛОВИТ: что проигрывателю отдали именно файл, а не ссылку — это
// сторожится разбором исходников (`source_invariants_test.dart`), потому что
// проверяется состав вызова, а не поведение.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('leave_note_voice_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  LeaveNoteVoiceStore storeWith(LeaveNoteVoiceDownload download) =>
      LeaveNoteVoiceStore(download: download, cacheDir: () async => dir);

  test('имя файла на диске выводится из вечера и человека', () {
    expect(
      leaveNoteVoiceFileName(eventId: 'ev1', uid: 'u1'),
      'leave_note_ev1_u1.m4a',
    );
    // Пара к именам: два разных человека одного вечера НЕ делят файл.
    expect(
      leaveNoteVoiceFileName(eventId: 'ev1', uid: 'u2'),
      isNot(leaveNoteVoiceFileName(eventId: 'ev1', uid: 'u1')),
    );
  });

  test('качается по адресу из eventId и uid, в тот же файл', () async {
    final asked = <String>[];
    final store = storeWith(({required storagePath, required dest}) async {
      asked.add(storagePath);
      await dest.writeAsBytes([1, 2, 3]);
    });

    final file = await store.voiceFile(eventId: 'ev1', uid: 'u1');

    expect(asked, [leaveNoteVoicePath(eventId: 'ev1', uid: 'u1')]);
    expect(file.path, '${dir.path}/leave_note_ev1_u1.m4a');
    expect(await file.readAsBytes(), [1, 2, 3]);
  });

  test('второй раз не качаем — файл уже на диске', () async {
    var calls = 0;
    final store = storeWith(({required storagePath, required dest}) async {
      calls++;
      await dest.writeAsBytes([1, 2, 3]);
    });

    await store.voiceFile(eventId: 'ev1', uid: 'u1');
    await store.voiceFile(eventId: 'ev1', uid: 'u1');

    // I13 — число вслух: не «не качали», а «позвали ровно один раз».
    expect(calls, 1);
  });

  test('пустой файл на диске годным не считается — качаем заново', () async {
    // Ноль байт — это не «уже скачано»: `exists()` у такого файла истинно, и
    // без проверки длины проигрыватель получил бы пустоту навсегда.
    await File('${dir.path}/leave_note_ev1_u1.m4a').writeAsBytes([]);
    var calls = 0;
    final store = storeWith(({required storagePath, required dest}) async {
      calls++;
      await dest.writeAsBytes([1, 2, 3]);
    });

    final file = await store.voiceFile(eventId: 'ev1', uid: 'u1');

    expect(calls, 1);
    expect(await file.length(), 3);
  });

  test('обрыв не оставляет обрезанного файла', () async {
    final store = storeWith(({required storagePath, required dest}) async {
      // Половина приехала, дальше обрыв — ровно то, что делает сеть.
      await dest.writeAsBytes([1, 2]);
      throw const SocketException('обрыв');
    });

    await expectLater(
      store.voiceFile(eventId: 'ev1', uid: 'u1'),
      throwsA(isA<SocketException>()),
    );

    // Ни итогового файла, ни `.part` — иначе следующий заход счёл бы огрызок
    // скачанным и играл бы его всегда.
    expect(await File('${dir.path}/leave_note_ev1_u1.m4a').exists(), isFalse);
    expect(
      await File('${dir.path}/leave_note_ev1_u1.m4a.part').exists(),
      isFalse,
    );
  });

  test('скачивание без байтов отказывает, а не отдаёт пустой файл', () async {
    // Подставное скачивание, которое «прошло» и ничего не записало: так
    // выглядела бы ошибка SDK, не бросившая исключение.
    final store = storeWith(({required storagePath, required dest}) async {});

    await expectLater(
      store.voiceFile(eventId: 'ev1', uid: 'u1'),
      throwsA(isA<StateError>()),
    );
    expect(await File('${dir.path}/leave_note_ev1_u1.m4a').exists(), isFalse);
  });

  test('после обрыва следующий заход качает заново и отдаёт файл', () async {
    var calls = 0;
    final store = storeWith(({required storagePath, required dest}) async {
      calls++;
      if (calls == 1) {
        await dest.writeAsBytes([1, 2]);
        throw const SocketException('обрыв');
      }
      await dest.writeAsBytes([1, 2, 3, 4]);
    });

    await expectLater(
      store.voiceFile(eventId: 'ev1', uid: 'u1'),
      throwsA(isA<SocketException>()),
    );
    final file = await store.voiceFile(eventId: 'ev1', uid: 'u1');

    expect(calls, 2);
    expect(await file.length(), 4);
  });
}
