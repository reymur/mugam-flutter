import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../shared/widgets/status_video_player.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import '../widgets/status_progress_bar.dart';
import 'status_viewers_screen.dart';

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
  // Which of group.statuses to open on first frame, by id — e.g. a status-
  // reply's quote-tap wants the exact segment that was replied to, not
  // always the first one. Null (every existing call site) keeps the
  // original always-start-at-0 behavior; a non-null id that no longer
  // matches any status in the group (expired since the reply was sent)
  // also falls back to 0 rather than throwing, in _StatusGroupPageState's
  // own initState below.
  final String? initialStatusId;

  const _StatusGroupPage({
    super.key,
    required this.group,
    required this.currentUid,
    required this.isOwnGroup,
    required this.onAdvanceToNextAuthor,
    this.initialStatusId,
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
  // Reply-to-status panel state (viewer side only — see isOwnGroup guard in
  // build() below; the owner sees "Baxanlar" in this same screen position
  // instead). _replyFocusNode's own listener (registered in initState)
  // reuses the existing _paused flag for "pause while typing", same
  // non-ref-counted simplification _openStatusViewers already makes for
  // "pause while the viewers list is open" — this app has no case where
  // two pause sources are ever actually active at once in practice, so a
  // plain bool has always been enough.
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocusNode = FocusNode();
  bool _sendingReply = false;

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
    final targetId = widget.initialStatusId;
    if (targetId != null) {
      final foundIndex = widget.group.statuses.indexWhere(
        (s) => s.id == targetId,
      );
      // -1 (not found — e.g. the specific replied-to status expired since)
      // falls back to the existing default of 0 rather than an invalid
      // index; _currentIndex is already 0 from its own field initializer
      // above, so only overwrite it on an actual match.
      if (foundIndex != -1) {
        _currentIndex = foundIndex;
      }
    }
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    // Rebuilds just to show/hide the send button as the field goes
    // empty/non-empty — cheap (this whole screen already rebuilds on every
    // progress-bar tick via setState in StatusProgressBar's own timer, see
    // that widget), so no debounce/throttle needed for a plain text watch.
    _replyController.addListener(() {
      if (mounted) setState(() {});
    });
    _replyFocusNode.addListener(() {
      if (mounted) setState(() => _paused = _replyFocusNode.hasFocus);
    });
    _maybeMarkViewed();
  }

  @override
  void dispose() {
    _snapController.dispose();
    _replyController.dispose();
    _replyFocusNode.dispose();
    super.dispose();
  }

  // Defensive backstop for the same class of bug build() guards against
  // below: if widget.group ever updates with a shorter statuses list
  // (deleting the last piece is the known trigger — statusFeedProvider's
  // live stream can deliver the post-delete group before
  // _confirmAndDeleteStatus's popUntil actually unmounts this screen,
  // reusing this same State via its unchanged ValueKey) while
  // _currentIndex now points past the new end, clamp it back in bounds
  // rather than leaving it dangling for the next _currentStatus read.
  @override
  void didUpdateWidget(_StatusGroupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final maxIndex = widget.group.statuses.length - 1;
    if (maxIndex >= 0 && _currentIndex > maxIndex) {
      _currentIndex = maxIndex;
    }
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

  // Shared by both the tap and the swipe-up gesture on the "Baxanlar"
  // label below — pauses the segment timer/video while the viewers list
  // is open (no RouteAware/lifecycle hook exists in this screen for
  // "another route was pushed on top": confirmed _confirmAndDeleteStatus's
  // own AlertDialog doesn't pause either, so this is done explicitly
  // around the push/pop instead of relying on one).
  Future<void> _openStatusViewers(Status status) async {
    setState(() => _paused = true);
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => StatusViewersScreen(
        ownerUid: widget.group.ownerUid,
        statusId: status.id,
      ),
    );
    if (mounted) setState(() => _paused = false);
  }

  // Deleting is destructive and immediate (no undo) — confirm first,
  // same AlertDialog shape as create_status_screen.dart's over-30s
  // dialog for visual consistency within this feature. Only pops the
  // whole viewer back to ChatsScreen when this was the author's last
  // remaining piece — otherwise stays open: didUpdateWidget's clamp +
  // build()'s bounds guard (added for the RangeError fix) already handle
  // rendering whatever piece is now current once the shortened group
  // arrives via statusFeedProvider's stream, so there's nothing else this
  // method needs to do to show it.
  Future<void> _confirmAndDeleteStatus(Status status) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text('Statusu sil', style: TextStyle(color: kText)),
        content: const Text(
          'Bu status həmişəlik silinəcək.',
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Ləğv et', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sil', style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Captured before the delete resolves — deleteStatus() itself returns
    // nothing about the post-delete count, and widget.group.statuses isn't
    // updated locally by this method (only ever replaced wholesale by a
    // new _StatusGroupPage from StatusViewerScreen's own rebuild), so this
    // is the only point where "how many pieces existed" is actually known.
    final wasLastPiece = widget.group.statuses.length <= 1;
    try {
      await ref
          .read(firestoreServiceProvider)
          .deleteStatus(ownerUid: status.ownerUid, statusId: status.id);
      if (!mounted) return;
      if (wasLastPiece) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: '_StatusGroupPageState: status delete failed',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Status silinmədi'),
          backgroundColor: kRed,
        ),
      );
    }
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

  // Sends the typed reply as a normal chat message in the (possibly
  // brand-new) 1:1 chat with this status's owner — see
  // FirestoreService.getOrCreateDirectChat's own doc comment for why a
  // reply may be the very first message between this pair. Unlike
  // _markViewed above, a failure here MUST be surfaced (silently losing a
  // reply the person thinks they sent is worse than the brief interruption
  // of a SnackBar), matching _confirmAndDeleteStatus's own try/catch shape
  // one section up rather than _markViewed's silent-log one.
  Future<void> _sendStatusReply(Status status, {String? overrideText}) async {
    // overrideText != null means a quick-emoji-reaction tap, not the typed
    // field — sent independently of whatever's currently in _replyController
    // (matching WhatsApp's own behavior: tapping a quick reaction doesn't
    // touch, clear, or send an in-progress typed draft). Only a null
    // overrideText (the actual send button / keyboard-submit path) reads
    // from and clears the real text field below.
    final text = overrideText ?? _replyController.text.trim();
    if (text.isEmpty || _sendingReply) return;
    setState(() => _sendingReply = true);
    try {
      final service = ref.read(firestoreServiceProvider);
      final chatId = await service.getOrCreateDirectChat(
        myUid: widget.currentUid,
        otherUid: status.ownerUid,
      );
      await service.sendMessage(
        chatId: chatId,
        senderId: widget.currentUid,
        text: text,
        replyToStatusId: status.id,
        replyToStatusOwnerUid: status.ownerUid,
        replyToStatusType: status.type,
        replyToStatusText: status.type == 'text'
            ? (status.text ?? '')
            : (status.caption ?? ''),
        replyToStatusThumbnailURL: status.type == 'text'
            ? null
            : status.mediaUrl,
      );
      if (!mounted) return;
      if (overrideText == null) {
        _replyController.clear();
        _replyFocusNode.unfocus();
      }
      // Captured before popping — same "grab the reference before an
      // imperative pop/async gap" pattern this app already uses elsewhere
      // (e.g. _scrollToMessage's own ScaffoldMessenger capture), since
      // this widget's own context becomes unsafe to derive new lookups
      // from right after Navigator.pop schedules it for removal.
      final router = GoRouter.of(context);
      Navigator.of(context).pop();
      router.push('/chat/$chatId');
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'StatusViewerScreen: status reply send failed',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cavab göndərilmədi'),
          backgroundColor: kRed,
        ),
      );
    } finally {
      if (mounted) setState(() => _sendingReply = false);
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
    if (details.velocity.pixelsPerSecond.dy < -velocityThreshold) {
      if (widget.isOwnGroup) {
        unawaited(_openStatusViewers(_currentStatus));
      } else {
        _replyFocusNode.requestFocus();
      }
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
    // Bridges the brief window between statusFeedProvider delivering a
    // shortened group (deleting the last piece is the known trigger) and
    // _confirmAndDeleteStatus's popUntil actually unmounting this screen —
    // without this, _currentStatus below would index past the end of the
    // now-shorter list and throw. didUpdateWidget above clamps
    // _currentIndex for every other case; this covers the one case it
    // can't (the list is now empty, so there's no valid index to clamp to).
    if (widget.group.statuses.isEmpty ||
        _currentIndex >= widget.group.statuses.length) {
      return const Scaffold(backgroundColor: Colors.black);
    }
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
                        isOwnGroup: widget.isOwnGroup,
                        onDelete: () => _confirmAndDeleteStatus(status),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 180,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withAlpha(150),
                          Colors.transparent,
                        ],
                      ),
                    ),
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
                      onTap: () => unawaited(_openStatusViewers(status)),
                      // Swipe-up-to-open now handled screen-wide by
                      // _handleVerticalDragEnd — no local
                      // onVerticalDragEnd needed here anymore.
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.keyboard_arrow_up,
                            color: kText,
                            size: 34,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.remove_red_eye_outlined,
                                size: 20,
                                color: kText,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${ref.watch(statusViewersProvider((ownerUid: widget.group.ownerUid, statusId: status.id))).value?.length ?? 0}',
                                style: const TextStyle(
                                  color: kText,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                // Viewer side (not the author): a WhatsApp-style reply bar,
                // always visible (not just on tap) per product decision —
                // AND an upward swipe also focuses it, exactly mirroring
                // the owner-side gesture above rather than introducing a
                // different interaction vocabulary for the same screen.
                // Same "safe alongside the screen-wide dismiss
                // GestureDetector" reasoning as that block: onVerticalDragEnd
                // only, no onVerticalDragUpdate, so it never competes with
                // the outer drag-to-dismiss for the same pointer motion.
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 24,
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Quick-reaction row — WhatsApp's own standard set.
                        // Each tap sends that single emoji through the
                        // exact same _sendStatusReply pipe as the typed
                        // field below (a status reaction IS just a normal
                        // reply whose text happens to be one emoji — see
                        // this method's own overrideText param), rather
                        // than a separate reaction-count field on the
                        // status doc itself (that's how message reactions
                        // work — toggleMessageReaction in
                        // functions/src/index.ts — but status reactions
                        // are a different, simpler WhatsApp mechanic with
                        // no aggregate count anywhere).
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(30),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: Colors.white.withAlpha(80),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children:
                                const ['❤️', '😂', '😮', '😢', '🙏', '👏']
                                    .map(
                                      (emoji) => GestureDetector(
                                        onTap: () => unawaited(
                                          _sendStatusReply(
                                            status,
                                            overrideText: emoji,
                                          ),
                                        ),
                                        child: Text(
                                          emoji,
                                          style: const TextStyle(
                                            fontSize: 26,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                          ),
                        ),
                        // Swipe-up-to-focus now handled screen-wide by
                        // _handleVerticalDragEnd — no local
                        // onVerticalDragEnd needed here anymore.
                        Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(30),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: Colors.white.withAlpha(80),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _replyController,
                                    focusNode: _replyFocusNode,
                                    style: const TextStyle(
                                      color: kText,
                                      fontSize: 14,
                                    ),
                                    maxLines: 4,
                                    minLines: 1,
                                    textInputAction: TextInputAction.send,
                                    onSubmitted: (_) =>
                                        unawaited(_sendStatusReply(status)),
                                    decoration: const InputDecoration(
                                      hintText: 'Cavab yaz...',
                                      hintStyle: TextStyle(
                                        color: kMuted,
                                        fontSize: 14,
                                      ),
                                      border: InputBorder.none,
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                // Only shown once there's something to send —
                                // an always-visible send button next to an
                                // empty field invites a confusing empty-
                                // message send attempt (silently a no-op,
                                // per _sendStatusReply's own early-return
                                // guard), same as leaving it out entirely
                                // would, but this is clearer about why
                                // nothing happens.
                                if (_replyController.text.trim().isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: _sendingReply
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: kGold,
                                            ),
                                          )
                                        : GestureDetector(
                                            onTap: () => unawaited(
                                              _sendStatusReply(status),
                                            ),
                                            child: const Icon(
                                              Icons.send,
                                              color: kGold,
                                              size: 20,
                                            ),
                                          ),
                                  ),
                              ],
                            ),
                          ),
                      ],
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
  final bool isOwnGroup;
  final VoidCallback onDelete;

  const _HeaderRow({
    required this.user,
    required this.status,
    required this.onClose,
    required this.isOwnGroup,
    required this.onDelete,
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
        // Own statuses get a "..." menu (currently just delete) instead
        // of a plain close X — deleting removes this specific status
        // fragment via the already-deployed backend (firestore.rules'
        // owner-delete rule + onStatusDeleted's cascade cleanup). Other
        // people's statuses keep the plain close X unchanged — deleting
        // someone else's status was never possible and isn't offered.
        // The existing drag-down-to-dismiss gesture still works as a
        // close method either way, this only changes the button.
        if (isOwnGroup)
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white, size: 26),
            color: kBg2,
            onSelected: (value) {
              if (value == 'delete') onDelete();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'delete',
                child: Text('Sil', style: TextStyle(color: kText)),
              ),
            ],
          )
        else
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 26),
            onPressed: onClose,
          ),
      ],
    );
  }
}

