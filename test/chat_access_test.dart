import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/chat/chat_access.dart';
import 'package:mugam_flutter/core/chat/chat_existence.dart';

// N33 + N34. Правило ошибается в ОБЕ стороны, и обе дорого:
//   не среагировать — человек сидит в чате, которого лишился;
//   среагировать рано — вышвырнуть его из чата, в котором он состоит.
// Поэтому положительных случаев здесь ровно столько же, сколько
// отрицательных, а «ничего не решено» проверяется отдельно от «всё в
// порядке»: это разные ответы, и слить их — снова N13.

const _me = 'me';
const _other = 'other';

ChatAccess access({
  required ChatExistence existence,
  bool fromCache = false,
  List<String>? members = const [_me, _other],
}) =>
    resolveChatAccess(
      existence: existence,
      fromCache: fromCache,
      members: members,
      currentUid: _me,
    );

void main() {
  group('реагировать', () {
    test('меня удалили из группы — чат есть, меня в нём нет', () {
      expect(
        access(existence: ChatExistence.present, members: const [_other]),
        ChatAccess.removedFromChat,
      );
    });

    test('группу удалили целиком — сервер сказал, что документа нет', () {
      expect(
        access(existence: ChatExistence.absent, members: null),
        ChatAccess.chatDeleted,
      );
    });

    test('два случая РАЗЛИЧАЮТСЯ — ради этого и заводился N34', () {
      // До признака существования оба выглядели одинаково: чат с пустым
      // составом. А слова человеку нужны разные — «группу удалили» и
      // «вас удалили из группы» это разные новости.
      final deleted = access(existence: ChatExistence.absent, members: null);
      final removed =
          access(existence: ChatExistence.present, members: const [_other]);
      expect(deleted, isNot(removed));
    });

    test('пустой состав от сервера — тоже исключение', () {
      expect(
        access(existence: ChatExistence.present, members: const []),
        ChatAccess.removedFromChat,
      );
    });
  });

  group('НЕ реагировать — вторая сторона, не менее важная', () {
    test('я участник — всё в порядке', () {
      expect(access(existence: ChatExistence.present), ChatAccess.ok);
    });

    test('сервер ещё не ответил — НИЧЕГО не решено', () {
      // Поток поднят с includeMetadataChanges, и первый снимок штатно
      // пустой. Ответь тут «чат удалён» — и человека выбросит из любого
      // чата на входе.
      expect(
        access(existence: ChatExistence.unknown, members: null),
        ChatAccess.unknown,
      );
    });

    test('состава ещё нет — не решено, а не «исключён»', () {
      expect(
        access(existence: ChatExistence.present, members: null),
        ChatAccess.unknown,
      );
    });

    test('состав ИЗ КЭША меня не содержит — не выбрасываем', () {
      // Кэш может отставать на сессию: человека добавили в группу, а в
      // кэше документ с прежним составом. Решение по такому снимку
      // ложное, а выглядит для человека ровно как настоящее. Чужое
      // удаление приходит от сервера, так что ждать нечего.
      expect(
        access(
          existence: ChatExistence.present,
          fromCache: true,
          members: const [_other],
        ),
        ChatAccess.ok,
      );
    });

    test('выброс достижим ТОЛЬКО по ответу сервера', () {
      // Перебор: ни одно сочетание с fromCache не даёт removedFromChat.
      final offenders = <String>[];
      for (final existence in ChatExistence.values) {
        for (final members in [
          null,
          const <String>[],
          const [_other],
          const [_me, _other],
        ]) {
          final a = access(
            existence: existence,
            fromCache: true,
            members: members,
          );
          if (a == ChatAccess.removedFromChat) {
            offenders.add('$existence, members=$members');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Исключение человека решено по снимку из кэша: $offenders. '
            'Состав из кэша может отставать, и выброс окажется ложным.',
      );
    });
  });
}
