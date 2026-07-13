import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../shared/widgets/status_video_player.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import '../widgets/status_progress_bar.dart';

// Fixed display duration for text/image statuses — video statuses instead
// use their own real duration, reported by StatusVideoPlayer's
// onDurationKnown once known (see _StatusGroupPageState._videoDuration).
// Named constant instead of a magic number scattered across this file.
const Duration _kTextImageSegmentDuration = Duration(seconds: 5);

// WhatsApp-style full-screen status viewer. One outer PageView page per
// author (StatusGroup) the current user can see, swipeable
// left/right between authors; each page owns its own tap-driven
// navigation between that author's individual statuses (_StatusGroupPage
// below) — see that class for the tap-vs-swipe distinction.
class StatusViewerScreen extends ConsumerStatefulWidget {
  final String initialOwnerUid;
  final String currentUid;

  const StatusViewerScreen({
    super.key,
    required this.initialOwnerUid,
    required this.currentUid,
  });

  @override
  ConsumerState<StatusViewerScreen> createState() =>
      _StatusViewerScreenState();
}

class _StatusViewerScreenState extends ConsumerState<StatusViewerScreen> {
  PageController? _pageController;
  bool _poppedForMissingGroup = false;

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(statusFeedProvider(widget.currentUid));
    final groups = feedAsync.value;

    // Still loading (or errored) — a black screen rather than a spinner,
    // same "don't distract for a secondary loading state" call as
    // StatusFeedBar makes for its own feed read.
    if (groups == null) {
      return const Scaffold(backgroundColor: Colors.black);
    }

    final initialIndex = groups.indexWhere(
      (g) => g.ownerUid == widget.initialOwnerUid,
    );
    if (initialIndex == -1) {
      // Edge case: the status expired (or its last item did) between the
      // feed-bar tap and this screen's first frame. Pop back to
      // ChatsScreen instead of showing an empty/broken viewer.
      if (!_poppedForMissingGroup) {
        _poppedForMissingGroup = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
      return const Scaffold(backgroundColor: Colors.black);
    }

    // Only set once, on first successful build — re-deriving this on
    // every snapshot would fight the PageController's own current page
    // whenever the feed updates for an unrelated reason (e.g. some other
    // author posting a new status elsewhere in the list). Known
    // simplification: if the currently-open author's position in `groups`
    // itself shifts later (a group reordering to a different index, or
    // disappearing entirely because all of it expired while this screen
    // is open), the PageView keeps showing whatever author is now at that
    // same index rather than following the original author — not handled
    // here, no report of this happening in practice yet.
    _pageController ??= PageController(initialPage: initialIndex);

    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pageController,
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          return _StatusGroupPage(
            key: ValueKey(group.ownerUid),
            group: group,
            currentUid: widget.currentUid,
            isOwnGroup: group.ownerUid == widget.currentUid,
            onAdvanceToNextAuthor: () {
              if (index < groups.length - 1) {
                _pageController!.nextPage(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                );
              } else {
                Navigator.of(context).pop();
              }
            },
          );
        },
      ),
    );
  }
}

// One author's statuses — owns which individual status is currently shown
// plus every gesture on the media area: tap-left-third/right-two-thirds to
// step between THIS author's own statuses, long-press to pause, drag-down
// to dismiss the whole viewer. Deliberately does not react to horizontal
// drags at all — that's the outer PageView's own default behavior for
// moving between authors, and left doing exactly that rather than
// duplicated or intercepted here.
class _StatusGroupPage extends ConsumerStatefulWidget {
  final StatusGroup group;
  final String currentUid;
  final bool isOwnGroup;
  final VoidCallback onAdvanceToNextAuthor;

  const _StatusGroupPage({
    super.key,
    required this.group,
    required this.currentUid,
    required this.isOwnGroup,
    required this.onAdvanceToNextAuthor,
  });

  @override
  ConsumerState<_StatusGroupPage> createState() => _StatusGroupPageState();
}

