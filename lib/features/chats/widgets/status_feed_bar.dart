import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/avatar_ring.dart';

// StatusFeedBar's own content height, computed rather than guessed — a
// hardcoded SizedBox(height: 90) previously overflowed by 10px on a real
// device (RenderFlex "OVERFLOWED BY 10.0 PIXELS" under the "Siz" label).
//
// AvatarRing's actual rendered footprint is exactly its `size` param
// (_kAvatarSize below, matching the unmodified default both
// _MyStatusItem/_OtherStatusItem use) — Container's own explicit
// width/height forces a TIGHT outer constraint, so the ring's 2.5px
// padding and 2.5px border are painted *inside* that same fixed box, not
// added on top of it.
const double _kAvatarSize = 64;
const double _kLabelSpacing = 4; // the SizedBox between ring and label
const double _kLabelLineHeight = 16; // one line at fontSize: 11
const double _kListVerticalPadding = 8 + 8; // ListView's own top+bottom
const double _kBarSafetyMargin = 8;
const double _kBarHeight =
    _kAvatarSize +
    _kLabelSpacing +
    _kLabelLineHeight +
    _kListVerticalPadding +
    _kBarSafetyMargin; // 64+4+16+16+8 = 108

// WhatsApp-style status row, above the chat list (see ChatsScreen). No
// navigation logic of its own — onCreateStatus/onOpenStatus are supplied
// by the caller, which is what actually knows about CreateStatusScreen/
// StatusViewerScreen (not built yet).
class StatusFeedBar extends ConsumerWidget {
  final String currentUid;
  final VoidCallback onCreateStatus;
  final Future<void> Function(String ownerUid) onOpenStatus;

  const StatusFeedBar({
    super.key,
    required this.currentUid,
    required this.onCreateStatus,
    required this.onOpenStatus,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feedAsync = ref.watch(statusFeedProvider(currentUid));

    // Secondary UI element — a loading spinner or visible error text here
    // would be more distracting than just letting the bar populate a
    // moment later (loading) or silently staying at "my status only"
    // (error). Still logged to Crashlytics on a real state transition
    // (ref.listen, not on every rebuild) so a genuine backend problem
    // isn't invisible — same recordError(e, st, reason: ...) call shape
    // already used throughout this codebase (e.g.
    // video_message_widgets.dart's _deactivateAudioSession catch).
    ref.listen<AsyncValue<List<StatusGroup>>>(statusFeedProvider(currentUid), (
      previous,
      next,
    ) {
      next.whenOrNull(
        error: (err, stack) => FirebaseCrashlytics.instance.recordError(
          err,
          stack,
          reason: 'StatusFeedBar: statusFeedProvider error',
        ),
      );
    });

    final groups = feedAsync.value ?? const <StatusGroup>[];
    // watchStatusFeed always sorts the current user's own group first when
    // one exists (see that method's own doc comment) — relying on that
    // ordering guarantee here rather than re-searching the list.
    final hasOwnGroup =
        groups.isNotEmpty && groups.first.ownerUid == currentUid;
    final ownGroup = hasOwnGroup ? groups.first : null;
    final otherGroups = hasOwnGroup ? groups.skip(1).toList() : groups;

    return SizedBox(
      height: _kBarHeight,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _MyStatusItem(
            currentUid: currentUid,
            ownGroup: ownGroup,
            onCreateStatus: onCreateStatus,
            onOpenStatus: onOpenStatus,
          ),
          for (final group in otherGroups)
            _OtherStatusItem(
              currentUid: currentUid,
              group: group,
              onOpenStatus: onOpenStatus,
            ),
        ],
      ),
    );
  }
}

class _MyStatusItem extends ConsumerWidget {
  final String currentUid;
  final StatusGroup? ownGroup;
  final VoidCallback onCreateStatus;
  final Future<void> Function(String ownerUid) onOpenStatus;

