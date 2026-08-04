import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/chat/chat_existence.dart';

// N34. Проверяется не «работает ли функция» — она в три строки, — а одно
// свойство, ради которого она вообще заведена: НЕ ЗНАЮ и НЕТ не должны
// сливаться. Слияние стоит дорого и молчит: проверка членства поверх него
// вышвыривает человека из живого чата на первом же снимке из кэша, и
// снаружи это выглядит как «меня удалили из группы».

void main() {
  group('три состояния, а не два', () {
    test('документ есть — существует, откуда бы снимок ни пришёл', () {
      // Кэш не выдумывает записей, которых не было: раз документ в нём
      // лежит, он существовал. Ждать ради этого сервер незачем.
      expect(
        chatExistenceOf(exists: true, isFromCache: true),
        ChatExistence.present,
      );
      expect(
        chatExistenceOf(exists: false, isFromCache: false),
        isNot(ChatExistence.present),
      );
    });

    test('пусто ОТ СЕРВЕРА — документа нет', () {
      expect(
        chatExistenceOf(exists: false, isFromCache: false),
        ChatExistence.absent,
      );
    });

    test('пусто ИЗ КЭША — «не знаю», и это НЕ «нет»', () {
      // Главная проверка файла. Поток поднят с includeMetadataChanges, и
      // первый снимок до ответа сервера штатно приходит пустым: спутай
      // его с удалением — и человека выбросит из любого чата на входе.
      final unknown = chatExistenceOf(exists: false, isFromCache: true);
      expect(unknown, ChatExistence.unknown);
      expect(unknown, isNot(ChatExistence.absent));
    });

    test('«нет» достижимо ТОЛЬКО ответом сервера', () {
      // Перебором всех четырёх сочетаний: absent обязан быть ровно один.
      final absent = <String>[];
      for (final exists in [true, false]) {
        for (final cached in [true, false]) {
          if (chatExistenceOf(exists: exists, isFromCache: cached) ==
              ChatExistence.absent) {
            absent.add('exists=$exists, fromCache=$cached');
          }
        }
      }
      expect(
        absent,
        ['exists=false, fromCache=false'],
        reason: 'Состояние «документа нет» должно быть достижимо ровно '
            'одним сочетанием — пустой снимок от сервера. Любое другое '
            'означает, что «не знаю» где-то читается как «нет».',
      );
    });
  });
}
