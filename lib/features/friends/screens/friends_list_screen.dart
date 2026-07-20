import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import '../../status/screens/status_viewer_screen.dart';
import '../../user/screens/user_profile_screen.dart';

// Confirmed-friends roster, reached from ProfileSettingsScreen's "Dostlar"
// ListTile. friendUidsProvider only ever gives back bare uids (the
// users/{uid}/friends subcollection's doc ids) — each row resolves its own
// user data via currentUserProvider, matching chats_screen.dart's
// _ChatListItem (a live stream, not the one-time userByIdProvider
// friend_requests_screen.dart uses) since ListView.separated only
// subscribes visible rows either way, and a friends roster benefits from
// live presence the same way the chat list does.
class FriendsListScreen extends ConsumerWidget {
  const FriendsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final friendUidsAsync = ref.watch(friendUidsProvider(currentUid));

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
          'Dostlar',
          style: GoogleFonts.nunito(fontSize: 18, color: kText),
        ),
      ),
      body: friendUidsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: kGold)),
        error: (_, _) => const Center(
          child: Text('Xəta baş verdi', style: TextStyle(color: kMuted)),
        ),
        data: (friendUids) {
          if (friendUids.isEmpty) {
            return const Center(
              child: Text(
                'Hələ dostunuz yoxdur',
                style: TextStyle(color: kMuted),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: friendUids.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) => _FriendTile(
              friendUid: friendUids[index],
            ),
          );
        },
      ),
    );
  }
}

class _FriendTile extends ConsumerWidget {
  final String friendUid;

  const _FriendTile({required this.friendUid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider(friendUid)).value;
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final hasActiveStatus = user?.hasActiveStatus == true;
    final viewerUser = hasActiveStatus
        ? ref.watch(currentUserProvider(currentUid)).value
        : null;
    final hasUnviewed =
        hasActiveStatus && (viewerUser?.hasUnviewedStatusFrom(user!) ?? false);
    const avatarBaseSize = 48.0;
    final avatarBoxSize = avatarBaseSize * 1.2;
    void openStatusViewer() => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserStatusViewerScreen(
              ownerUid: user!.id,
              currentUid: currentUid,
              initialUser: user,
            ),
          ),
        );

    return GestureDetector(
      onTap: user == null
          ? null
          : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => UserProfileScreen(user: user),
                ),
              ),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder),
        ),
        child: Row(
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
                        photoURL: user?.photoURL,
                        onViewStatus: openStatusViewer,
                      ),
                      child: AvatarRing(
                        photoURL: user?.photoURL,
                        fallbackEmoji: user?.emoji ?? '🎵',
                        hasUnviewed: hasUnviewed,
                        size: avatarBoxSize,
                      ),
                    )
                  else
                    GestureDetector(
                      onTap: user?.photoURL != null
                          ? () => showFullImage(context, user!.photoURL!)
                          : null,
                      child: Container(
                        width: avatarBoxSize,
                        height: avatarBoxSize,
                        decoration: BoxDecoration(
                          color: kBg3,
                          shape: BoxShape.circle,
                          border: Border.all(color: kBorder, width: 1.5),
                          image: user?.photoURL != null
                              ? DecorationImage(
                                  image: NetworkImage(user!.photoURL!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: user?.photoURL == null
                            ? Text(
                                user?.emoji ?? '🎵',
                                style: const TextStyle(fontSize: 24),
                              )
                            : null,
                      ),
                    ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: user?.isActuallyOnline == true ? kGreen : kMuted,
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
              child: Text(
                user?.name ?? '...',
                style: const TextStyle(color: kText, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
