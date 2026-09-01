import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/firebase/voip_push_token_service.dart';

// СТОРОЖ НА СОГЛАСИЕ ДВУХ ФАЙЛОВ, А НЕ НА ПРАВИЛЬНОСТЬ ОДНОГО.
//
// Клиент пишет `users/{uid}/voipPushTokens/{deviceId}`, а сервер (шаг 4)
// будет читать оттуда адрес и среду. Договорённость о составе полей живёт в
// ДВУХ местах — в этом коде и в парном тесте правил
// `functions/test/voip-tokens-rules.test.ts`, — и правила её не удерживают:
// в блоке `voipPushTokens` нет `hasOnly`, то есть с точки зрения Firestore
// туда можно писать что угодно. Значит разойтись эти два места могут молча,
// и заметить это будет нечем до самой отправки, а отправка молчит по
// определению (N186: APNs выбрасывает без отказа).
//
// Это N80 в чистом виде — число, живущее в двух наших файлах при одной дате.
// Здесь вместо числа состав полей, но болезнь та же.
//
// ЧЕГО ЭТОТ СТОРОЖ НЕ ЛОВИТ (границы пишутся вместе со сторожем):
//   - он сверяет ИМЕНА полей, а не значения и не типы. `platform: 'ios'`,
//     записанный как `platform: 'IOS'`, пройдёт;
//   - ВЕРДИКТ «каждое поле названо в парном тесте правил» ищет ПОДСТРОКУ, и
//     это измерено порчей, а не предположено: переименование
//     `environment` → `env` он ПРОПУСТИЛ, потому что «env» входит в
//     «environment». Покраснели тогда два других вердикта, и защита
//     удержалась ими; но само это сравнение слабее, чем читается по его
//     названию, и полагаться на него одно нельзя;
//   - он ничего не знает о том, что прочтёт СЕРВЕР: функции отправки ещё
//     нет (шаг 4). Когда появится — третьим местом станет она, и её надо
//     будет внести сюда же;
//   - он не проверяет ПУТЬ (`voipPushTokens`) — только тело документа. Путь
//     стоит в трёх местах и сверяется отдельным вердиктом ниже.
void main() {
  // Тело документа — единственное, что можно проверить, не выходя в сеть.
  // Утверждение НАЛИЧИЯ, а не отсутствия: ослепший разбор дал бы пустое
  // множество, пустое не равно ожидаемому, вердикт покраснел бы (I31).
  // Поэтому отдельной канарейки этому сторожу не нужно — он сам себе
  // канарейка.
  group('тело документа адреса PushKit', () {
    test('состав полей ровно тот, что пишет парный тест правил', () {
      final doc = VoipPushTokenService.tokenDoc(
        token: 'a' * 64,
        platform: 'ios',
        environment: 'sandbox',
      );

      expect(
        doc.keys.toSet(),
        {'token', 'platform', 'environment', 'updatedAt'},
        reason: 'состав полей разошёлся с functions/test/voip-tokens-rules.test.ts',
      );
    });

    test('значения переносятся, а не теряются по дороге', () {
      final doc = VoipPushTokenService.tokenDoc(
        token: 'b' * 64,
        platform: 'ios',
        environment: 'production',
      );

      expect(doc['token'], 'b' * 64);
      expect(doc['platform'], 'ios');
      expect(doc['environment'], 'production');
    });

    test('updatedAt — серверная отметка, а не часы телефона', () {
      final doc = VoipPushTokenService.tokenDoc(
        token: 'c' * 64,
        platform: 'ios',
        environment: 'sandbox',
      );

      // Точный тип — FieldValue; сверяется по имени, потому что
      // FieldValue.serverTimestamp() не равен сам себе при сравнении.
      expect(
        doc['updatedAt'].runtimeType.toString(),
        contains('FieldValue'),
        reason: 'время берётся с телефона — уехавшие часы сделают свежий '
            'адрес неотличимым от протухшего',
      );
      expect(doc['updatedAt'], isNot(isA<DateTime>()));
      expect(doc['updatedAt'], isNot(isA<String>()));
    });
  });

  group('согласие с парным тестом правил', () {
    // Разбор чужого файла, поэтому рядом стоит канарейка: ноль по образцу
    // означал бы «разбор слеп», а не «полей нет» (I31, N103).
    late String rulesTest;

    setUpAll(() {
      final f = File('functions/test/voip-tokens-rules.test.ts');
      expect(
        f.existsSync(),
        isTrue,
        reason: 'парный тест правил пропал — сверять не с чем',
      );
      rulesTest = f.readAsStringSync();
    });

    test('КАНАРЕЙКА: разбор видит заведомо существующее', () {
      // СЧИТАЕТ ВХОЖДЕНИЯ И НАЗЫВАЕТ ЧИСЛО, а не отвечает «да/нет» на голое
      // имя. Первая редакция была написана как `contains('voipPushTokens')`
      // и покраснела у сторожа сторожей (test/guards_are_guards_test.dart,
      // вердикт «в текстовых сторожах нет contains по голому имени») — по
      // делу: имя есть в файле всегда, и такое сравнение довольно одним
      // упоминанием. Здесь спрашивается «а сколько она сейчас нашла?» (I13).
      final mentions = 'voipPushTokens'.allMatches(rulesTest).length;
      expect(
        mentions,
        greaterThanOrEqualTo(2),
        reason: 'разбор нашёл $mentions упоминаний коллекции — он слеп, '
            'а не «полей нет»',
      );
      expect(
        rulesTest.contains('voipPushTokens/'),
        isTrue,
        reason: 'имя есть, а ПУТИ нет — парный тест перестал ходить в '
            'документ коллекции',
      );
      expect(rulesTest.length, greaterThan(1000));
    });

    test('каждое поле нашего документа названо в парном тесте правил', () {
      final doc = VoipPushTokenService.tokenDoc(
        token: 'a' * 64,
        platform: 'ios',
        environment: 'sandbox',
      );

      final missing = doc.keys.where((k) => !rulesTest.contains(k)).toList();

      expect(
        missing,
        isEmpty,
        reason: 'клиент пишет поля, которых парный тест правил не знает: '
            '$missing — расхождение молчаливое, правила состав не держат '
            '(в блоке voipPushTokens нет hasOnly)',
      );
    });

    test('путь коллекции совпадает у клиента и у парного теста правил', () {
      final client =
          File('lib/firebase/voip_push_token_service.dart').readAsStringSync();

      expect(
        client.contains("collection('voipPushTokens')"),
        isTrue,
        reason: 'клиент перестал писать в voipPushTokens',
      );
      expect(
        rulesTest.contains('voipPushTokens/'),
        isTrue,
        reason: 'парный тест правил перестал проверять voipPushTokens',
      );
    });
  });
}
