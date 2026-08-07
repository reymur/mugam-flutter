import '../../firebase/models.dart';

/// Что стоит во второй строке карточки чата.
///
/// **Две части, а не готовая строка** — решение владельца 08.08 по N76.
/// Имя рисуется приглушённым цветом, текст обычным; одной строкой два
/// стиля не выразить, и экрану пришлось бы резать её обратно по
/// двоеточию — то есть разбирать только что склеенное. Разрежется неверно
/// в первый же текст, где двоеточие есть.
typedef ChatPreview = ({String? prefix, String text, bool italic, bool cleared});

/// Правило второй строки целиком: и префикс, и текст, и наклон.
///
/// **Живёт здесь, а не в `build()`**, по той же причине, что
/// `buildDayBuckets` и `chatAfterDeparture`: порченое правило внутри
/// виджета не видно ни одному тесту.
///
/// `senderName` разрешает вызывающий — из уже живого `allUsersProvider`.
/// Функция чистая и в базу не ходит.
ChatPreview chatPreview({
  required Chat chat,
  required String currentUid,
  required String? senderName,
}) {
  // Чат очищен у этого человека и с тех пор ничего не приходило —
  // показывать нечего, и имя над пустотой не ставится.
  final clearedAt = chat.clearedBy[currentUid];
  final isCleared =
      clearedAt != null &&
      (chat.lastMessageTime == null ||
          !chat.lastMessageTime!.isAfter(clearedAt));
  // `cleared` отдаётся наружу, а не вычисляется вторично на экране:
  // по нему прячется ещё и время в строке, и будь это два вычисления —
  // они разошлись бы в первый же день, когда тронут одно.
  if (isCleared) {
    return (prefix: null, text: '', italic: false, cleared: true);
  }

  // «Удалил у себя» — заглушка вместо текста. Наклон здесь не украшение,
  // а признак: это не то, что написали, а то, что человек сам скрыл.
  // Имени тоже нет — заглушка про него самого, а не про автора.
  if (chat.lastMessageDeletedFor.contains(currentUid)) {
    return (
      prefix: null,
      text: '🚫 Bu mesajı sildiniz',
      italic: true,
      cleared: false,
    );
  }

  return (
    prefix: _prefixFor(chat, currentUid, senderName),
    text: chat.lastMessage,
    italic: false,
    cleared: false,
  );
}

/// Кого назвать перед текстом — и когда не называть никого.
String? _prefixFor(Chat chat, String currentUid, String? senderName) {
  // ЛИЧНЫЙ ЧАТ — имени нет: оно уже стоит заголовком этой же строки.
  // WhatsApp там его тоже не ставит.
  if (!chat.isGroup) return null;

  // СИСТЕМНАЯ ЗАПИСЬ — имени нет, текст говорит сам за себя.
  //
  // Проверяется ФЛАГ, а не пустой автор, и это не перестраховка: у всех
  // шести системных записей отправитель настоящий (группу создал
  // `creatorUid`, вышел — `uid` вышедшего, добавил, удалил и назначил
  // админом — `adminUid`). Проверка на пустоту дала бы
  // «Rafael Dagli: Rafael Dagli qrupdan çıxdı» — имя дважды.
  if (chat.lastMessageIsSystem) return null;

  final by = chat.lastMessageBy;
  // Чаты, где последнее сообщение легло до появления поля. Показать
  // нечего, и это честнее выдумки.
  if (by == null || by.isEmpty) return null;

  // СВОЁ — «Siz». Решение владельца 08.08: иначе не отличить «я написал и
  // жду ответа» от «мне написали», а это разные состояния, и в списке они
  // должны читаться по-разному.
  if (by == currentUid) return 'Siz';

  // ЧУЖОЕ В ГРУППЕ — имя. Если оно ещё не доехало или человека больше
  // нет, префикса нет вовсе: показать сырой uid хуже, чем не показать
  // ничего.
  if (senderName == null || senderName.trim().isEmpty) return null;
  return senderName.trim();
}
