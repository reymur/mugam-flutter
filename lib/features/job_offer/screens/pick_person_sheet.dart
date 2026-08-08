import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';

// ---------------------------------------------------------------------------
// «КОМУ ПРЕДЛОЖИТЬ РАБОТУ» — выбор ОДНОГО человека
// ---------------------------------------------------------------------------
// Нужен входам, которые человека не знают: день в календаре знает дату, а
// главный экран не знает ничего (пункт 6, `docs/plan.md`).
//
// СПИСОК БЕРЁТСЯ ИЗ `musiciansProvider` — ровно того, что человек видит на
// главном под «Musiqiçilər». Довод владельца 09.08: список обязан
// совпадать с виденным, иначе человек ищет знакомое имя, не находит и
// решает, что этого человека в приложении нет.
//
// (Что `musiciansProvider` и `allUsersProvider` — сегодня один и тот же
// запрос без единого фильтра, записано отдельной находкой N87. Здесь
// намеренно зовётся тот из двух, что стоит на главном: когда их сведут в
// один, это место не поменяется.)
//
// ПОИСК — ЛОКАЛЬНЫЙ, ПО УЖЕ ЗАГРУЖЕННОМУ СПИСКУ, и заведён сразу, а не
// «когда людей станет больше». Два довода, оба владельца:
//   - условие вида «завести поиск, когда станет больше N» требует, чтобы
//     кто-то заметил момент. Замечать некому — правило без сторожа это
//     память, а не защита;
//   - через `UserSearchController` (Algolia) искать нельзя: он ходит в
//     индекс, то есть искал бы НЕ ПО ТОМУ списку, который человек видит,
//     и вернул бы ровно ту беду, от которой список и выбран.
//
// Возвращает uid выбранного или `null`, если закрыли.
Future<String?> pickPersonForJobOffer(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // Ввод здесь есть (строка поиска), но терять при закрытии нечего:
    // ни одно поле не переживает выбор. Поэтому тап по фону закрывает, в
    // отличие от листа предложения (N28 — правило про листы С ВВОДОМ
    // касается введённого, которое жалко, а не любого поля).
    builder: (_) => const _PickPersonSheet(),
  );
}

class _PickPersonSheet extends ConsumerStatefulWidget {
  const _PickPersonSheet();

  @override
  ConsumerState<_PickPersonSheet> createState() => _PickPersonSheetState();
}

class _PickPersonSheetState extends ConsumerState<_PickPersonSheet> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Отбор по подстроке — по имени, инструменту и городу сразу.
  ///
  /// По трём полям, а не по одному имени: человек ищет и «Rafael», и
  /// «gitara», и «Gəncə», и все три вопроса у него одинаково законны. Поиск
  /// по одному имени заставил бы помнить имя, а помнят чаще инструмент.
  List<User> _filter(List<User> all, String myUid) {
    final q = _query.trim().toLowerCase();
    final withoutMe = all.where((u) => u.id != myUid);
    if (q.isEmpty) return withoutMe.toList();
    return withoutMe
        .where((u) =>
            u.name.toLowerCase().contains(q) ||
            u.instrument.toLowerCase().contains(q) ||
            u.city.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
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
          const Text(
            'Kimə təklif edirsiniz?',
            style: TextStyle(
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
              // Пустота из кэша — это молчание, а не ответ (N14): пока
              // список не дошёл, показывается ожидание, а не «никого нет».
              loading: () =>
                  const Center(child: CircularProgressIndicator(color: kGold)),
              error: (_, _) => const Center(
                child: Text(
                  'Siyahı yüklənmədi',
                  style: TextStyle(color: kMuted),
                ),
              ),
              data: (all) {
                final people = _filter(all, myUid);
                if (people.isEmpty) {
                  // Два разных ответа, а не один на оба случая: «никого
                  // нет вовсе» и «никто не подошёл под запрос» — разные
                  // новости, и вторая подсказывает, что делать.
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
                  itemBuilder: (_, i) => _PersonRow(user: people[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    final photo = user.photoURL;
    return ListTile(
      onTap: () => Navigator.pop(context, user.id),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: kBg3,
        backgroundImage: (photo != null && photo.isNotEmpty)
            ? NetworkImage(photo)
            : null,
        child: (photo == null || photo.isEmpty)
            ? Text(
                user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                style: const TextStyle(color: kGold, fontWeight: FontWeight.bold),
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
    );
  }
}
