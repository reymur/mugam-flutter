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
import '../../../shared/widgets/online_dot.dart';
import '../../search/screens/filter_sheet.dart';

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
      // КРУЖОК «В СЕТИ» — ТОТ ЖЕ, ЧТО В ЧАТЕ И ЕЩЁ В ОДИННАДЦАТИ МЕСТАХ
      // (решение владельца 18.09: не заводить другого).
      //
      // ПРАВИЛО НЕ ПИШЕТСЯ ЗАНОВО, А СПРАШИВАЕТСЯ: `User.isActuallyOnline` —
      // одно на весь проект. Два места, решающих «в сети ли он», разошлись бы
      // молча, и человек был бы зелёным в чате и серым здесь (N49).
      //
      // ЛИШНИХ ЧТЕНИЙ НОЛЬ. `online` и `lastSeen` приходят тем же документом
      // `users/{uid}`, что имя, фото и инструмент; список и так держит целого
      // `User`. Отдельного запроса на присутствие нет и не нужно.
      //
      // ЗДЕСЬ СТОЯЛА ЗАПИСЬ «протухание лечится таймером в состоянии списка,
      // а в строке его быть не должно — она `StatelessWidget`, и таймер
      // завёлся бы на каждую строку». Довод был верен, а вывод из него — нет:
      // таймер уехал ВНУТРЬ кружка, и двадцать кружков делят ОДИН общий
      // будильник, не заводя по своему. Строка так и осталась
      // `StatelessWidget`.
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: kBg3,
            backgroundImage: (photo != null && photo.isNotEmpty)
                ? NetworkImage(photo)
                : null,
            child: (photo == null || photo.isEmpty)
                ? Text(
                    user.name.isNotEmpty ? azUpperCase(user.name[0]) : '?',
                    style: const TextStyle(
                        color: kGold, fontWeight: FontWeight.bold),
                  )
                : null,
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: OnlineDot(user: user),
          ),
        ],
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

  // ФИЛЬТРЫ — ГОРОД, ИНСТРУМЕНТ, РЕЙТИНГ, «ONLAYN INDI» (19.09).
  //
  // **Живут в общей середине, а не в одном из листов, и это разбор, а не
  // удобство.** Признак I58: посмотреть, что идёт ПОСЛЕ общего шага. Фильтр
  // сужает список — дальше в обоих листах рисуется строка и по ней жмут.
  // Совпало, значит дело одно, значит место общее.
  //
  // **Флага «а этому фильтров не показывать» здесь НЕТ и заводить нельзя** —
  // это был бы ровно тот переключатель, по которому узнаётся склейка двух дел.
  // Одноместный лист «кому предложить работу» получает фильтры вместе с
  // многоместным, и это сказано вслух, а не сделано молча: при открытии
  // фильтров ноль, кнопка ничего не меняет, пока её не тронут.
  //
  // ОТКУДА ОНИ ВЗЯЛИСЬ. Из снятого `_ParticipantPickerDialog`
  // (`agreements_screen.dart`), где отбор делала Algolia. Здесь отбор идёт по
  // ЖИВОМУ человеку — `SearchFilters.matchesPerson`, — и «Onlayn indi»
  // впервые отвечает по-настоящему: у индекса окно запроса обязано быть шире
  // десятиминутного шага переиндексации (N57), то есть «в сети сейчас» там
  // значило «был в сети недавно».
  //
  // ЦЕНА, НАЗВАННАЯ СРАЗУ: отбор идёт ПОСЛЕ выборки, а не до. Algolia
  // отбирала на сервере и отдавала двадцать подходящих; здесь берутся все и
  // отбрасываются лишние. При двенадцати учётках прода (замер 19.09) это
  // ничего не стоит, а когда станет стоить — платить придётся за
  // `musiciansProvider`, который тянет коллекцию целиком и без фильтров.
  SearchFilters _filters = const SearchFilters();

  Future<void> _openFilters() async {
    final result = await FilterSheet.show(
      context,
      initial: _filters,
      nameController: _searchController,
    );
    if (result != null) setState(() => _filters = result);
  }

  // ЗДЕСЬ СТОЯЛО ОБНОВЛЕНИЕ ЗЕЛЁНОГО КРУЖКА ПО ТАЙМЕРУ — заведено 18.09,
  // снято 18.09 же, в тот же день, и это не переделка, а окончание работы:
  // таймер переехал ВНУТРЬ самого кружка (`shared/widgets/online_dot.dart`),
  // потому что снаружи его можно забыть. Так и вышло в десяти местах из
  // одиннадцати.

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
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: kText, fontSize: 14),
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Ad, alət və ya şəhər',
                      hintStyle: const TextStyle(color: kMuted),
                      prefixIcon: const Icon(
                        Icons.search,
                        color: kMuted,
                        size: 20,
                      ),
                      filled: true,
                      fillColor: kBg3,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
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
                const SizedBox(width: 10),
                // КНОПКА ФИЛЬТРОВ — ТА ЖЕ, ЧТО В ПОИСКЕ И В СПИСКЕ ЧАТОВ.
                //
                // Вид взят у снятого `_ParticipantPickerDialog` дословно (42×42,
                // скругление 10, значок `tune_rounded`, счётчик красным кружком
                // в углу): фильтры переехали, а не завелись заново, и выглядеть
                // они обязаны так же — иначе человек не узнает своё.
                //
                // `FilterSheet` и `SearchFilters` тоже общие, а не свои: пять
                // полей фильтра решаются в одном месте на весь проект, и второе
                // их написание разошлось бы молча (N49).
                _FilterButton(
                  activeCount: _filters.activeCount,
                  onTap: _openFilters,
                ),
              ],
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
                final found = filterPeople(
                  all,
                  myUid: widget.myUid,
                  query: _query,
                );
                // ФИЛЬТРЫ ПОСЛЕ ПОИСКА, А НЕ ВМЕСТО НЕГО: поиск отвечает «кого
                // я назвал», фильтр — «кто мне подходит», и вопросы эти
                // складываются, а не заменяют друг друга.
                final people = _filters.isEmpty
                    ? found
                    : found.where(_filters.matchesPerson).toList();
                if (people.isEmpty) {
                  // ТРИ ПУСТОТЫ, А НЕ ДВЕ (19.09, I47). Здесь их было две —
                  // «никого нет вовсе» и «никто не подошёл под запрос», — и
                  // сливать их было нельзя, потому что вторая подсказывает,
                  // что делать. С приходом фильтров появилась ТРЕТЬЯ: список
                  // не пуст и запрос не виноват, отсеял фильтр. Ответ у неё
                  // свой, потому что и делать надо своё — снять фильтр, а не
                  // переписать запрос.
                  //
                  // Порядок ветвей содержателен: сперва спрашивается фильтр,
                  // потому что он сильнее — при включённом фильтре пустой
                  // запрос НЕ означает «никого нет вовсе».
                  final String word;
                  if (!_filters.isEmpty && found.isNotEmpty) {
                    word = 'Süzgəcə uyğun adam yoxdur';
                  } else if (_query.trim().isEmpty) {
                    word = 'Hələ heç kim yoxdur';
                  } else {
                    word = 'Tapılmadı';
                  }
                  return Center(
                    child: Text(word, style: const TextStyle(color: kMuted)),
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

/// КНОПКА ФИЛЬТРОВ У ЛИСТА ВЫБОРА ЛЮДЕЙ.
///
/// **Вид перенесён из снятого `_ParticipantPickerDialog` дословно** — 42×42,
/// скругление 10, `tune_rounded` на 20, счётчик включённых красным кружком в
/// углу со смещением −4. Приводить его «к общему виду» было нельзя: фильтры
/// не заводились заново, они переехали, и человек обязан узнать своё.
///
/// **Отдельным виджетом, а не куском внутри `build`, по одной причине:** тот
/// `build` и так длинный, а этот кусок ничего не знает ни о списке, ни о
/// поиске — ему нужны число и нажатие. Это разделение по задаче, а не по
/// длине (I58).
///
/// **Что он НЕ решает:** какие поля у фильтра и что они значат. Это
/// `SearchFilters` и `FilterSheet`, общие на весь проект.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.activeCount, required this.onTap});

  final int activeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final on = activeCount > 0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: on ? kGold : kBg3,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: on ? kGold : kBorder),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Center(
              child: Icon(
                Icons.tune_rounded,
                size: 20,
                color: on ? kOnGold : kMuted,
              ),
            ),
            // СЧЁТЧИК ВКЛЮЧЁННЫХ — не украшение: включённый фильтр меняет то,
            // что человек видит, а сам по себе невидим. Без числа пустой
            // список читался бы как «никого нет» (I14 — короткий вывод,
            // принятый за хорошую новость).
            if (on)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  decoration: const BoxDecoration(
                    color: kRed,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$activeCount',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: kOnRed,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
