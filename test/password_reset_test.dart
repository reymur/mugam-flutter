import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/auth/password_reset.dart';

// Работа 5а — сброс пароля.
//
// Ссылка «Şifrəni unutdum?» была снята с экрана входа 07.08 как ТУПИК:
// она вела `onTap: () {}`, человек жал единственную отведённую ему дорогу
// и не получал ничего (N65). С тех пор двери нет вовсе — это единственное
// место в приложении, где стало ХУЖЕ, чем до нашей правки.
//
// Проверяется здесь то, что можно проверить возвратом: разбор введённого
// текста и разбор кода ошибки. Сам поход в сеть чистым не бывает.

void main() {
  group('что делать с введённым адресом', () {
    test('пустой и недописанный не отправляются', () {
      for (final bad in ['', '   ', 'ali', 'ali@', '@m.com', 'ali@@m.com']) {
        expect(
          checkResetEmail(bad).canSend,
          isFalse,
          reason: 'отправили бы «$bad» и показали «письмо отправлено»',
        );
      }
    });

    test('домен без точки не отправляется', () {
      expect(checkResetEmail('ali@localhost').canSend, isFalse);
      expect(checkResetEmail('ali@.com').canSend, isFalse);
      expect(checkResetEmail('ali@m.').canSend, isFalse);
    });

    test('обычный адрес уходит без предупреждения', () {
      final r = checkResetEmail('qarimxan@gmail.com');
      expect(r.canSend, isTrue);
      expect(r.warning, isNull);
    });

    test('пробелы по краям не мешают', () {
      expect(checkResetEmail('  ali@mail.ru  ').canSend, isTrue);
    });
  });

  group('опечатка в домене — спрашиваем, но НЕ запрещаем', () {
    test('.con ловится — это живой случай из прода', () {
      // В проде 08.08 нашёлся домен `n.con`: человек набрал `.con` вместо
      // `.com`, и это прошло, потому что валидатора в форме нет (N78).
      final r = checkResetEmail('test@n.con');
      expect(r.warning, 'test@n.com?');
      expect(
        r.canSend,
        isTrue,
        reason: 'это вопрос, а не запрет: вдруг адрес настоящий',
      );
    });

    test('опечатка в самом имени домена тоже ловится', () {
      expect(checkResetEmail('ali@gmial.com').warning, 'ali@gmail.com?');
      expect(checkResetEmail('ali@gmail.co').warning, 'ali@gmail.com?');
    });

    test('живые зоны не трогаются', () {
      // `.co` — настоящая зона, и запрет на неё врал бы.
      for (final ok in ['ali@x.co', 'ali@x.ru', 'ali@x.az', 'ali@x.info']) {
        expect(
          checkResetEmail(ok).warning,
          isNull,
          reason: '«$ok» — живой адрес, предупреждение здесь ложное',
        );
      }
    });
  });

  group('отказ не получает выдуманную причину (разбор N45)', () {
    test('названные Firebase причины передаются как есть', () {
      expect(resetErrorMessage('invalid-email'), contains('düzgün deyil'));
      expect(resetErrorMessage('too-many-requests'), contains('Çox cəhd'));
      expect(
        resetErrorMessage('network-request-failed'),
        contains('İnternet'),
      );
    });

    test('НЕИЗВЕСТНЫЙ отказ не превращается в «письмо отправлено»', () {
      // Главная проверка этого файла. В N45 ветка ловила отказ и
      // объясняла его правдоподобной выдумкой — человек читал уверенную
      // неправду. Здесь неизвестное обязано остаться неизвестным.
      for (final unknown in [null, '', 'internal-error', 'что-то-новое']) {
        final msg = resetErrorMessage(unknown);
        expect(
          msg,
          contains('Göndərilə bilmədi'),
          reason: 'неизвестный отказ «$unknown» объяснён выдумкой',
        );
        expect(
          msg.contains('göndərildi'),
          isFalse,
          reason: 'отказ выдан за отправку: «$msg»',
        );
      }
    });
  });

  group('успех говорит ровно то, что мы знаем', () {
    test('не утверждает, что письмо ушло ИМЕННО этому человеку', () {
      // Firebase отвечает успехом на любой синтаксически верный адрес —
      // это защита от подбора чужих почт. Значит «письмо отправлено» было
      // бы утверждением о том, чего мы не знаем.
      expect(resetSentMessage, contains('Əgər belə hesab varsa'));
    });
  });
}
