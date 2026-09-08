/// СЕРЕДИНА ДВУХ ЛИСТОВ ВЫБОРА ЛЮДЕЙ — общая часть ДО расхождения.
///
/// **Заведено 08.09, работа 7, шаг 2 (`docs/plan.md`). Поведение не
/// меняется ни на экран: это перенос, а не правка.**
///
/// --- ЗАЧЕМ, И ЭТО РЕШЕНИЕ ВЛАДЕЛЬЦА, А НЕ УБОРКА ---
///
/// Вопрос стоял так: одноместный лист «кому предложить работу» уже есть, а
/// многоместный «кого позвать в состав» нужен. Расширить первый флагом или
/// завести второй копией?
///
/// Отвергнуты оба, доводы владельца 08.09 дословно:
///   • **расширение** заводит флаг, который едет через ПЯТЬ входов
///     предложения работы и в трёх всегда `false`, — это склейка двух дел, и
///     однажды он получит `true` не там. Переключатель «а этому не делать»
///     в объединённой функции есть признак того, что объединены два
///     действия (I58);
///   • **второй лист копией** дублирует правило «список обязан совпадать с
///     виденным на главном» (решение владельца 09.08), а дубли расходились
///     и находились случайно — не меньше четырёх названных случаев: N74,
///     N76, N94, N117.
///
/// --- ЧТО ЗДЕСЬ, А ЧТО ОСТАЁТСЯ ЛИСТАМ ---
///
/// Правило I58 в обратную сторону: **сводить по задаче, а не по совпадению
/// вида**, и общей становится ровно часть ДО расхождения.
///
/// Здесь — то, у чего вопрос ОДИН на оба листа:
///   • откуда берутся люди ([musiciansProvider]);
///   • по каким полям идёт поиск ([filterPeople]);
///   • как выглядит строка человека ([PersonRow]);
///   • что показывать вместо списка, пока он не дошёл или не нашёлся
///     ([PersonPickerBody]).
///
/// Листам остаётся то, где вопрос РАЗНЫЙ: сколько можно отметить, что
/// делает нажатие на строку, есть ли кнопка «готово» и какой заголовок.
///
/// **Флага режима здесь нет ни одного, и это проверяемо:** ни одна функция
/// ниже не принимает признак «одноместный/многоместный». Расхождение
/// выражено тем, что лист ПЕРЕДАЁТ (свой `rowBuilder`, свой заголовок, свой
/// низ), а не тем, что общая часть спрашивает, кто её зовёт.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';

/// Отбор по подстроке — по имени, инструменту и городу сразу.
///
/// По трём полям, а не по одному имени: человек ищет и «Rafael», и
/// «gitara», и «Gəncə», и все три вопроса у него одинаково законны. Поиск по
/// одному имени заставил бы помнить имя, а помнят чаще инструмент.
///
/// **Себя в списке нет никогда** — ни в одном из двух листов: предложить
/// работу себе и позвать себя в свой же состав одинаково бессмысленны.
///
/// **Чистая функция, и это выигрыш переноса, а не его цель.** Пока правило
/// жило внутри состояния виджета, проверить его было нечем — тот же довод,
/// по которому заведены `event_edit` и `agreement_cancel`.
List<User> filterPeople(
  List<User> all, {
  required String myUid,
  required String query,
}) {
  final q = azLowerCase(query.trim());
  final withoutMe = all.where((u) => u.id != myUid);
  if (q.isEmpty) return withoutMe.toList();
  return withoutMe
      .where((u) =>
          azLowerCase(u.name).contains(q) ||
          azLowerCase(u.instrument).contains(q) ||
          azLowerCase(u.city).contains(q))
      .toList();
}

