import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';

// Owner-only "Baxanlar" list for one specific status segment — reached from
// StatusViewerScreen's own bottom label (isOwnGroup branch only, see that
// screen), shown as a modal bottom sheet over the (paused) status rather
// than a full-screen route, so the status stays visible behind it — see
// StatusViewerScreen._openStatusViewers. Mirrors _AddParticipantsSheet's
// (group_info_screen.dart) SafeArea + fixed-fraction-height + drag-handle
// shape for the same "sheet with a scrollable list inside" case, and
// _ParticipantTile's (group_info_screen.dart) plain non-ring avatar
// convention, since a viewer here has no "active status" semantics of
// their own to show a ring for.
class StatusViewersScreen extends ConsumerWidget {
  final String ownerUid;
  final String statusId;

  const StatusViewersScreen({
    super.key,
    required this.ownerUid,
    required this.statusId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewersAsync = ref.watch(
      statusViewersProvider((ownerUid: ownerUid, statusId: statusId)),
    );

    return Container(
      decoration: const BoxDecoration(
        color: kBg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: kMuted,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Baxanlar',
                        style: GoogleFonts.nunito(
                          fontSize: 18,
                          color: kText,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: kGold),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: viewersAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator(color: kGold)),
                  error: (_, _) => const Center(
                    child: Text('Xəta baş verdi', style: TextStyle(color: kMuted)),
                  ),
                  data: (viewers) {
                    if (viewers.isEmpty) {
                      return const Center(
                        child: Text(
                          'Hələ heç kim baxmayıb',
                          style: TextStyle(color: kMuted),
                        ),
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: viewers.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _ViewerTile(viewer: viewers[index]),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewerTile extends ConsumerWidget {
  final StatusViewer viewer;

  const _ViewerTile({required this.viewer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userByIdProvider(viewer.uid)).value;
    final name = user?.name ?? 'İstifadəçi';
    final emoji = user?.emoji ?? '👤';
    const avatarSize = 44.0;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: GestureDetector(
        onTap: user?.photoURL != null
            ? () => showFullImage(context, user!.photoURL!)
            : null,
        child: Container(
          width: avatarSize,
          height: avatarSize,
          decoration: const BoxDecoration(color: kBg3, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(emoji, style: const TextStyle(fontSize: 18)),
        ),
      ),
      title: Text(
        name,
        style: GoogleFonts.nunito(fontSize: 14, color: kText),
      ),
      // 'd MMM, HH:mm' — same DateFormat already used by
      // MessageInfoScreen._formatInfoTime for this app's other per-person
      // timestamp list, not a new format invented for this screen.
      trailing: Text(
        DateFormat('d MMM, HH:mm').format(viewer.viewedAt),
        style: const TextStyle(color: kMuted, fontSize: 12),
      ),
    );
  }
}
