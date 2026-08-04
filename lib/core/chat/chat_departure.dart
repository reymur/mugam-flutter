// Что остаётся у чата, когда человек перестаёт быть его участником.
//
// Правило вынесено сюда из двух мест сразу, потому что расходились они
// ровно в том, в чём расходиться не должны. Членство снимали оба —
// `leaveGroup` (вышел сам) и `removeGroupMember` (удалил админ), — а
// отметку присутствия `activeUsers` не снимал НИ ОДИН. Поле пережило
// членство, и это не косметика: правило чтения чата доказывается полем
// `members`, поэтому вышедший, застрявший в `activeUsers`, оказывался
// человеком, который в чате уже не состоит, но признак присутствия в нём
// имеет. Опыт на двух наборах правил 04.08 показал, чем это оборачивается:
// стоило добавить в правило чтения дизъюнкт по `activeUsers` (напрашивалось
// как починка N32), и вышедший получал документ чужого чата вместе с
// `lastMessage` и списком участников.
//
// Поэтому правило одно на оба пути. Разойтись им теперь негде: разойтись
// можно только вместе.
//
// Чистая функция без Firebase намеренно — иначе проверить её было бы
// нечем, ровно как правило переноса участников до N31.

class ChatAfterDeparture {
  const ChatAfterDeparture({
    required this.members,
    required this.admins,
    required this.activeUsers,
    required bool wasAdmin,
  }) : _wasAdmin = wasAdmin;

  /// Участники без ушедшего.
  final List<String> members;

  /// Администраторы без ушедшего. Повышение сюда НЕ входит: кого именно
  /// повышать, решает случай, а случай в чистой функции не живёт. Решение
  /// «повышать ли вообще» — здесь, в [needsAdminPromotion]; выбор — за
  /// вызывающим.
  final List<String> admins;

  /// Отметки присутствия без ушедшего — то самое поле, которое раньше
  /// переживало членство.
  final List<String> activeUsers;

  final bool _wasAdmin;

  /// Группа не должна остаться без администратора: если ушёл последний и
  /// люди в ней ещё есть, кого-то надо повысить.
  ///
  /// Условие намеренно включает «ушедший БЫЛ администратором» — без этого
  /// правило начало бы повышать людей в группах, где администратора не было
  /// и до ухода, а это уже не сохранение прежнего поведения, а тихая его
  /// правка под видом переноса.
  bool get needsAdminPromotion =>
      _wasAdmin && admins.isEmpty && members.isNotEmpty;
}

/// Единственное место, где человек вычёркивается из чата.
ChatAfterDeparture chatAfterDeparture({
  required List<String> members,
  required List<String> admins,
  required List<String> activeUsers,
  required String uid,
}) {
  return ChatAfterDeparture(
    members: members.where((m) => m != uid).toList(),
    admins: admins.where((a) => a != uid).toList(),
    activeUsers: activeUsers.where((a) => a != uid).toList(),
    wasAdmin: admins.contains(uid),
  );
}
