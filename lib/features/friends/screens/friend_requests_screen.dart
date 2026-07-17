import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../user/screens/user_profile_screen.dart';

// Incoming/outgoing friendRequests inbox, reached from ProfileScreen's
// settings tab (see the "Dost sorğuları" ListTile there). Each row resolves
// its counterpart's name/avatar/presence live via currentUserProvider —
// this screen never duplicates user data of its own, it only reads
// FriendRequest documents (uids only) plus that shared lookup.
class FriendRequestsScreen extends ConsumerStatefulWidget {
  const FriendRequestsScreen({super.key});

  @override
  ConsumerState<FriendRequestsScreen> createState() =>
      _FriendRequestsScreenState();
}

class _FriendRequestsScreenState extends ConsumerState<FriendRequestsScreen> {
  @override
  void initState() {
    super.initState();
    // Fire-and-forget, the moment this screen opens — marks requests as
    // viewed regardless of whether the user goes on to accept/decline any
    // of them (see hasUnreadFriendRequestsProvider's own doc comment).
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && uid.isNotEmpty) {
      ref.read(firestoreServiceProvider).markFriendRequestsViewed(uid);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final incomingAsync = ref.watch(incomingFriendRequestsProvider(currentUid));
    final outgoingAsync = ref.watch(outgoingFriendRequestsProvider(currentUid));

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: kBg,
        appBar: AppBar(
          backgroundColor: kBg2,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: kGold),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            'Dost sorğuları',
            style: GoogleFonts.playfairDisplay(fontSize: 18, color: kText),
          ),
          bottom: TabBar(
            indicatorColor: kGold,
            labelColor: kGold,
            unselectedLabelColor: kMuted,
            tabs: [
              Tab(text: 'Gələn (${incomingAsync.asData?.value.length ?? 0})'),
              const Tab(text: 'Göndərilən'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _RequestList(
              async: incomingAsync,
              currentUid: currentUid,
              emptyText: 'Hələ heç kim sizə dostluq təklifi göndərməyib',
              incoming: true,
            ),
            _RequestList(
              async: outgoingAsync,
              currentUid: currentUid,
              emptyText: 'Göndərdiyiniz təklif yoxdur',
              incoming: false,
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestList extends ConsumerWidget {
  final AsyncValue<List<FriendRequest>> async;
  final String currentUid;
  final String emptyText;
  final bool incoming;

  const _RequestList({
    required this.async,
    required this.currentUid,
    required this.emptyText,
    required this.incoming,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator(color: kGold)),
      error: (_, _) => const Center(
        child: Text('Xəta baş verdi', style: TextStyle(color: kMuted)),
      ),
      data: (requests) {
        if (requests.isEmpty) {
          return Center(
            child: Text(emptyText, style: const TextStyle(color: kMuted)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: requests.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final req = requests[index];
            final otherUid = req.otherUid(currentUid);
            return _RequestTile(
              otherUid: otherUid,
              requestId: req.id,
              incoming: incoming,
            );
          },
        );
      },
    );
  }
}

class _RequestTile extends ConsumerWidget {
  final String otherUid;
  final String requestId;
  final bool incoming;

  const _RequestTile({
    required this.otherUid,
    required this.requestId,
    required this.incoming,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(currentUserProvider(otherUid));
    final service = ref.read(firestoreServiceProvider);
    final user = userAsync.value;

    return GestureDetector(
      onTap: incoming && user != null
          ? () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => UserProfileScreen(user: user)),
              )
          : null,
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
              width: 44,
              height: 44,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: kBg3,
                    child: Text(user?.emoji ?? '🎵', style: const TextStyle(fontSize: 20)),
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
            const SizedBox(width: 8),
            if (incoming) ...[
              IconButton(
                icon: const Icon(Icons.check_circle, color: kGold),
                tooltip: 'Qəbul et',
                onPressed: () => service.acceptFriendRequest(requestId),
              ),
              IconButton(
                icon: const Icon(Icons.cancel, color: kMuted),
                tooltip: 'İmtina et',
                onPressed: () => service.removeFriendRequestOrFriendship(requestId),
              ),
            ] else
              TextButton(
                onPressed: () => service.removeFriendRequestOrFriendship(requestId),
                child: const Text('Ləğv et', style: TextStyle(color: kMuted)),
              ),
          ],
        ),
      ),
    );
  }
}