// Entry point for opening one specific person's status directly — e.g. from
// an avatar ring on a screen outside the friends-scoped feed (chat header,
// musician list, add-participant picker, ...), where the target may not be
// a friend at all. Deliberately kept in this same file rather than made a
// separate top-level screen: it needs to hand its fetched StatusGroup to
// _StatusGroupPage, which is private to this file — this file already has
// several private helper widgets, so adding one more closely-related entry
// point here (rather than removing that widget's privacy, or duplicating
// its ~300 lines of gesture/playback logic elsewhere) is the smaller,
// lower-risk change. StatusViewerScreen itself is NOT reused as-is: its
// whole PageView is built around swiping across every group in the live
// friends feed (statusFeedProvider), which doesn't apply here — a single
// person's statuses, opened from outside that feed, with nothing else to
// swipe to.
class UserStatusViewerScreen extends ConsumerStatefulWidget {
  final String ownerUid;
  final String currentUid;
  // Optional — when the caller already has the owner's User doc in hand
  // (every avatar-ring site does, per activeStatusIds/hasActiveStatus's own
  // rationale), passing it here skips a redundant fetch. Falls back to
  // userByIdProvider when omitted.
  final User? initialUser;
  // Optional — which specific status to open on first frame (e.g. a
  // status-reply's quote tap in chat_screen.dart), forwarded as-is to
  // _StatusGroupPage. Every existing call site omits this and keeps
  // opening at the first status, unchanged.
  final String? initialStatusId;

