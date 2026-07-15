import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import 'forward_sheet.dart';
import 'video_message_widgets.dart';

// Shared full-screen media viewer, opened from a tapped ImageMessageBubble/
// VideoMessageBubble in chat_screen.dart — unlike the old showFullImage
// (single photo, no chat context), this browses ALL of the chat's
// image/video messages (chatMediaProvider) via a swipeable PageView + a
// bottom thumbnail strip, matching the WhatsApp/Telegram "media gallery"
// pattern. Built entirely on already-verified standalone pieces:
// VideoPlaybackCore for video pages, ZoomableImage for photo pages,
// ChatMediaThumbnail for the strip tiles.
//
// ZoomableImage only accepts a non-null imageURL (no localFilePath
// support) — that's fine here because (a) chatMediaProvider's messages are
// always real, already-sent Firestore docs (never a synthetic pending
// message, which only exists client-side and is never round-tripped
// through Firestore — see Message.localSendStatus's own doc comment), so
// they always carry a real imageURL/videoURL, and (b) the chat_screen.dart
// call site that opens this screen already gates the tap on
// `msg.imageURL != null`, so initialMessage can't be a still-pending photo
// either.
class ChatAttachmentViewerScreen extends ConsumerStatefulWidget {
  final Message initialMessage;
  final String chatId;
  final String currentUid;
  final String chatName;
  final String senderName;

  const ChatAttachmentViewerScreen({
    super.key,
    required this.initialMessage,
    required this.chatId,
    required this.currentUid,
    required this.chatName,
    required this.senderName,
  });

  @override
  ConsumerState<ChatAttachmentViewerScreen> createState() =>
      _ChatAttachmentViewerScreenState();
}

