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
import 'main_shell.dart';

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
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          MainShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(path: '/home', builder: (c, s) => const HomeScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
              path: '/agreements',
              builder: (c, s) => const AgreementsScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/search', builder: (c, s) => const SearchScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/board', builder: (c, s) => const BoardScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/gigs', builder: (c, s) => const GigsScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/market', builder: (c, s) => const MarketScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/stories', builder: (c, s) => const StoriesScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/video', builder: (c, s) => const VideoScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/chats', builder: (c, s) => const ChatsScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/profile', builder: (c, s) => const ProfileScreen()),
        ]),
      ],
    ),
  ],
);
