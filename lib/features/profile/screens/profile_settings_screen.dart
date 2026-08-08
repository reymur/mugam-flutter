import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/settings/start_tab_settings.dart';
import '../../../core/store/local_message_store.dart';
import '../../../navigation/app_tabs.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/auth_service.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/push_notification_service.dart';

// Reached from the gear icon in ProfileScreen's header (Navigator.push,
// same pattern as EditProfileScreen and chats_screen.dart's
// AppSettingsScreen — a real screen with its own back button, not an
// inline tab). Everything that used to be a horizontal tab (Video,
// Tədbirlər, Rəylər) or _SettingsTab's inline list (Dost sorğuları,
// Seçilmiş mesajlar, Çıxış) now lives here as one list, and each row opens
// its own screen in turn — see _ComingSoonScreen for the three still-
// unbuilt sections, and '/friend-requests' / '/starred' for the two that
// already had real screens. Çıxış is the one deliberate exception: it's an
// action with a confirmation dialog, not content to display, so it stays
// an in-place action rather than a pointless screen of its own.
class ProfileSettingsScreen extends ConsumerWidget {
  const ProfileSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final incomingAsync = ref.watch(incomingFriendRequestsProvider(currentUid));
    final startTabId = ref.watch(startTabProvider);
    final startTabLabel = kAppTabs
        .firstWhere(
          (t) => t.id == startTabId,
          orElse: () => kAppTabs.first,
        )
        .label;
    // Same rollback-safety contract as before this moved: an AsyncError
    // here (e.g. firestore.rules for friendRequests rolled back while this
    // build is still installed) hides the Dost sorğuları row entirely
    // rather than showing a badge that can never load and leading to a
    // screen that can only ever say "Xəta baş verdi".
    final friendRequestsAvailable = !incomingAsync.hasError;
    final incomingCount = incomingAsync.asData?.value.length ?? 0;
    final hasUnread = ref.watch(hasUnreadFriendRequestsProvider(currentUid));

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Ayarlar',
          style: GoogleFonts.nunito(fontSize: 18, color: kText),
        ),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.event, color: kGold),
            title: const Text('Tədbirlər', style: TextStyle(color: kText)),
            trailing: const Icon(Icons.chevron_right, color: kMuted),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    const _ComingSoonScreen(title: 'Tədbirlər', emoji: '📅'),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.video_library, color: kGold),
            title: const Text('Video', style: TextStyle(color: kText)),
            trailing: const Icon(Icons.chevron_right, color: kMuted),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    const _ComingSoonScreen(title: 'Video', emoji: '🎬'),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.star_border, color: kGold),
            title: const Text('Rəylər', style: TextStyle(color: kText)),
            trailing: const Icon(Icons.chevron_right, color: kMuted),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    const _ComingSoonScreen(title: 'Rəylər', emoji: '⭐'),
              ),
            ),
          ),
          const Divider(color: kBorder, height: 1),
          ListTile(
            leading: const Icon(Icons.group, color: kGold),
            title: const Text('Dostlar', style: TextStyle(color: kText)),
            trailing: const Icon(Icons.chevron_right, color: kMuted),
            onTap: () => context.push('/friends'),
          ),
          if (friendRequestsAvailable)
            ListTile(
              leading: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.people_alt, color: kGold),
                  // Unread dot — separate from the existing gold pending-
                  // count badge in `trailing` below; this one tracks
                  // "seen since last visit" (hasUnreadFriendRequestsProvider),
                  // not raw pending count.
                  if (hasUnread)
                    Positioned(
                      top: -2,
                      right: -2,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: kRed,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              title: const Text(
                'Dost sorğuları',
                style: TextStyle(color: kText),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (incomingCount > 0) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: kGold,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$incomingCount',
                        style: const TextStyle(
                          color: kOnGold,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  const Icon(Icons.chevron_right, color: kMuted),
                ],
              ),
              onTap: () => context.push('/friend-requests'),
            ),
          ListTile(
            leading: const Icon(Icons.star, color: kGold),
            title: const Text(
              'Seçilmiş mesajlar',
              style: TextStyle(color: kText),
            ),
            trailing: const Icon(Icons.chevron_right, color: kMuted),
            onTap: () => context.push('/starred'),
          ),
          const Divider(color: kBorder, height: 1),
          // «Tətbiq açılır…» — с какой вкладки открывается приложение.
          // Список строится ИЗ kAppTabs, а не отдельным перечнем: два
          // списка одного и того же расходятся молча, и ровно из этого
          // вышла N58.
          ListTile(
            leading: const Icon(Icons.play_circle_outline, color: kGold),
            title: const Text('Tətbiq açılır', style: TextStyle(color: kText)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  startTabLabel,
                  style: const TextStyle(color: kMuted, fontSize: 14),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, color: kMuted),
              ],
            ),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              backgroundColor: kBg2,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
              ),
              builder: (sheetContext) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Tətbiq açılır',
                          style: TextStyle(
                            color: kGold,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    for (final tab in kAppTabs)
                      ListTile(
                        leading: Text(
                          tab.emoji,
                          style: const TextStyle(fontSize: 20),
                        ),
                        title: Text(
                          tab.label,
                          style: const TextStyle(color: kText),
                        ),
                        trailing: tab.id == startTabId
                            ? const Icon(Icons.check, color: kGold)
                            : null,
                        onTap: () {
                          ref.read(startTabProvider.notifier).setTab(tab.id);
                          Navigator.pop(sheetContext);
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(color: kBorder, height: 1),
          ListTile(
            leading: const Icon(Icons.logout, color: kRed),
            title: const Text('Çıxış', style: TextStyle(color: kRed)),
            onTap: () => _confirmLogout(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text('Çıxış', style: TextStyle(color: kText)),
        content: const Text(
          'Hesabdan çıxmaq istəyirsiniz?',
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Ləğv et', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Çıxış', style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    final service = ref.read(firestoreServiceProvider);
    // Best-effort presence/active-user cleanup — must never block the
    // actual sign-out below. Confirmed on-device: a slow/stuck network
    // left one of these awaits hanging indefinitely with no error ever
    // surfacing, making "Çıxış" look completely unresponsive since neither
    // of these calls had its own timeout. Each already logs its own
    // failure to Crashlytics internally, so swallowing here doesn't lose
    // that signal.
    if (uid != null && uid.isNotEmpty) {
      try {
        await service
            .setUserPresence(uid, online: false)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
      try {
        await service
            .clearActiveUserFromAllChats(uid)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
      // Токен этого устройства снимается с уходящего аккаунта здесь же и
      // именно ДО logout(): правила разрешают писать в
      // users/{uid}/pushTokens только самому владельцу, после выхода
      // удалить его уже нечем.
      //
      // Без этого документ токена оставался у прежнего аккаунта навсегда,
      // и push для него уходил на устройство, где теперь сидит другой
      // человек — с именем отправителя и началом текста в теле
      // уведомления. В проде 02.08 таких общих токенов нашлось три, один
      // сразу у трёх пользователей.
      try {
        await PushNotificationService.instance
            .unregisterToken(uid)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    try {
      await ref.read(localMessageStoreProvider).clearAllForSignOut();
      await AuthService().logout();
      if (context.mounted) context.go('/login');
    } catch (e, st) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Çıxış zamanı xəta baş verdi: $e'),
            backgroundColor: kRed,
          ),
        );
      }
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'ProfileSettingsScreen: sign out failed',
      );
    }
  }
}

// Full-screen stand-in for the three sections that don't have real content
// yet (Video/Tədbirlər/Rəylər) — same emoji+text placeholder that used to
// render inline as a tab, now with its own AppBar/back button since each
// row in ProfileSettingsScreen opens a real screen rather than switching
// an inline tab index.
class _ComingSoonScreen extends StatelessWidget {
  const _ComingSoonScreen({required this.title, required this.emoji});

  final String title;
  final String emoji;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          title,
          style: GoogleFonts.nunito(fontSize: 18, color: kText),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            const Text(
              'Tezliklə əlavə olunacaq',
              style: TextStyle(fontSize: 14, color: kMuted),
            ),
          ],
        ),
      ),
    );
  }
}