class _ChatAttachmentViewerScreenState
    extends ConsumerState<ChatAttachmentViewerScreen>
    with SingleTickerProviderStateMixin {
  // Mirrors VideoPlayerScreen/VideoPlaybackCore's own bottomChromeHeight
  // contract (see that widget's doc comment) — computed from the exact
  // same constants the bottom chrome Column below is built with, rather
  // than a separately-guessed number, so the two can't silently drift.
  static const double _kActionRowHeight = 56.0;
  static const double _kThumbnailStripHeight = 64.0;

  // Drag-to-dismiss thresholds/visual treatment match StatusViewerScreen's
  // own _StatusGroupPageState for a consistent feel across the app, but
  // the AnimationController/state below is this screen's own instance —
  // separate screens, separate lifecycles, nothing shared. Unlike
  // StatusViewerScreen, this drag is gated on _isZoomed (see
  // _buildAttachment's onZoomChanged wiring): StatusViewerScreen nests its
  // own vertical-drag GestureDetector directly around ZoomableImage with
  // no such gating, which is a latent, currently-unaddressed conflict
  // there between the dismiss drag and ZoomableImage's own pan-when-zoomed
  // gesture (out of scope to fix in that screen here) — deliberately not
  // copied into this screen.
  static const double _dismissDistanceThreshold = 120.0;
  static const double _dismissVelocityThreshold = 700.0;

  late final PageController _pageController;
  int _currentIndex = 0;
  // Set once chatMediaProvider's list first arrives and initialMessage's
  // position in it has been located — guards against re-jumping the
  // PageController on every later emission of the same provider (e.g. a
  // reaction elsewhere in the chat re-triggers this stream).
  bool _initialPageResolved = false;

  // True while the CURRENT page's ZoomableImage is zoomed in (see
  // _buildAttachment's onZoomChanged) — gates the dismiss-drag
  // GestureDetector's recognizers to null (not just a no-op callback body)
  // so InteractiveViewer's own pan-when-zoomed gesture isn't competing
  // against a vertical-drag recognizer it can't win outright; see
  // ZoomableImage.onZoomChanged's own doc comment for why a plain
  // no-op-the-callback approach wouldn't be enough here.
  bool _isZoomed = false;
  double _dragY = 0;
  late final AnimationController _snapController;
  Animation<double>? _snapAnimation;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _snapController.dispose();
    super.dispose();
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    setState(() {
      // No floor at 0 (unlike StatusViewerScreen's down-only original) —
      // this screen dismisses on either an upward or a downward drag, so
      // the sign of _dragY must be preserved to track which direction
      // the finger is actually moving.
      _dragY = _dragY + details.delta.dy;
    });
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    final shouldDismiss =
        _dragY.abs() > _dismissDistanceThreshold ||
        details.velocity.pixelsPerSecond.dy.abs() > _dismissVelocityThreshold;
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

  void _resolveInitialPage(List<Message> media) {
    if (_initialPageResolved) return;
    final index = media.indexWhere((m) => m.id == widget.initialMessage.id);
    if (index == -1) return;
    _initialPageResolved = true;
    if (index == 0) {
      if (mounted) setState(() => _currentIndex = 0);
      return;
    }
    // The PageController was already constructed (and, once the PageView
    // below first builds, attached) with its default initialPage of 0 —
    // this data arrived asynchronously after that, so correcting to the
    // real index needs an explicit jump post-frame rather than a
    // constructor-time initialPage.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _pageController.jumpToPage(index);
      setState(() => _currentIndex = index);
    });
  }

  Future<void> _shareMessage(Message message) async {
    try {
      final localPath = message.localFilePath;
      final XFile file;
      if (localPath != null) {
        file = XFile(localPath);
      } else if (message.type == 'video' && message.videoURL != null) {
        final cached = await DefaultCacheManager().getSingleFile(
          message.videoURL!,
        );
        final bytes = await cached.readAsBytes();
        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/share_${message.id}.mp4';
        await File(path).writeAsBytes(bytes);
        file = XFile(path);
      } else if (message.type == 'image' && message.imageURL != null) {
        final cached = await DefaultCacheManager().getSingleFile(
          message.imageURL!,
        );
        final bytes = await cached.readAsBytes();
        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/share_${message.id}.jpg';
        await File(path).writeAsBytes(bytes);
        file = XFile(path);
      } else {
        return;
      }
      await SharePlus.instance.share(ShareParams(files: [file]));
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'ChatAttachmentViewerScreen: share failed',
      );
    }
  }

  void _openForward(Message message) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg2,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ForwardSheet(
        messages: [message],
        sourceChatId: widget.chatId,
        currentUid: widget.currentUid,
        onDone: () {},
      ),
    );
  }

  Future<void> _toggleFavorite(Message message, bool isStarred) async {
    final service = ref.read(firestoreServiceProvider);
    if (isStarred) {
      await service.unstarMessage(
        uid: widget.currentUid,
        messageId: message.id,
      );
    } else {
      await service.starMessage(
        uid: widget.currentUid,
        chatId: widget.chatId,
        chatName: widget.chatName,
        senderName: widget.senderName,
        message: message,
      );
    }
  }

  void _confirmDelete(Message message) {
    final isMe = message.senderId == widget.currentUid;
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(width: 40),
                  const Expanded(
                    child: Text(
                      'Mesajı silmək?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: kText,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: kMuted),
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (isMe)
                ListTile(
                  title: const Text(
                    'Hamıdan sil',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await ref
                        .read(firestoreServiceProvider)
                        .deleteMessageForAll(
                          chatId: widget.chatId,
                          messageId: message.id,
                        );
                    if (mounted) Navigator.of(context).pop();
                  },
                ),
              ListTile(
                title: const Text(
                  'Yalnız məndən sil',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await ref
                      .read(firestoreServiceProvider)
                      .deleteMessageForMe(
                        chatId: widget.chatId,
                        messageId: message.id,
                        uid: widget.currentUid,
                      );
                  if (mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openReactionPicker(Message message) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SizedBox(
        height: 320,
        child: EmojiPicker(
          onEmojiSelected: (category, emoji) {
            Navigator.of(context).pop();
            ref
                .read(firestoreServiceProvider)
                .toggleReaction(
                  chatId: widget.chatId,
                  messageId: message.id,
                  emoji: emoji.emoji,
                );
          },
        ),
      ),
    );
  }

  // No .then()-based caller wiring — this screen is a plain
  // Navigator.push (not itself wrapped in a .then() at construction time),
  // so it reports the chosen reply target back through the pop result
  // instead; see chat_screen.dart's call site, which reads it via its own
  // .then((result) { if (result != null) _startReply(result as Message); }).
  void _reply(Message message) {
    Navigator.of(context).pop(message);
  }

  Widget _buildAttachment(Message message, double bottomChromeHeight) {
    if (message.type == 'video') {
      return VideoPlaybackCore(
        videoURL: message.videoURL,
        localFilePath: message.localFilePath,
        bottomChromeHeight: bottomChromeHeight,
      );
    }
    final url = message.imageURL;
    if (url == null) return const SizedBox.shrink();
    return ZoomableImage(
      imageURL: url,
      onZoomChanged: (zoomed) => setState(() => _isZoomed = zoomed),
    );
  }

  Widget _buildHeader(Message message) {
    final timestamp = message.timestamp;
    final dateText = timestamp != null
        ? DateFormat('d MMM, HH:mm').format(timestamp.toDate())
        : '';
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      // No nested SafeArea here — _buildScaffold now wraps its whole body
      // Stack in a single top-level SafeArea (matching VideoPlayerScreen's
      // own close-button Positioned, which relies on that same outer
      // SafeArea alone), so a second one here would double-apply the top
      // inset instead of just measuring from it once.
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        color: Colors.black45,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.senderName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (dateText.isNotEmpty)
                    Text(
                      dateText,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            // Stub — menu has no functionality yet, just the affordance.
            IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnailStrip(List<Message> media) {
    return SizedBox(
      height: _kThumbnailStripHeight,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: media.length,
        itemBuilder: (context, index) {
          final item = media[index];
          final isCurrent = index == _currentIndex;
          return GestureDetector(
            onTap: () => _pageController.animateToPage(
              index,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            ),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: isCurrent ? Border.all(color: kGold, width: 2) : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: ChatMediaThumbnail(message: item, size: 48),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildActionRow(Message message, bool isStarred) {
    return SizedBox(
      height: _kActionRowHeight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          IconButton(
            icon: const Icon(Icons.ios_share, color: Colors.white),
            onPressed: () => _shareMessage(message),
          ),
          IconButton(
            icon: const Icon(Icons.forward, color: Colors.white),
            onPressed: () => _openForward(message),
          ),
          IconButton(
            icon: Icon(
              isStarred ? Icons.star : Icons.star_border,
              color: isStarred ? kGold : Colors.white,
            ),
            onPressed: () => _toggleFavorite(message, isStarred),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white),
            onPressed: () => _confirmDelete(message),
          ),
          IconButton(
            icon: const Icon(
              Icons.emoji_emotions_outlined,
              color: Colors.white,
            ),
            onPressed: () => _openReactionPicker(message),
          ),
          InkWell(
            onTap: () => _reply(message),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: kBg3,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.reply, color: kGold, size: 18),
                  SizedBox(width: 6),
                  Text(
                    'Cavabla',
                    style: TextStyle(color: kGold, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScaffold({
    required Message currentMessage,
    required bool isStarred,
    required int pageCount,
    required Widget Function(int index) pageBuilder,
    required List<Message>? thumbnailMedia,
  }) {
    final showStrip = thumbnailMedia != null && thumbnailMedia.length > 1;
    final dismissProgress = (_dragY.abs() / 400).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: Colors.black,
      // A single SafeArea for the whole body — matching VideoPlayerScreen's
      // own working structure — puts the header, PageView/VideoPlaybackCore,
      // and footer all in the same coordinate space. Previously the footer
      // alone had its own nested SafeArea(top: false) while the PageView
      // had none at all, so VideoPlaybackCore's own
      // Positioned(bottom: widget.bottomChromeHeight) was measured from the
      // true screen edge while the footer's actual painted position was
      // already inset upward by its own SafeArea — the two disagreed on
      // where "bottom" was, and the footer's opaque Container visually
      // overlapped and painted over the scrub bar underneath it.
      body: SafeArea(
        child: Stack(
          children: [
            GestureDetector(
              // null (not a no-op body) while zoomed — see _isZoomed's own
              // doc comment on why the recognizer itself must not exist
              // rather than merely declining to act, so InteractiveViewer's
              // pan-when-zoomed gesture isn't competing against it in the
              // arena. Horizontal drags are left entirely alone (no
              // onHorizontalDrag* here), same as StatusViewerScreen's own
              // outer gesture detector — that's the PageView's own default
              // swipe-between-pages behavior, untouched.
              onVerticalDragUpdate:
                  _isZoomed ? null : _handleVerticalDragUpdate,
              onVerticalDragEnd: _isZoomed ? null : _handleVerticalDragEnd,
              child: Transform.translate(
                offset: Offset(0, _dragY),
                child: Opacity(
                  opacity: 1 - dismissProgress * 0.6,
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: pageCount,
                    onPageChanged: (index) => setState(() {
                      _currentIndex = index;
                      // A new page is now current and hasn't been touched
                      // yet — reset the gate rather than leaving it stuck
                      // on whatever the PREVIOUS (now off-screen) page's
                      // ZoomableImage last reported, which would otherwise
                      // silently disable dismiss on every later page until
                      // the user happened to zoom in and back out again.
                      _isZoomed = false;
                    }),
                    itemBuilder: (context, index) => pageBuilder(index),
                  ),
                ),
              ),
            ),
            _buildHeader(currentMessage),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              // No nested SafeArea here either — see the outer SafeArea's
              // own doc comment above; this Positioned now shares that
              // single coordinate space with VideoPlaybackCore's scrub bar,
              // so their bottom edges actually line up instead of the
              // footer silently painting over it.
              child: Container(
                color: Colors.black45,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showStrip) _buildThumbnailStrip(thumbnailMedia),
                    _buildActionRow(currentMessage, isStarred),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaAsync = ref.watch(chatMediaProvider(widget.chatId));
    final starredAsync = ref.watch(starredMessagesProvider(widget.currentUid));

    return mediaAsync.when(
      data: (media) {
        // chatMediaProvider's own doc comment (watchChatMedia in
        // firestore_service.dart) explicitly requires the caller to apply
        // the per-user deletedFor filter itself — Firestore has no "array
        // does not contain" query, so it can't be done server-side.
        // Missing this let a message the current user had personally
        // deleted still appear here and be reply-quotable, which then made
        // chat_screen.dart's reply-jump silently fail afterward (that
        // screen's own _lastMessages correctly filters deletedFor, by
        // design, so the target could never be found there — this was
        // mistaken for a timing race before the real cause was found).
        final filteredMedia = media
            .where((m) => !m.deletedFor.contains(widget.currentUid))
            .toList();
        _resolveInitialPage(filteredMedia);
        final items = filteredMedia.isEmpty
            ? [widget.initialMessage]
            : filteredMedia;
        final currentMessage = items[_currentIndex.clamp(0, items.length - 1)];
        final isStarred =
            starredAsync.value?.any((m) => m.id == currentMessage.id) ??
            false;
        final showStrip = items.length > 1;
        final bottomChromeHeight =
            (showStrip ? _kThumbnailStripHeight : 0.0) + _kActionRowHeight;
        return _buildScaffold(
          currentMessage: currentMessage,
          isStarred: isStarred,
          pageCount: items.length,
          pageBuilder: (index) =>
              _buildAttachment(items[index], bottomChromeHeight),
          thumbnailMedia: items,
        );
      },
      // Not blocked on chatMediaProvider's first snapshot — show the
      // tapped attachment immediately in a single-page view, same as
      // VideoPlayerScreen's own instant-open behavior, and let the real
      // multi-item PageView replace it once the list arrives (see the
      // `data` branch, which is what actually runs from then on for this
      // same live provider).
      loading: () {
        final isStarred =
            starredAsync.value?.any(
              (m) => m.id == widget.initialMessage.id,
            ) ??
            false;
        return _buildScaffold(
          currentMessage: widget.initialMessage,
          isStarred: isStarred,
          pageCount: 1,
          pageBuilder: (_) =>
              _buildAttachment(widget.initialMessage, _kActionRowHeight),
          thumbnailMedia: null,
        );
      },
      error: (e, st) {
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          reason: 'ChatAttachmentViewerScreen: chatMediaProvider failed',
        );
        final isStarred =
            starredAsync.value?.any(
              (m) => m.id == widget.initialMessage.id,
            ) ??
            false;
        return _buildScaffold(
          currentMessage: widget.initialMessage,
          isStarred: isStarred,
          pageCount: 1,
          pageBuilder: (_) =>
              _buildAttachment(widget.initialMessage, _kActionRowHeight),
          thumbnailMedia: null,
        );
      },
    );
  }
}