  const UserStatusViewerScreen({
    super.key,
    required this.ownerUid,
    required this.currentUid,
    this.initialUser,
    this.initialStatusId,
  });

  @override
  ConsumerState<UserStatusViewerScreen> createState() =>
      _UserStatusViewerScreenState();
}

class _UserStatusViewerScreenState
    extends ConsumerState<UserStatusViewerScreen> {
  Future<StatusGroup?>? _groupFuture;

  @override
  void initState() {
    super.initState();
    if (widget.initialUser != null) {
      _groupFuture = _fetch(widget.initialUser!);
    }
  }

  Future<StatusGroup?> _fetch(User owner) {
    return ref
        .read(firestoreServiceProvider)
        .fetchStatusGroupForUser(owner: owner);
  }

  static const _loading = Scaffold(
    backgroundColor: Colors.black,
    body: Center(child: CircularProgressIndicator(color: kGold)),
  );

  @override
  Widget build(BuildContext context) {
    // initialUser omitted — resolve it ourselves first (userByIdProvider is
    // the same one-shot per-uid fetch already used elsewhere in this app,
    // e.g. message_info_screen.dart, for exactly this "not already in
    // hand" case), then kick off _fetch exactly once via the same
    // _groupFuture ??= pattern as _MyStatusItem/_OtherStatusItem's own
    // initState-computed futures elsewhere in this file — recomputing it on
    // every build would refire the fetch (and every per-status get() inside
    // it) on any unrelated rebuild.
    if (widget.initialUser == null) {
      final ownerAsync = ref.watch(userByIdProvider(widget.ownerUid));
      final owner = ownerAsync.value;
      if (owner == null) {
        return ownerAsync.hasError ? _errorScaffold() : _loading;
      }
      _groupFuture ??= _fetch(owner);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<StatusGroup?>(
        future: _groupFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(color: kGold),
            );
          }
          final group = snapshot.data;
          if (group == null) {
            return const Center(
              child: Text(
                'Aktiv status yoxdur',
                style: TextStyle(color: kMuted),
              ),
            );
          }
          return _StatusGroupPage(
            key: ValueKey(group.ownerUid),
            group: group,
            currentUid: widget.currentUid,
            isOwnGroup: group.ownerUid == widget.currentUid,
            // Nothing else to swipe to — this viewer only ever shows the
            // one requested person's group, so "advance" just closes it,
            // matching StatusViewerScreen's own end-of-feed behavior
            // (Navigator.pop when index == groups.length - 1) rather than
            // introducing a distinct "last piece" gesture just for this
            // entry point.
            onAdvanceToNextAuthor: () => Navigator.of(context).pop(),
            initialStatusId: widget.initialStatusId,
          );
        },
      ),
    );
  }

  Widget _errorScaffold() {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text(
          'Status yüklənmədi',
          style: TextStyle(color: kMuted),
        ),
      ),
    );
  }
}
