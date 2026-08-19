import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/store/local_message_store.dart';
import 'package:mugam_flutter/firebase/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ССЫЛКА НА ПРЕДЛОЖЕНИЕ ДОЛЖНА ПЕРЕЖИВАТЬ ПЕРЕСБОРКУ СООБЩЕНИЯ.
//
// У `Message` четыре способа пересобрать себя, и каждый перечисляет поля
// РУКОПИСНЫМ списком: подтверждение отправки, смена состояния отправки, ход
// загрузки файла и слияние пришедшего с сервера с тем, что уже лежит на
// телефоне. Поле, забытое в таком списке, пропадает молча (N140).
//
// --- ГЛАВНЫЙ ЗДЕСЬ — ЧЕТВЁРТЫЙ, И ВОТ ПОЧЕМУ ---
//
// Через слияние проходит КАЖДОЕ уже лежащее на телефоне сообщение, когда
// сервер присылает его снова. Это дорога всей старой переписки. Пока
// ссылка теряется там, карточка предложения не появится даже после
// починки хранилища — и выглядело бы это как «починка не сработала».
//
// Слияние проверяется НАСТОЯЩИМ ПУТЁМ, через хранилище (два обновления
// подряд: первое кладёт строку, второе сливается с ней), а не прямым
// вызовом метода: прод ходит именно так, и обход через публичный вход
// заодно доказывает, что до слияния дело вообще доходит.
//
// Три остальных зовутся из очереди отправки напрямую, поэтому и здесь
// проверяются прямым вызовом — это их настоящий вход, а не ближайший.

const _link = 'offer-42';

Message _anchor({String? offerId = _link}) => Message(
  id: 'm-anchor',
  chatId: 'chat-1',
  senderId: 'boss',
  text: '2 gün: 19, 20 avqust · Toy',
  type: 'text',
  seq: 1,
  timestamp: Timestamp.fromDate(DateTime.utc(2026, 8, 19, 8, 29)),
  offerId: offerId,
  // КАНАРЕЙКА — БЕЗУСЛОВНАЯ (условлено 19.08). Строка, которой может не
  // быть, но переносится она всегда, без спутника. Поле, живущее лишь при
  // заполненном соседе, покраснело бы вместе с проверяемым и перестало бы
  // различать поломку и неподходящие данные.
  mediaFileName: 'запись.m4a',
);

Future<Message> _mergedThroughStore() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = LocalMessageStore(prefs);
  await store.init();

  // Первое обновление — строки ещё нет, она заводится с нуля.
  await store.upsertManyFromFirestore(chatId: 'chat-1', reals: [_anchor()]);
  // Второе — строка уже есть, и вот здесь идёт слияние.
  await store.upsertManyFromFirestore(chatId: 'chat-1', reals: [_anchor()]);

  final messages = await store.watchChat('chat-1').first;
  expect(
    messages.length,
    1,
    reason: 'сообщение не доехало — сливать было нечего, и красный ниже '
        'означал бы не потерю поля, а несостоявшуюся проверку',
  );
  return messages.single;
}

void main() {
  group('слияние пришедшего с сервера с тем, что на телефоне', () {
    test('соседнее поле переживает слияние', () async {
      final merged = await _mergedThroughStore();
      expect(merged.mediaFileName, 'запись.m4a');
      expect(merged.text, '2 gün: 19, 20 avqust · Toy');
    });

    test('ссылка на предложение переживает слияние', () async {
      final merged = await _mergedThroughStore();
      expect(
        merged.offerId,
        _link,
        reason: 'это дорога ВСЕХ старых сообщений: сервер присылает их '
            'снова, они сливаются с лежащими на телефоне и теряют ссылку — '
            'карточка не появится ни на одном',
      );
    });
  });

  group('пересборка сообщения не теряет ссылку', () {
    test('канарейка: соседнее поле переживает все три пересборки', () {
      final m = _anchor();
      expect(m.withConfirmedSeq(7).mediaFileName, 'запись.m4a');
      expect(
        m.withLocalStatus(status: 'queued').mediaFileName,
        'запись.m4a',
      );
      expect(m.withUploadProgress(0.5).mediaFileName, 'запись.m4a');
    });

    test('подтверждение отправки сохраняет ссылку', () {
      expect(_anchor().withConfirmedSeq(7).offerId, _link);
    });

    test('смена состояния отправки сохраняет ссылку', () {
      expect(_anchor().withLocalStatus(status: 'failed').offerId, _link);
    });

    test('ход загрузки файла сохраняет ссылку', () {
      expect(_anchor().withUploadProgress(0.5).offerId, _link);
    });
  });
}
