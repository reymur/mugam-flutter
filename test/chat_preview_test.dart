import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/chat/chat_preview.dart';
import 'package:mugam_flutter/firebase/models.dart';

// N76 — в строке ГРУППЫ не видно, кто написал последнее сообщение.
//
// Найдено 07.08 на устройстве: строка «Q1» показывала «Ыыыы» и молчала об
// авторе. В группе из двух это ещё угадывается, из двадцати — нет, и
// человек обязан открыть группу, чтобы понять, стоит ли её открывать.
//
// Проверяется ПРАВИЛО, а не экран: то же основание, что у
// `buildDayBuckets` и `chatAfterDeparture` — порченое правило внутри
// build() не видно ни одному тесту.

Chat chat({
  bool isGroup = true,
  String lastMessage = 'Ыыыы',
  String? lastMessageBy = 'them',
  bool isSystem = false,
  List<String> deletedFor = const [],
  Map<String, DateTime> clearedBy = const {},
  DateTime? lastMessageTime,
}) {
  return Chat(
    id: 'c1',
    name: 'Q1',
    emoji: '💬',
    lastMessage: lastMessage,
    lastMessageTime: lastMessageTime ?? DateTime(2026, 8, 7, 23, 7),
    lastMessageDeletedFor: deletedFor,
    lastMessageBy: lastMessageBy,
    lastMessageIsSystem: isSystem,
    unreadCount: 0,
    members: const ['me', 'them'],
    isGroup: isGroup,
    clearedBy: clearedBy,
  );
}

void main() {
  group('кого называет строка чата (N76)', () {
    test('чужое сообщение в группе — имя перед текстом', () {
      final p = chatPreview(
        chat: chat(),
        currentUid: 'me',
        senderName: 'Fərid',
      );
      expect(p.prefix, 'Fərid');
      expect(p.text, 'Ыыыы');
      expect(p.italic, isFalse);
    });

    test('своё сообщение — «Siz»', () {
      // Иначе не отличить «я написал и жду ответа» от «мне написали».
      final p = chatPreview(
        chat: chat(lastMessageBy: 'me'),
        currentUid: 'me',
        senderName: 'Teymur',
      );
      expect(p.prefix, 'Siz');
    });

    test('личный чат — имени нет, оно в заголовке строки', () {
      final p = chatPreview(
        chat: chat(isGroup: false),
        currentUid: 'me',
        senderName: 'Fərid',
      );
      expect(p.prefix, isNull);
      expect(p.text, 'Ыыыы');
    });

    test('СИСТЕМНАЯ ЗАПИСЬ — имени нет, хотя отправитель у неё настоящий', () {
      // Ловушка, ради которой заведён отдельный флаг. У всех шести
      // системных записей senderId настоящий: тут — тот, кто вышел.
      // Проверка «автор пустой» пропустила бы это и дала бы имя дважды.
      final p = chatPreview(
        chat: chat(
          lastMessage: 'Rafael Dagli qrupdan çıxdı',
          lastMessageBy: 'rafael',
          isSystem: true,
        ),
        currentUid: 'me',
        senderName: 'Rafael Dagli',
      );
      expect(
        p.prefix,
        isNull,
        reason: 'вышло бы «Rafael Dagli: Rafael Dagli qrupdan çıxdı»',
      );
      expect(p.text, 'Rafael Dagli qrupdan çıxdı');
    });

    test('автора нет — чат старше поля, префикса нет', () {
      final p = chatPreview(
        chat: chat(lastMessageBy: null),
        currentUid: 'me',
        senderName: 'Fərid',
      );
      expect(p.prefix, isNull);
    });

    test('имя не доехало — показываем текст без префикса, а не uid', () {
      // Сырой uid в списке хуже, чем отсутствие имени.
      final p = chatPreview(
        chat: chat(),
        currentUid: 'me',
        senderName: null,
      );
      expect(p.prefix, isNull);
      expect(p.text, 'Ыыыы');
    });

    test('пустое имя считается за отсутствующее', () {
      final p = chatPreview(
        chat: chat(),
        currentUid: 'me',
        senderName: '   ',
      );
      expect(p.prefix, isNull);
    });
  });

  group('состояния, где показывать нечего', () {
    test('удалил у себя — заглушка курсивом и без имени', () {
      final p = chatPreview(
        chat: chat(deletedFor: const ['me']),
        currentUid: 'me',
        senderName: 'Fərid',
      );
      expect(p.prefix, isNull);
      expect(p.text, '🚫 Bu mesajı sildiniz');
      expect(p.italic, isTrue);
    });

    test('второй стороне то же сообщение видно как обычно', () {
      // Удаление у себя никогда не меняет то, что видит другой.
      final p = chatPreview(
        chat: chat(deletedFor: const ['them']),
        currentUid: 'me',
        senderName: 'Fərid',
      );
      expect(p.prefix, 'Fərid');
      expect(p.text, 'Ыыыы');
    });

    test('чат очищен и с тех пор ничего не приходило — пусто', () {
      final p = chatPreview(
        chat: chat(
          lastMessageTime: DateTime(2026, 8, 7, 10),
          clearedBy: {'me': DateTime(2026, 8, 7, 12)},
        ),
        currentUid: 'me',
        senderName: 'Fərid',
      );
      expect(p.prefix, isNull);
      expect(p.text, '');
      // По этому же признаку экран прячет время в строке. Признак отдаётся
      // отсюда, а не вычисляется на экране вторично.
      expect(p.cleared, isTrue);
    });

    test('после очистки пришло новое — снова видно, и с именем', () {
      final p = chatPreview(
        chat: chat(
          lastMessageTime: DateTime(2026, 8, 7, 14),
          clearedBy: {'me': DateTime(2026, 8, 7, 12)},
        ),
        currentUid: 'me',
        senderName: 'Fərid',
      );
      expect(p.prefix, 'Fərid');
      expect(p.text, 'Ыыыы');
      expect(p.cleared, isFalse, reason: 'время снова должно показываться');
    });
  });
}