/// Строка человека в списке выбора.
///
/// **[onTap] и [trailing] — это и есть точка расхождения двух листов**, и
/// потому они параметры, а не флаг: одноместный лист закрывается по нажатию
/// и ничего не рисует справа, многоместный отмечает и рисует отметку. Ни
/// одна из двух надобностей не заставляет строку спрашивать, кто её зовёт.
class PersonRow extends StatelessWidget {
  const PersonRow({
    super.key,
    required this.user,
    required this.onTap,
    this.trailing,
  });

  final User user;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final photo = user.photoURL;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: kBg3,
        backgroundImage: (photo != null && photo.isNotEmpty)
            ? NetworkImage(photo)
            : null,
        child: (photo == null || photo.isEmpty)
            ? Text(
                user.name.isNotEmpty ? azUpperCase(user.name[0]) : '?',
                style:
                    const TextStyle(color: kGold, fontWeight: FontWeight.bold),
              )
            : null,
      ),
      title: Text(
        user.name,
        style: const TextStyle(color: kText, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [user.instrument, user.city].where((s) => s.isNotEmpty).join(' · '),
        style: const TextStyle(color: kMuted, fontSize: 12),
      ),
      trailing: trailing,
    );
  }
}

/// Оболочка листа: заголовок, строка поиска, список и три его состояния.
///
/// **Три состояния списка разведены здесь, а не в каждом листе**, потому что
/// путать их одинаково вредно обоим:
///   • **пока не дошёл** — ожидание, а не «никого нет». Пустота из кэша это
///     молчание, а не ответ (N14);
///   • **не дошёл вовсе** — свои слова про отказ;
///   • **дошёл, но пуст** — два РАЗНЫХ ответа: «никого нет вовсе» и «никто
///     не подошёл под запрос». Вторая новость подсказывает, что делать, и
///     сливать её с первой нельзя (I47).
///
/// [footer] — низ листа; у одноместного его нет, у многоместного там кнопка
/// «готово». `null` значит «низа нет», а не «низ пустой».
class PersonPickerBody extends ConsumerStatefulWidget {
  const PersonPickerBody({
    super.key,
    required this.title,
    required this.myUid,
    required this.rowBuilder,
    this.footer,
  });

  final String title;
  final String myUid;

  /// Как нарисовать строку. Оба листа зовут [PersonRow], но с разными
  /// [PersonRow.onTap] и [PersonRow.trailing] — в этом и всё расхождение.
  final Widget Function(User user) rowBuilder;

  final Widget? footer;

  @override
  ConsumerState<PersonPickerBody> createState() => _PersonPickerBodyState();
}

class _PersonPickerBodyState extends ConsumerState<PersonPickerBody> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncUsers = ref.watch(musiciansProvider);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: EdgeInsets.only(top: 80, bottom: bottomInset),
      decoration: const BoxDecoration(
        color: kBg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 16),
          Text(
            widget.title,
            style: const TextStyle(
              color: kText,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: kText, fontSize: 14),
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Ad, alət və ya şəhər',
                hintStyle: const TextStyle(color: kMuted),
                prefixIcon: const Icon(Icons.search, color: kMuted, size: 20),
                filled: true,
                fillColor: kBg3,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: kBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: kBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: kGold),
                ),
              ),
            ),
          ),
          Expanded(
            child: asyncUsers.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator(color: kGold)),
              error: (_, _) => const Center(
                child: Text(
                  'Siyahı yüklənmədi',
                  style: TextStyle(color: kMuted),
                ),
              ),
              data: (all) {
                final people = filterPeople(
                  all,
                  myUid: widget.myUid,
                  query: _query,
                );
                if (people.isEmpty) {
                  return Center(
                    child: Text(
                      _query.trim().isEmpty
                          ? 'Hələ heç kim yoxdur'
                          : 'Tapılmadı',
                      style: const TextStyle(color: kMuted),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 20),
                  itemCount: people.length,
                  itemBuilder: (_, i) => widget.rowBuilder(people[i]),
                );
              },
            ),
          ),
          if (widget.footer != null) widget.footer!,
        ],
      ),
    );
  }
}