  const _MyStatusItem({
    required this.currentUid,
    required this.ownGroup,
    required this.onCreateStatus,
    required this.onOpenStatus,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ownUser = ref.watch(currentUserProvider(currentUid)).value;

    return GestureDetector(
      onTap: ownGroup != null ? () => onOpenStatus(currentUid) : onCreateStatus,
      child: SizedBox(
        width: 68,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AvatarRing(
                  photoURL: ownUser?.photoURL,
                  fallbackEmoji: ownUser?.emoji,
                  // Never gold for your own status — "unviewed" doesn't
                  // apply to yourself.
                  hasUnviewed: false,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  // Always visible, independent of whether a status is
                  // already active — matches WhatsApp's own behavior
                  // (confirmed via search) of keeping the add-status
                  // control on screen at all times, not just before the
                  // first post; tapping it lets you post another status
                  // alongside an existing one rather than only being able
                  // to view what's already there. Scaled from
                  // edit_profile_screen.dart's avatar-edit badge (28px
                  // badge / 14px icon on a 96px avatar, ~0.29/~0.15 ratio)
                  // down to AvatarRing's default 64px size — same
                  // kGold/dark-icon treatment, "+" instead of a camera.
                  // Its own GestureDetector so tapping the badge
                  // specifically always creates, independent of the outer
                  // ring's own tap target (open-existing vs create-first).
                  child: GestureDetector(
                    onTap: onCreateStatus,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: const BoxDecoration(
                        color: kGold,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.add,
                        size: 12,
                        color: Color(0xFF1A0E00),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Siz', // established "You" convention in this app — see
              // group_info_screen.dart/chat_screen.dart/
              // agreements_screen.dart, not "Sən".
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(fontSize: 11, color: kMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _OtherStatusItem extends ConsumerStatefulWidget {
  final String currentUid;
  final StatusGroup group;
  final Future<void> Function(String ownerUid) onOpenStatus;

  const _OtherStatusItem({
    required this.currentUid,
    required this.group,
    required this.onOpenStatus,
  });

  @override
  ConsumerState<_OtherStatusItem> createState() => _OtherStatusItemState();
}

class _OtherStatusItemState extends ConsumerState<_OtherStatusItem> {
  // Computed once (initState), not inline in build() — ChatsScreen's
  // search field calls setState() on every keystroke, which rebuilds this
  // whole subtree; an inline Future.wait(...) in build() would refire
  // every hasViewedStatus() read for every visible status on every
  // keystroke, not just when this group's statuses actually change.
  late Future<List<bool>> _viewedFuture;

  @override
  void initState() {
    super.initState();
    _viewedFuture = _computeViewedFuture(widget.group);
  }

  @override
  void didUpdateWidget(_OtherStatusItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only recompute if the actual set of statuses changed (e.g. this
    // owner posted a new one while the bar was on screen) — not on every
    // didUpdateWidget call, which would reintroduce the same
    // once-per-keystroke problem this fix exists to avoid.
    final oldIds = oldWidget.group.statuses.map((s) => s.id).toList();
    final newIds = widget.group.statuses.map((s) => s.id).toList();
    if (!listEquals(oldIds, newIds)) {
      _viewedFuture = _computeViewedFuture(widget.group);
    }
  }

  // One hasViewedStatus() read per status currently in this group, batched
  // via Future.wait — bounded by how many statuses one owner has active at
  // once (same reasoning as hasViewedStatus's own SCALE NOTE-style comment
  // in firestore_service.dart). ref.read, not ref.watch: this only needs a
  // one-time FirestoreService reference to kick off the reads, not a
  // rebuild subscription.
  Future<List<bool>> _computeViewedFuture(StatusGroup group) {
    final firestoreService = ref.read(firestoreServiceProvider);
    return Future.wait(
      group.statuses.map(
        (s) => firestoreService.hasViewedStatus(
          ownerUid: group.ownerUid,
          statusId: s.id,
          viewerUid: widget.currentUid,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider(widget.group.ownerUid)).value;

    return GestureDetector(
      onTap: () async {
        // onOpenStatus now returns the Navigator.push Future — awaiting it
        // lets us recompute _viewedFuture the moment the viewer is popped,
        // so the ring flips from gold to gray immediately on return instead
        // of staying stale until this group's status *set* next changes
        // (didUpdateWidget's own check, which doesn't fire just from
        // viewing).
        await widget.onOpenStatus(widget.group.ownerUid);
        if (mounted) {
          setState(() {
            _viewedFuture = _computeViewedFuture(widget.group);
          });
        }
      },
      child: SizedBox(
        width: 68,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FutureBuilder<List<bool>>(
              future: _viewedFuture,
              // Defaults to NOT gold while resolving (viewedFlags == null
              // below), so the ring doesn't flash gold-then-gray on every
              // rebuild.
              builder: (context, snapshot) {
                final viewedFlags = snapshot.data;
                final hasUnviewed =
                    viewedFlags != null &&
                    viewedFlags.any((viewed) => !viewed);
                return AvatarRing(
                  photoURL: user?.photoURL,
                  fallbackEmoji: user?.emoji,
                  hasUnviewed: hasUnviewed,
                );
              },
            ),
            const SizedBox(height: 4),
            Text(
              user?.name ?? '',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(fontSize: 11, color: kMuted),
            ),
          ],
        ),
      ),
    );
  }
}
