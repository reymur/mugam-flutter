import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/search/user_search_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import '../../settings/screens/app_settings_screen.dart';
import '../../status/screens/create_status_screen.dart';
import '../../status/screens/status_viewer_screen.dart';
import '../widgets/status_feed_bar.dart';
import 'create_group_screen.dart';

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _searchScrollController = ScrollController();
  late final String _currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  // A query searches Algolia across every user (same as search_screen.dart),
  // not just this user's own chats — a brand-new account with zero
  // conversations would otherwise have no way to find anyone to message
  // from this tab at all. Empty query keeps the original behavior: the
  // existing chats list, unfiltered.
  late final UserSearchController _searchCtrl = UserSearchController(
    excludeUids: [_currentUid],
  );
  bool _openingChat = false;

  bool get _isSearching => _searchController.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _searchScrollController.addListener(_onSearchScroll);
  }

  void _onSearchChanged() {
    setState(() {}); // toggle between the chats list and search results
    _searchCtrl.search(_searchController.text);
  }

  void _onSearchScroll() {
    if (!_searchCtrl.hasMore || _searchCtrl.isLoading || _searchCtrl.isLoadingMore) {
      return;
    }
    if (_searchScrollController.position.pixels >=
        _searchScrollController.position.maxScrollExtent - 200) {
      _searchCtrl.loadMore();
    }
  }

  // Same find-or-create semantics whether `user` is someone already chatted
  // with (getOrCreateDirectChat just resolves back to that existing chat —
  // see its own doc comment, firestore_service.dart) or a brand-new contact
  // discovered only through this search.
  Future<void> _openChatWith(User user) async {
    if (_openingChat) return;
    setState(() => _openingChat = true);
    try {
      final chatId = await ref.read(firestoreServiceProvider).getOrCreateDirectChat(
            myUid: _currentUid,
            otherUid: user.id,
          );
      if (!mounted) return;
      context.push('/chat/$chatId');
    } finally {
      if (mounted) setState(() => _openingChat = false);
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchScrollController.removeListener(_onSearchScroll);
    _searchScrollController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('MY UID: ${FirebaseAuth.instance.currentUser?.uid}');
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final chatsAsync = ref.watch(chatsProvider(currentUid));

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.settings, color: kGold),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AppSettingsScreen()),
          ),
        ),
        title: Text(
          'Mesajlar',
          style: GoogleFonts.nunito(fontSize: 20, color: kText),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add, color: kGold),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          StatusFeedBar(
            currentUid: currentUid,
            onCreateStatus: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CreateStatusScreen()),
            ),
            onOpenStatus: (ownerUid) {
              return Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StatusViewerScreen(
                    initialOwnerUid: ownerUid,
                    currentUid: currentUid,
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: 8,
            ),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: kText),
              decoration: InputDecoration(
                filled: true,
                fillColor: kBg3,
                hintText: '🔍 Axtar...',
                hintStyle: const TextStyle(color: kMuted),
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
            child: _isSearching
                ? _buildUserSearchResults()
                : chatsAsync.when(
                    loading: () => const Center(
                      child: CircularProgressIndicator(color: kGold),
                    ),
                    error: (err, stack) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          err.toString(),
                          style: const TextStyle(color: kRed, fontSize: 12),
                        ),
                      ),
                    ),
                    data: (chats) {
                      if (chats.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('💬', style: TextStyle(fontSize: 52)),
                                const SizedBox(height: 12),
                                Text(
                                  'Hələ mesaj yoxdur',
                                  style: GoogleFonts.nunito(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: kText,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Musiqiçilərlə əlaqə saxlamaq üçün onların profilinə keçin',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 13, color: kMuted),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      return ListView.builder(
                        itemCount: chats.length,
                        itemBuilder: (context, index) {
                          final chat = chats[index];
                          return _ChatListItem(
                            chat: chat,
                            currentUid: currentUid,
                            onTap: () => context.push('/chat/${chat.id}'),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // Query non-empty: search every user via Algolia (same data source/
  // debounce/pagination as search_screen.dart — see UserSearchController),
  // not just this user's own chats. Tapping a result finds-or-creates the
  // 1:1 chat and opens it, whether or not one already existed.
  Widget _buildUserSearchResults() {
    return ListenableBuilder(
      listenable: _searchCtrl,
      builder: (context, _) {
        if (_searchCtrl.isLoading) {
          return const Center(child: CircularProgressIndicator(color: kGold));
        }
        if (_searchCtrl.error != null) {
          return Center(
            child: Text(_searchCtrl.error!, style: const TextStyle(color: kMuted)),
          );
        }

        final results = _searchCtrl.results;
        if (results.isEmpty) {
          return const Center(
            child: Text(
              'Axtarış nəticəsi tapılmadı',
              style: TextStyle(color: kMuted, fontSize: 14),
            ),
          );
        }

        return ListView.builder(
          controller: _searchScrollController,
          itemCount: results.length + (_searchCtrl.isLoadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= results.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator(color: kGold)),
              );
            }
            final user = results[index];
            return ListTile(
              enabled: !_openingChat,
              onTap: () => _openChatWith(user),
              leading: AvatarRing(
                photoURL: user.photoURL,
                fallbackEmoji: user.emoji,
                hasUnviewed: false,
                size: 48,
              ),
              title: Text(
                user.name,
                style: GoogleFonts.nunito(fontWeight: FontWeight.w700, color: kText),
              ),
              subtitle: Text(
                [user.instrument, user.city].where((s) => s.isNotEmpty).join(' · '),
                style: const TextStyle(color: kMuted, fontSize: 12.5),
              ),
              trailing: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: user.isActuallyOnline ? kGreen : kMuted,
                  shape: BoxShape.circle,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ChatListItem extends ConsumerWidget {
  final Chat chat;
  final String currentUid;
  final VoidCallback onTap;

  const _ChatListItem({
    required this.chat,
    required this.currentUid,
    required this.onTap,
  });

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final now = DateTime.now();
    final isToday =
        time.year == now.year && time.month == now.month && time.day == now.day;
    return isToday
        ? DateFormat('HH:mm').format(time)
        : DateFormat('dd.MM').format(time);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // mugam-v2 writes a 1:1 chat's `name`/`emoji` fields from the
    // initiator's perspective (the other participant's name/emoji at
    // creation time), never updating them afterwards. The recipient reading
    // that field back sees their OWN name/emoji instead of the initiator's.
    // Resolve the other participant's current name/emoji dynamically
    // instead of trusting those static fields.
    var displayName = chat.name;
    var displayEmoji = chat.emoji;
    User? other;
    if (!chat.isGroup) {
      final otherUid = chat.members.firstWhere(
        (m) => m != currentUid,
        orElse: () => '',
      );
      if (otherUid.isNotEmpty) {
        other = ref.watch(currentUserProvider(otherUid)).value;
        if (other != null) {
          displayName = other.name;
          displayEmoji = other.emoji;
        }
      }
    }
    final hasActiveStatus = !chat.isGroup && other?.hasActiveStatus == true;
    final viewerUser = hasActiveStatus
        ? ref.watch(currentUserProvider(currentUid)).value
        : null;
    final hasUnviewed =
        hasActiveStatus && (viewerUser?.hasUnviewedStatusFrom(other!) ?? false);
    const avatarBaseSize = 48.0;
    final avatarBoxSize = avatarBaseSize * 1.2;
    void openStatusViewer() => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserStatusViewerScreen(
              ownerUid: other!.id,
              currentUid: currentUid,
              initialUser: other,
            ),
          ),
        );

    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: avatarBoxSize,
                  height: avatarBoxSize,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (hasActiveStatus)
                        GestureDetector(
                          onTap: openStatusViewer,
                          onLongPress: () => showAvatarLongPressMenu(
                            context,
                            photoURL: other?.photoURL,
                            onViewStatus: openStatusViewer,
                          ),
                          child: AvatarRing(
                            photoURL: other?.photoURL,
                            fallbackEmoji: displayEmoji,
                            hasUnviewed: hasUnviewed,
                            size: avatarBoxSize,
                          ),
                        )
                      else
                        GestureDetector(
                          onTap: other?.photoURL != null
                              ? () => showFullImage(context, other!.photoURL!)
                              : null,
                          child: Container(
                            width: avatarBoxSize,
                            height: avatarBoxSize,
                            decoration: BoxDecoration(
                              color: kBg3,
                              shape: BoxShape.circle,
                              border: Border.all(color: kBorder, width: 1.5),
                              image: other?.photoURL != null
                                  ? DecorationImage(
                                      image: NetworkImage(other!.photoURL!),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            alignment: Alignment.center,
                            child: other?.photoURL == null
                                ? Text(
                                    displayEmoji,
                                    style: const TextStyle(fontSize: 24),
                                  )
                                : null,
                          ),
                        ),
                      if (!chat.isGroup)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: other?.isActuallyOnline == true
                                  ? kGreen
                                  : kMuted,
                              shape: BoxShape.circle,
                              border: Border.all(color: kBg2, width: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              displayName,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.nunito(
                                fontWeight: FontWeight.w700,
                                fontSize: 18,
                                color: kText,
                              ),
                            ),
                          ),
                          Text(
                            _formatTime(chat.lastMessageTime),
                            style: const TextStyle(fontSize: 13.2, color: kMuted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              chat.lastMessageDeletedFor.contains(currentUid)
                                  ? '🚫 Bu mesajı sildiniz'
                                  : chat.lastMessage,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15.6,
                                color: kMuted,
                                fontStyle:
                                    chat.lastMessageDeletedFor.contains(
                                      currentUid,
                                    )
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                              ),
                            ),
                          ),
                          if (chat.unreadCount > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              width: 20,
                              height: 20,
                              decoration: const BoxDecoration(
                                color: kRed,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                chat.unreadCount.toString(),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: kBorder.withAlpha(60), indent: 80),
        ],
      ),
    );
  }
}
