import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
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
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
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
          style: GoogleFonts.playfairDisplay(fontSize: 20, color: kText),
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
              onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
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
            child: chatsAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator(color: kGold)),
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
                            style: GoogleFonts.playfairDisplay(
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

                // Known follow-up: search still matches against the chat
                // doc's static `name` field, which for 1:1 chats is written
                // from the initiator's perspective and can be wrong for the
                // recipient (see _ChatListItem, which resolves the correct
                // name dynamically for display). Not fixed here — lower
                // priority, separate from the display bug this fix targets.
                final filtered = chats
                    .where((c) => c.name.toLowerCase().contains(_searchQuery))
                    .toList();

                if (filtered.isEmpty) {
                  return const Center(
                    child: Text(
                      'Axtarış nəticəsi tapılmadı',
                      style: TextStyle(color: kMuted, fontSize: 14),
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final chat = filtered[index];
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
    if (!chat.isGroup) {
      final otherUid = chat.members.firstWhere(
        (m) => m != currentUid,
        orElse: () => '',
      );
      if (otherUid.isNotEmpty) {
        final other = ref.watch(userByIdProvider(otherUid)).value;
        if (other != null) {
          displayName = other.name;
          displayEmoji = other.emoji;
        }
      }
    }

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
                  width: 48,
                  height: 48,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: kBg3,
                          shape: BoxShape.circle,
                          border: Border.all(color: kBorder, width: 1.5),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          displayEmoji,
                          style: const TextStyle(fontSize: 24),
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
                              color: kGreen,
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
                                fontSize: 15,
                                color: kText,
                              ),
                            ),
                          ),
                          Text(
                            _formatTime(chat.lastMessageTime),
                            style: const TextStyle(fontSize: 11, color: kMuted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              chat.lastMessage,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: kMuted,
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
