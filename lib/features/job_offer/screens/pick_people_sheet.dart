import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import 'person_picker_core.dart';

// ---------------------------------------------------------------------------
// «КОГО ПОЗВАТЬ В СОСТАВ» — выбор НЕСКОЛЬКИХ человек
// ---------------------------------------------------------------------------
// Работа 7, шаг 3 (`docs/plan.md`), 08.09. Второй из двух тонких листов над
// общей серединой — решение владельца 08.09.
//
// ПОЧЕМУ ОТДЕЛЬНЫЙ ЛИСТ, А НЕ ФЛАГ В ОДНОМЕСТНОМ, и довод не про
// аккуратность. Раунд предложения работы живёт на документе ЧАТА, и он один
// на пару: «кому предложить работу» одноместно **по устройству**. «Кого
// позвать в состав» многоместно **по смыслу**. Это два разных вопроса, а не
// один с флажком (I58).
//
// Довод владельца против расширения, дословно: флаг ехал бы через ПЯТЬ
// входов предложения работы и в трёх всегда `false` — склейка двух дел, и
// однажды он получит `true` не там.
//
// ЧТО ЗДЕСЬ, А ЧТО В СЕРЕДИНЕ. Здесь только расхождение: набор отмеченных,
// отметка справа у строки, кнопка «готово» и её счётчик. Список, поиск, вид
// строки и три состояния списка — общие, в `person_picker_core.dart`.
//
// ВОЗВРАЩАЕТ список uid в порядке отметки или `null`, если закрыли.
// **`null` и пустой список — РАЗНОЕ** (I47): первое значит «передумал»,
// второе — «нажал „готово“, не выбрав никого». Второе сегодня невозможно —
// кнопка при пустом наборе не нажимается, — но различие сохранено в типе,
// чтобы вызывающий не решал за человека.
Future<List<String>?> pickPeopleForLineup(BuildContext context) {
  return showModalBottomSheet<List<String>>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // ЗАКРЫТИЕ ПО ТАПУ ФОНА ЗАПРЕЩЕНО, и это отличие от одноместного листа
    // по существу, а не по вкусу. Там терять нечего: выбор человека и есть
    // единственное действие, и закрытие ничего не рушит. Здесь человек уже
    // отметил нескольких — набор это введённое, которое жалко (N28).
    isDismissible: false,
    builder: (_) => const _PickPeopleSheet(),
  );
}

class _PickPeopleSheet extends ConsumerStatefulWidget {
  const _PickPeopleSheet();

  @override
  ConsumerState<_PickPeopleSheet> createState() => _PickPeopleSheetState();
}

class _PickPeopleSheetState extends ConsumerState<_PickPeopleSheet> {
  /// Отмеченные, В ПОРЯДКЕ ОТМЕТКИ.
  ///
  /// Список, а не множество: порядок — это то, в каком человек собирал
  /// состав, и он же порядок приглашений. Множество вернуло бы их в порядке
  /// хеша, то есть в случайном, и «позвал сперва барабанщика» превратилось
  /// бы в «позвал кого попало».
  final List<String> _picked = [];

  void _toggle(String uid) {
    setState(() {
      if (!_picked.remove(uid)) _picked.add(uid);
    });
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return PersonPickerBody(
      title: 'Kimi çağırırsınız?',
      myUid: myUid,
      // ВСЁ РАСХОЖДЕНИЕ МНОГОМЕСТНОГО ЛИСТА — В ЭТИХ ДВУХ КУСКАХ: нажатие
      // отмечает вместо закрытия, справа стоит отметка. Общая середина о
      // существовании отметок не знает и знать не должна.
      rowBuilder: (user) {
        final on = _picked.contains(user.id);
        return PersonRow(
          user: user,
          onTap: () => _toggle(user.id),
          // ОТМЕТКА ВИДНА И БЕЗ ЦВЕТА. Галочка против пустого кружка — это
          // разница ФОРМЫ, а не оттенка: цветом одним различать нельзя, у
          // нас это уже решено для состояния вечера (решение 10.08 о форме
          // статуса).
          trailing: Icon(
            on ? Icons.check_circle : Icons.radio_button_unchecked,
            color: on ? kGold : kMuted,
            size: 22,
          ),
        );
      },
      footer: _Footer(
        count: _picked.length,
        // ПУСТОЙ НАБОР — КНОПКА НЕ НАЖИМАЕТСЯ, а не «нажимается и ничего не
        // делает». Кнопка, которой некуда вести, неотличима от поломки
        // (N65, N146) — поэтому она гаснет, и видно, что она ждёт выбора.
        onDone: _picked.isEmpty
            ? null
            : () => Navigator.pop(context, List<String>.from(_picked)),
        onCancel: () => Navigator.pop(context),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.count,
    required this.onDone,
    required this.onCancel,
  });

  final int count;
  final VoidCallback? onDone;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            TextButton(
              onPressed: onCancel,
              child: const Text(
                'İmtina',
                style: TextStyle(color: kMuted),
              ),
            ),
            const Spacer(),
            // СЧЁТЧИК РЯДОМ С КНОПКОЙ, А НЕ В ЗАГОЛОВКЕ: человек смотрит на
            // кнопку, когда решает, всех ли отметил. Число в шапке отвечало
            // бы на тот же вопрос там, куда он в этот миг не смотрит.
            ElevatedButton(
              onPressed: onDone,
              style: ElevatedButton.styleFrom(
                backgroundColor: kGold,
                foregroundColor: kOnGold,
                disabledBackgroundColor: kBg3,
                disabledForegroundColor: kMuted,
              ),
              child: Text(count == 0 ? 'Seç' : 'Seçildi: $count'),
            ),
          ],
        ),
      ),
    );
  }
}
