import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';

class StarredMessagesScreen extends ConsumerWidget {
  // When set, only this chat's starred messages are shown (the per-chat
  // "Seçilmişlər" view opened from About Contact) instead of every starred
  // message across all chats (the global Profile → Settings view).
  final String? chatId;
  final String? title;

  const StarredMessagesScreen({super.key, this.chatId, this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final starredAsync = ref.watch(starredMessagesProvider(currentUid));

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        title: Text(
          title ?? 'Seçilmiş mesajlar',
          style: GoogleFonts.playfairDisplay(fontSize: 20, color: kText),
        ),
      ),
      body: starredAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: kGold)),
        error: (err, stack) => Center(
          child: Text(
            err.toString(),
            style: const TextStyle(color: kRed, fontSize: 12),
          ),
        ),
        data: (allStarred) {
          final starred = chatId == null
              ? allStarred
              : allStarred.where((m) => m.chatId == chatId).toList();
          if (starred.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('⭐', style: TextStyle(fontSize: 52)),
                    const SizedBox(height: 12),
                    Text(
                      'Seçilmiş mesaj yoxdur',
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: kText,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Mesaj üzərində uzun basıb "Seçilmişlər" seçin',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: kMuted),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: starred.length,
            itemBuilder: (context, index) {
              final item = starred[index];
              return _StarredListItem(
                item: item,
                onTap: () => context.push(
                  '/chat/${item.chatId}',
                  extra: item.id,
                ),
                onUnstar: () => ref
                    .read(firestoreServiceProvider)
                    .unstarMessage(uid: currentUid, messageId: item.id),
              );
            },
          );
        },
      ),
    );
  }
}

class _StarredListItem extends StatelessWidget {
  final StarredMessage item;
  final VoidCallback onTap;
  final VoidCallback onUnstar;

  const _StarredListItem({
    required this.item,
    required this.onTap,
    required this.onUnstar,
  });

  String _preview() {
    switch (item.type) {
      case 'image':
        return '🖼 Şəkil';
      case 'audio':
        return '🎤 Səs mesajı';
      case 'video':
        return '🎥 Video';
      case 'file':
        return '📄 ${item.fileName ?? 'Fayl'}';
      default:
        return item.text;
    }
  }

  String _formatDate() {
    final ts = item.starredAt?.toDate();
    if (ts == null) return '';
    return DateFormat('dd.MM.yyyy HH:mm').format(ts);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.chatName,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.nunito(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: kGold,
                              ),
                            ),
                          ),
                          Text(
                            _formatDate(),
                            style: const TextStyle(
                              fontSize: 11,
                              color: kMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.senderName,
                        style: const TextStyle(fontSize: 12, color: kMuted),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _preview(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, color: kText),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.star, color: kGold, size: 20),
                  onPressed: onUnstar,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: kBorder.withAlpha(60), indent: 16),
        ],
      ),
    );
  }
}