class _StatusGroupPageState extends ConsumerState<_StatusGroupPage>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  bool _paused = false;
  Duration? _videoDuration;
  String? _markedViewedStatusId;

  // Drag-to-dismiss state, plus the snap-back controller for when a drag
  // doesn't clear the dismiss threshold — same drag-then-animate-back
  // idiom as chat_screen.dart's _SwipeableMessageBubble._snapController.
  double _dragY = 0;
  late final AnimationController _snapController;
  Animation<double>? _snapAnimation;

  Status get _currentStatus => widget.group.statuses[_currentIndex];
  bool get _effectivePaused => _paused || _dragY > 0;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _maybeMarkViewed();
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  // Never called for the owner's own group — you don't "view" your own
  // status. Guarded by _markedViewedStatusId so re-visiting the same
  // status (e.g. tapping back then forward again) doesn't re-write the
  // same viewer doc over and over.
  void _maybeMarkViewed() {
    if (widget.isOwnGroup) return;
    final status = _currentStatus;
    if (_markedViewedStatusId == status.id) return;
    _markedViewedStatusId = status.id;
    unawaited(_markViewed(status.id));
  }

  // A failed view-marking write must not interrupt viewing — same
  // try/catch + FirebaseCrashlytics.instance.recordError shape as
  // status_video_player.dart's _deactivateAudioSession, silently logged
  // for diagnosis rather than surfaced as UI or rethrown.
  Future<void> _markViewed(String statusId) async {
    try {
      await ref
          .read(firestoreServiceProvider)
          .markStatusViewed(
            ownerUid: widget.group.ownerUid,
            statusId: statusId,
            viewerUid: widget.currentUid,
          );
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'StatusViewerScreen: markStatusViewed failed',
      );
    }
  }

  void _goToIndex(int index) {
    setState(() {
      _currentIndex = index;
      _videoDuration = null;
    });
    _maybeMarkViewed();
  }

  void _advance() {
    if (_currentIndex < widget.group.statuses.length - 1) {
      _goToIndex(_currentIndex + 1);
    } else {
      widget.onAdvanceToNextAuthor();
    }
  }

  void _goBack() {
    // At index 0 this is a deliberate no-op — only an actual horizontal
    // swipe moves to the previous author, never a left-third tap. The
    // outer PageView already owns that gesture; nothing to wire here.
    if (_currentIndex > 0) {
      _goToIndex(_currentIndex - 1);
    }
  }

  void _handleTapUp(TapUpDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    if (details.localPosition.dx < width / 3) {
      _goBack();
    } else {
      _advance();
    }
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragY = (_dragY + details.delta.dy).clamp(0.0, double.infinity);
    });
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    const distanceThreshold = 120.0;
    const velocityThreshold = 700.0;
    final shouldDismiss =
        _dragY > distanceThreshold ||
        details.velocity.pixelsPerSecond.dy > velocityThreshold;
    if (shouldDismiss) {
      Navigator.of(context).pop();
      return;
    }
    _snapBack();
  }

  void _snapBack() {
    _snapAnimation = Tween<double>(begin: _dragY, end: 0.0).animate(
      CurvedAnimation(parent: _snapController, curve: Curves.easeOut),
    )..addListener(() => setState(() => _dragY = _snapAnimation!.value));
    _snapController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final status = _currentStatus;
    final user = ref.watch(userByIdProvider(widget.group.ownerUid)).value;
    final dragProgress = (_dragY / 400).clamp(0.0, 1.0);

    return GestureDetector(
      onTapUp: _handleTapUp,
      onLongPressStart: (_) => setState(() => _paused = true),
      onLongPressEnd: (_) => setState(() => _paused = false),
      onVerticalDragUpdate: _handleVerticalDragUpdate,
      onVerticalDragEnd: _handleVerticalDragEnd,
      child: Transform.translate(
        offset: Offset(0, _dragY),
        child: Opacity(
          opacity: 1 - dragProgress * 0.6,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: kBg),
              _MediaContent(
                key: ValueKey(status.id),
                status: status,
                paused: _effectivePaused,
                onVideoEnded: status.type == 'video' ? _advance : null,
                onDurationKnown: (d) => setState(() => _videoDuration = d),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      StatusProgressBar(
                        segmentCount: widget.group.statuses.length,
                        currentIndex: _currentIndex,
                        segmentDuration: status.type == 'video'
                            ? (_videoDuration ?? _kTextImageSegmentDuration)
                            : _kTextImageSegmentDuration,
                        paused: _effectivePaused,
                        // Video segments advance via StatusVideoPlayer's
                        // onVideoEnded above, not this timer — the two
                        // fire within milliseconds of each other (the bar
                        // is driven by the same duration the video
                        // reports), so wiring both to _advance would
                        // double-advance and skip a status. Text/image
                        // segments have no video widget at all, so the
                        // timer is the only signal for them.
                        onSegmentComplete: status.type == 'video'
                            ? () {}
                            : _advance,
                      ),
                      const SizedBox(height: 8),
                      _HeaderRow(
                        user: user,
                        status: status,
                        onClose: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.isOwnGroup)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Center(
                    child: GestureDetector(
                      onTap: () {
                        // TODO: navigate to ViewersListScreen, not built yet
                      },
                      child: const Text(
                        'Baxanlar',
                        style: TextStyle(color: kMuted, fontSize: 13),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaContent extends StatelessWidget {
  final Status status;
  final bool paused;
  final VoidCallback? onVideoEnded;
  final ValueChanged<Duration> onDurationKnown;

  const _MediaContent({
    super.key,
    required this.status,
    required this.paused,
    required this.onVideoEnded,
    required this.onDurationKnown,
  });

  @override
  Widget build(BuildContext context) {
    switch (status.type) {
      case 'image':
        return ZoomableImage(imageURL: status.mediaUrl!);
      case 'video':
        return StatusVideoPlayer(
          videoURL: status.mediaUrl,
          paused: paused,
          onVideoEnded: onVideoEnded,
          onDurationKnown: onDurationKnown,
        );
      case 'text':
      default:
        // Status has no stored background-color field (confirmed against
        // the model) — a fixed dark background is a known simplification
        // here, not this screen's to invent a color-picker for; that's a
        // CreateStatusScreen concern.
        return Container(
          color: kBg2,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            status.text ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: kText,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
    }
  }
}

class _HeaderRow extends StatelessWidget {
  final User? user;
  final Status status;
  final VoidCallback onClose;

  const _HeaderRow({
    required this.user,
    required this.status,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AvatarRing(
          photoURL: user?.photoURL,
          fallbackEmoji: user?.emoji,
          hasUnviewed: false,
          size: 36,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                user?.name ?? '',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(
                  color: kText,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                // Statuses always expire within 24h of createdAt, so a
                // bare HH:mm (never a date) reads the same as
                // chats_screen.dart's own _formatTime does for anything
                // from today.
                DateFormat('HH:mm').format(status.createdAt),
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white, size: 26),
          onPressed: onClose,
        ),
      ],
    );
  }
}
