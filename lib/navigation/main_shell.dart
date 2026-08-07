import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../firebase/firestore_service.dart' show chatsProvider;
import '../shared/widgets/custom_tab_bar.dart';

/// Оболочка приложения: экран вкладки плюс нижняя панель.
///
/// СЧЁТЧИК НЕПРОЧИТАННОГО (N57, работа 07.08). Раньше панель получала
/// бейдж-умолчание `0`, то есть не показывала его никогда — и потому
/// привязка бейджа к вкладке по номеру не могла себя выдать ни при какой
/// перестановке. Теперь число считается здесь.
///
/// **Считаются ЧАТЫ с непрочитанным, а не сообщения.** Одно и то же
/// состояние прода 07.08 даёт «7» или «29» — разница втрое. «3» читается
/// как «три разговора ждут» и называет действие; «29» называет объём и
/// пугает, а число сообщений в каждом чате и так стоит на его карточке.
///
/// **Новой подписки это не заводит.** `chatsProvider` — семейство
/// Riverpod, и экран «Mesaj» слушает ровно его же: на одинаковый аргумент
/// отдаётся та же подписка, а не вторая. Разница с прежним поведением
/// только в том, что слушатель больше не закрывается при уходе с вкладки.
/// Цена этой разницы посчитана по проду: у человека максимум 6 чатов,
/// записей в документы чатов 4 за сутки (772 за неделю, но неделя
/// включает наш собственный прогон — I8), то есть десятки чтений в сутки
/// против бесплатных 50 000.
///
/// **Серверный агрегат `unreadTotal` на `users/{uid}` отвергнут** и не
/// «пока», а по причине: запись в документ пользователя поднимает
/// `onUserWritten`, который без разбора шлёт запись в Algolia (N43).
/// Агрегат на каждое сообщение размножил бы ровно то, что мы считаем
/// лишним. Пока N43 открыт, «дешёвый» вариант дороже этого.
class MainShell extends ConsumerWidget {
  const MainShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    // Пустой uid бывает на выходе из аккаунта: запрос по нему ничего не
    // вернёт, и просить его незачем — панель просто без бейджа.
    final chats = uid.isEmpty
        ? const []
        : (ref.watch(chatsProvider(uid)).asData?.value ?? const []);
    final unreadChats = chats.where((c) => c.unreadCount > 0).length;

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: CustomTabBar(
        currentIndex: navigationShell.currentIndex,
        onTap: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        unreadCount: unreadChats,
      ),
    );
  }
}
