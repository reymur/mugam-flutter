import 'package:flutter/material.dart';

import '../../core/agreements/event_answer_reply.dart';
import '../../core/theme/colors.dart';
import '../../firebase/models.dart';
import 'event_conflict_banner.dart';

/// ОКНО «ТЫ УЖЕ ЗАНЯТ В ЭТО ВРЕМЯ» — спрашивается В МОМЕНТ СОГЛАСИЯ.
///
/// Второе окно заведено не по недосмотру: общим у него с `EventConflictDialog`
/// остаётся **правило** (`resolveConflictBanner`, `exactConflictsAt`), а не
/// вопрос. Там человек создаёт или правит СВОЁ мероприятие и может распорядиться
/// мешающим; здесь он отвечает за себя на ЧУЖОМ вечере и распорядиться не может
/// ничем, кроме собственного ответа.
///
/// ДВА УРОКА N39, ЗАПИСАННЫЕ ЗДЕСЬ, А НЕ В КОНСПЕКТЕ — их читают отсюда:
///
/// **1. Ответа, трогающего ЧУЖОЙ документ, здесь быть не может по правилам.**
/// В N39 главная золотая кнопка удаляла постороннее мероприятие у человека,
/// пришедшего снять участника. Правило шага 4 разрешает участнику тронуть ровно
/// свой ключ (`affectedKeys().hasOnly([request.auth.uid])`), поэтому «удалить
/// мешающее» / «заменить» — не «неудобный» ответ, а **невыразимый**: сервер
/// откажет, что бы ни было нажато.
///
/// **2. Ветки по владению мешающего вечера нет** — ни один из трёх ответов
/// мешающего документа не касается, значит различать своё и чужое незачем. В
/// N39 дефектом была ровно подмена вопроса владением там, где ответ от него не
/// зависел. Утверждение записано исполняемо: `answerConflictChoices()` не
/// принимает владения вовсе, и это закреплено тестом.
class AnswerConflictDialog extends StatelessWidget {
  const AnswerConflictDialog({
    super.key,
    required this.conflicts,
  });

  /// ВСЕ, кто занял эту минуту, а не первый из них (N51). На одно время
  /// свободно встают своё мероприятие и чужое, где человек участник.
  final List<PersonalEvent> conflicts;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kBg2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        conflicts.length == 1
            ? 'Bu vaxtda sizin tədbiriniz var'
            : 'Bu vaxtda sizin ${conflicts.length} tədbiriniz var',
        style: const TextStyle(color: kText, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Чем именно занято — единственное место, где это сказано. Без него
          // человек решает вслепую: «занято» без имени вечера не отличает
          // важное от проходного.
          for (final e in conflicts) ...[
            Text(eventConflictSummary(e), style: kWarnFactStyle),
            const SizedBox(height: 6),
          ],
        ],
      ),
      actions: [
        // «Посмотреть» стоит первым и ничего не пишет: прежде чем решать, надо
        // увидеть, о чём речь.
        TextButton(
          onPressed: () =>
              Navigator.pop(context, AnswerConflictChoice.view),
          child: const Text('Bax', style: TextStyle(color: kMuted)),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, AnswerConflictChoice.cannotGo),
          child: const Text('Bacarmıram', style: TextStyle(color: kMuted)),
        ),
        // «Всё равно иду» — главный ответ окна, и он СОЗИДАТЕЛЬНЫЙ: человек
        // подтверждает то, ради чего сюда пришёл. В N39 главной кнопкой было
        // разрушительное действие над чужим документом — здесь главная кнопка
        // не трогает ничего, кроме собственного ответа.
        TextButton(
          onPressed: () =>
              Navigator.pop(context, AnswerConflictChoice.goAnyway),
          child: const Text('Yenə də gəlirəm',
              style: TextStyle(color: kGold, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
