import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'auth_gate_screen.dart';
import '../features/agreements/screens/agreements_screen.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/auth/screens/register_screen.dart';
import '../features/board/screens/board_screen.dart';
import '../features/calls/screens/active_call_screen.dart';
import '../features/calls/screens/incoming_call_screen.dart';
import '../features/calls/screens/outgoing_call_screen.dart';
import '../features/chat/screens/chat_screen.dart';
import '../features/chats/screens/chats_screen.dart';
import '../features/friends/screens/friend_requests_screen.dart';
import '../features/friends/screens/friends_list_screen.dart';
import '../features/gigs/screens/gigs_screen.dart';
import '../features/home/screens/home_screen.dart';
import '../features/market/screens/market_screen.dart';
import '../features/profile/screens/profile_screen.dart';
import '../features/search/screens/search_screen.dart';
import '../features/starred/screens/starred_messages_screen.dart';
import '../features/stories/screens/stories_screen.dart';
import '../features/video/screens/video_screen.dart';
import 'app_tabs.dart';
import 'main_shell.dart';

/// Экран вкладки — по её имени, а не по номеру.
///
/// Отдельной картой, а не полем в `AppTab`: список вкладок описывает
/// ПОРЯДОК и не должен тянуть за собой импорты всех экранов приложения.
/// Полнота карты проверяется тестом (`test/app_tabs_test.dart`): вкладка
/// без экрана — красный тест, а не пустая ветка.
const Map<String, Widget Function()> _screensByTabId = {
  'home': HomeScreen.new,
  'agreements': AgreementsScreen.new,
  'search': SearchScreen.new,
  'board': BoardScreen.new,
  'gigs': GigsScreen.new,
  'market': MarketScreen.new,
  'stories': StoriesScreen.new,
  'video': VideoScreen.new,
  'chats': ChatsScreen.new,
  'profile': ProfileScreen.new,
};

Widget screenForTab(String id) {
  final build = _screensByTabId[id];
  // Пустой ветки не бывает: вкладка без экрана — ошибка сборки списка, а
  // не молчаливый чёрный экран.
  assert(build != null, 'у вкладки "$id" нет экрана в _screensByTabId');
  return build == null ? const SizedBox.shrink() : build();
}

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (c, s) => const AuthGateScreen(),
    ),
    GoRoute(
      path: '/login',
      builder: (c, s) => const LoginScreen(),
    ),
    GoRoute(
      path: '/register',
      builder: (c, s) => const RegisterScreen(),
    ),
    GoRoute(
      path: '/chat/:chatId',
      builder: (c, s) => ChatScreen(
        chatId: s.pathParameters['chatId']!,
        initialHighlightMessageId: s.extra as String?,
      ),
    ),
    GoRoute(
      path: '/starred',
      builder: (c, s) => const StarredMessagesScreen(),
    ),
    GoRoute(
      path: '/friend-requests',
      builder: (c, s) => const FriendRequestsScreen(),
    ),
    GoRoute(
      path: '/friends',
      builder: (c, s) => const FriendsListScreen(),
    ),
    GoRoute(
      path: '/call/incoming/:callId',
      builder: (c, s) => IncomingCallScreen(callId: s.pathParameters['callId']!),
    ),
    GoRoute(
      path: '/call/outgoing/:callId',
      builder: (c, s) => OutgoingCallScreen(callId: s.pathParameters['callId']!),
    ),
    GoRoute(
      path: '/call/active/:callId',
      builder: (c, s) => ActiveCallScreen(callId: s.pathParameters['callId']!),
    ),
    // ВЕТКИ СТРОЯТСЯ ИЗ ТОГО ЖЕ СПИСКА, что и панель (`app_tabs.dart`).
    //
    // Прежде порядок был записан здесь и в `custom_tab_bar.dart` двумя
    // копиями, а связаны они были ничем: панель отдаёт
    // `navigationShell.currentIndex` в подсветку, тап отдаёт индекс
    // обратно в `goBranch(index)`, и обе стороны верны, только пока
    // порядки совпадают. Перестановка вкладки в одном месте уводила бы
    // человека не на тот экран — молча, потому что оба списка выглядят
    // правильными по отдельности (N58).
    //
    // Теперь разойтись им негде: порядок один, а экран для вкладки
    // берётся по её имени. Отсутствующее имя не соберётся — тест на
    // полноту `_screensByTabId` держит это отдельно.
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          MainShell(navigationShell: navigationShell),
      branches: [
        for (final tab in kAppTabs)
          StatefulShellBranch(routes: [
            GoRoute(
              path: tab.path,
              builder: (c, s) => screenForTab(tab.id),
            ),
          ]),
      ],
    ),
  ],
);
