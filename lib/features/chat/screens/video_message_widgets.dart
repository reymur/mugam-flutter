import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:video_player/video_player.dart';
import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import 'chat_screen.dart';
import 'forward_sheet.dart';
import 'media_thumbnail_cache.dart';

// Single source of truth for "what state is this message visually in" —
// computed once per message in chat_screen.dart's _buildMessageBubble and
// consumed by BOTH the corner checkmark AND the photo/video upload-progress
// ring, instead of each independently re-deriving its own interpretation
// of msg.localSendStatus/deliveredTo/lastReadMsgId. Confirmed on-device
// that those two previously-separate branches could visibly disagree for
// several seconds (checkmarks already showing delivered while the video's
// progress ring was still up) — not a timing bug in either branch
// specifically, but the structural risk of having two independent
// decisions about the same underlying state at all. This doesn't reduce
// the number of underlying data sources (pending queue vs. Firestore
// messages vs. Firestore chat-meta genuinely are different, necessarily
// separate providers) — it just guarantees every widget reads the one
// already-computed answer instead of asking its own version of the
// question.
enum MessageDeliveryStatus { queued, uploading, failed, sentUnconfirmed, delivered, read }

// isMe/otherUid gate the delivered/read computation the same way the old
// inline logic did (group chats / other people's messages have no
// meaningful otherUid-keyed receipt to check) — anything that isn't
// queued/uploading/failed and doesn't qualify for that check is
// sentUnconfirmed, matching the prior fallback behavior exactly.
MessageDeliveryStatus deliveryStatusFor({
  required Message msg,
  required bool isMe,
  required String? otherUid,
  required Map<String, dynamic> deliveredTo,
  required Map<String, dynamic> lastReadMsgId,
  required List<String> allMsgIds,
  required int index,
}) {
  switch (msg.localSendStatus) {
    case 'queued':
      return MessageDeliveryStatus.queued;
    case 'uploading':
      return MessageDeliveryStatus.uploading;
    case 'failed':
      return MessageDeliveryStatus.failed;
  }
  if (!isMe || otherUid == null) return MessageDeliveryStatus.sentUnconfirmed;
  final lastReadId = lastReadMsgId[otherUid] as String?;
  final lastReadIndex = lastReadId != null ? allMsgIds.indexOf(lastReadId) : -1;
  final isRead = lastReadIndex != -1 && index >= lastReadIndex;
  if (isRead) return MessageDeliveryStatus.read;
  if (deliveredTo[otherUid] != null) return MessageDeliveryStatus.delivered;
  return MessageDeliveryStatus.sentUnconfirmed;
}

Future<void> _deactivateAudioSession() async {
  try {
    final session = await AudioSession.instance;
    await session.setActive(false);
  } catch (e, st) {
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'video_message_widgets: _deactivateAudioSession failed',
    );
  }
}

// Separate from the DefaultCacheManager used for images — videos are much
// larger, so they get their own bounded store instead of competing with (or
// bloating past) the image cache's own size/age limits.
class VideoCacheManager {
  static const key = 'mugamVideoCache';
  static final CacheManager instance = CacheManager(
    Config(key, stalePeriod: const Duration(days: 7), maxNrOfCacheObjects: 30),
  );
}

// Playback always starts immediately via network stream (see
// _VideoPlayerScreenState) — this just warms the cache in the background so
// a later open of the same video can skip the network entirely. Guarded
// against piling up duplicate downloads if the same video is opened/closed
// several times before the first download finishes.
final Set<String> _videoCachingInFlight = {};

Future<void> _cacheVideoInBackground(String url) async {
  if (url.isEmpty || _videoCachingInFlight.contains(url)) return;
  if (await VideoCacheManager.instance.getFileFromCache(url) != null) return;
  _videoCachingInFlight.add(url);
  try {
    await VideoCacheManager.instance.downloadFile(url);
  } catch (_) {
    // A failed background cache attempt must not surface as a playback
    // error — the next open just tries again from scratch.
  } finally {
    _videoCachingInFlight.remove(url);
  }
}

// Plain thumbnail frame, no tap handler and no play icon — used both by the
// full-size chat bubble (wrapped with a play icon by VideoMessageBubble) and
// by the small quote-card previews, which don't need a play affordance.
// VideoThumbnail.thumbnailData's `video` param accepts either a network URL
// or a local file path, so a not-yet-uploaded pending video's thumbnail
// renders exactly the same way as a sent one.
class VideoThumbnailImage extends StatefulWidget {
  final String? videoURL;
  final String? localFilePath;
  // Null for VideoMessageBubble's chat-bubble usage, which sizes its own
  // ancestor to the video's real aspect ratio and lets this widget fill it
  // (see StackFit.expand there). Non-null for the fixed-square quote-card/
  // replying-to-bar previews, unaffected by this change.
  final double? size;
  // Stable key (see Message.stableMediaKey) identifying the logical message
  // this thumbnail belongs to, independent of which technical source
  // (localFilePath vs. videoURL) is currently being read from — see
  // MediaThumbnailCacheManager. Null for the reply-quote/reply-composer
  // preview call sites, which only ever render an already-final videoURL
  // (never experience a local->network swap), so they fall back to keying
  // by source exactly as before.
  final String? cacheKey;
  // Already-generated preview frame bytes, captured before this message was
  // ever enqueued and already precached into Flutter's ImageCache (see
  // chat_screen.dart's _uploadAndSendVideoFile) — lets the very first build
  // paint the real thumbnail immediately instead of showing the loading
  // spinner while _loadThumb's own generation call catches up. Null for the
  // reply-quote/reply-composer previews (already-sent videos, no pending
  // phase) and for a pending item resumed after an app restart (this is
  // never persisted).
  final Uint8List? initialBytes;

  const VideoThumbnailImage({
    super.key,
    this.videoURL,
    this.localFilePath,
    this.size,
    this.cacheKey,
    this.initialBytes,
  });

  @override
  State<VideoThumbnailImage> createState() => _VideoThumbnailImageState();
}

class _VideoThumbnailImageState extends State<VideoThumbnailImage> {
  Uint8List? _thumb;

  String get _source => widget.localFilePath ?? widget.videoURL ?? '';
  String get _cacheKey => widget.cacheKey ?? _source;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialBytes;
    if (initial != null) {
      _thumb = initial;
      MediaThumbnailCacheManager.instance.put(_cacheKey, initial);
    } else {
      _loadThumb();
    }
  }

  @override
  void didUpdateWidget(VideoThumbnailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A message's videoURL can change under an already-mounted bubble (e.g.
    // a queued send's synthetic localFilePath being replaced by the real
    // uploaded URL) — reload only if the LOGICAL message identity changed
    // (cacheKey), not just the technical source. Same message, same cached
    // bytes: no reset, no visible reload flash.
    final oldKey = oldWidget.cacheKey ?? (oldWidget.localFilePath ?? oldWidget.videoURL ?? '');
    if (oldKey != _cacheKey) {
      setState(() => _thumb = null);
      _loadThumb();
    }
  }

  Future<void> _loadThumb() async {
    final source = _source;
    if (source.isEmpty) return;
    final key = _cacheKey;
    final cached = MediaThumbnailCacheManager.instance.get(key);
    if (cached != null) {
      if (mounted) setState(() => _thumb = cached);
      return;
    }
    try {
      final data = await VideoThumbnail.thumbnailData(
        video: source,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 400,
        quality: 60,
      );
      MediaThumbnailCacheManager.instance.put(key, data);
      if (mounted) setState(() => _thumb = data);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _thumb;
    return Container(
      width: widget.size,
      height: widget.size,
      color: kBg3,
      child: thumb != null
          ? Image.memory(thumb, fit: BoxFit.cover)
          : const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: kGold),
              ),
            ),
    );
  }
}

// Plain static-image thumbnail counterpart to VideoThumbnailImage — no
// frame-extraction step needed since the source is already an image, so
// this is just CachedNetworkImage/Image.file behind the same kBg3
// placeholder background for visual consistency between image and video
// tiles in a mixed media strip (see ChatMediaThumbnail below). Doesn't
// reuse ImageMessageBubble's ImagePreviewCacheManager/cacheKey plumbing —
// that exists specifically for the pending-upload local->network swap
// (see its own doc comment), which a media-gallery strip of already-sent
// messages doesn't need; CachedNetworkImage already caches the network
// fetch itself.
class ImageThumbnail extends StatelessWidget {
  final String? imageURL;
  final String? localFilePath;
  final double? size;

  const ImageThumbnail({
    super.key,
    this.imageURL,
    this.localFilePath,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final localPath = localFilePath;
    final url = imageURL;
    return Container(
      width: size,
      height: size,
      color: kBg3,
      child: localPath != null
          ? Image.file(File(localPath), fit: BoxFit.cover)
          : url != null
              ? CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  placeholder: (ctx, url) => const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: kGold,
                      ),
                    ),
                  ),
                  errorWidget: (ctx, url, err) => const Icon(
                    Icons.broken_image,
                    color: kMuted,
                  ),
                )
              : const SizedBox.shrink(),
    );
  }
}

// Single entry point for a mixed image/video media strip (see
// chatMediaProvider in firestore_service.dart) — dispatches to
// VideoThumbnailImage or ImageThumbnail by message.type so callers don't
// need their own type-branching. VideoThumbnailImage alone can't render a
// photo (VideoThumbnail.thumbnailData is video-frame-extraction only) and
// ImageThumbnail alone can't render a video frame, so neither is safe to
// use unconditionally across a mixed list.
class ChatMediaThumbnail extends StatelessWidget {
  final Message message;
  final double size;

  const ChatMediaThumbnail({
    super.key,
    required this.message,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return message.type == 'video'
        ? VideoThumbnailImage(
            videoURL: message.videoURL,
            localFilePath: message.localFilePath,
            size: size,
            cacheKey: message.stableMediaKey,
          )
        : ImageThumbnail(
            imageURL: message.imageURL,
            localFilePath: message.localFilePath,
            size: size,
          );
  }
}

// Public (not file-private) so FileMessageBubble's upload-ETA text can
// reuse it instead of a second m:ss formatter — see its doc comment.
String formatDurationMmSs(int ms) {
  final total = Duration(milliseconds: ms);
  final m = total.inMinutes.remainder(60);
  final s = total.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

// Full chat-bubble video message: thumbnail + play icon, tap opens playback.
// Works identically for an already-sent video (videoURL) or one still
// queued/uploading (localFilePath) — tapping either previews the video, a
// message doesn't have to finish sending before it can be watched.
//
// Sized to the video's own as-displayed aspect ratio (width/height read
// from the file's metadata at send time, see flutter_video_info in
// chat_screen.dart — NOT derived from decoding the generated thumbnail),
// clamped between a min (so an extremely wide/tall video doesn't become
// unreadable or too small to tap) and a max (so it doesn't blow out the
// chat layout) — matching WhatsApp's media bubbles. width/height are the
// same plain message data in both the pending (queued/uploading synthetic
// message) and sent (real Firestore message) states, so the bubble is a
// stable size across that transition — no resize flicker, unlike an
// earlier version of this that derived size from the thumbnail image,
// which is fetched under a different cache key (local file path vs.
// uploaded URL) in each state. Falls back to a fixed square when
// width/height are unknown (probe failed, or an older message sent before
// this field existed) — stable in both states either way.
class VideoMessageBubble extends StatelessWidget {
  static const double _minSide = 120;
  static const double _maxWidth = 260;
  static const double _maxHeight = 340;
  static const double _fallbackSide = 200;

  final String? videoURL;
  final String? localFilePath;
  final int? durationMs;
  final int? videoWidth;
  final int? videoHeight;
  final double bubbleRadius;
  final Widget timeCheckmarkOverlay;
  // Single computed source of truth (see deliveryStatusFor) — the same
  // value the corner checkmark is derived from, so this widget's own
  // uploading-vs-sent decision can never visibly disagree with it.
  final MessageDeliveryStatus deliveryStatus;
  final double? localUploadProgress;
  final VoidCallback? onCancelUpload;
  // See VideoThumbnailImage.cacheKey — pass Message.stableMediaKey here so
  // the generated thumbnail survives the pending->sent source swap.
  final String? thumbnailCacheKey;
  // See VideoThumbnailImage.initialBytes.
  final Uint8List? initialBytes;
  // Optional caption (Message.text) — same treatment as ImageMessageBubble,
  // see its own caption field comment for the full rationale.
  final String caption;
  final bool isMe;
  final Message message;
  final String chatId;
  final String currentUid;
  final String chatName;
  final String senderName;

  const VideoMessageBubble({
    super.key,
    this.videoURL,
    this.localFilePath,
    this.durationMs,
    this.videoWidth,
    this.videoHeight,
    required this.bubbleRadius,
    required this.timeCheckmarkOverlay,
    required this.deliveryStatus,
    this.localUploadProgress,
    this.onCancelUpload,
    this.thumbnailCacheKey,
    this.initialBytes,
    this.caption = '',
    required this.isMe,
    required this.message,
    required this.chatId,
    required this.currentUid,
    required this.chatName,
    required this.senderName,
  });

  Size _boundedSize() {
    final w0 = videoWidth;
    final h0 = videoHeight;
    if (w0 == null || h0 == null || w0 <= 0 || h0 <= 0) {
      return const Size(_fallbackSide, _fallbackSide);
    }
    final ratio = w0 / h0;
    var w = _maxWidth;
    var h = w / ratio;
    if (h > _maxHeight) {
      h = _maxHeight;
      w = h * ratio;
    }
    if (h < _minSide) {
      h = _minSide;
      w = h * ratio;
    }
    if (w < _minSide) {
      w = _minSide;
      h = w / ratio;
    }
    // Re-clamp in case the min-side correction above pushed the other
    // dimension back past its own max (very thin/wide aspect ratios).
    if (w > _maxWidth) {
      w = _maxWidth;
      h = w / ratio;
    }
    if (h > _maxHeight) {
      h = _maxHeight;
      w = h * ratio;
    }
    return Size(w, h);
  }

  @override
  Widget build(BuildContext context) {
    final size = _boundedSize();
    final hasCaption = caption.trim().isNotEmpty;

    final videoStack = ClipRRect(
      borderRadius: hasCaption
          ? BorderRadius.only(
              topLeft: Radius.circular(bubbleRadius),
              topRight: Radius.circular(bubbleRadius),
            )
          : BorderRadius.circular(bubbleRadius),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            VideoThumbnailImage(
              videoURL: videoURL,
              localFilePath: localFilePath,
              cacheKey: thumbnailCacheKey,
              initialBytes: initialBytes,
            ),
            if (deliveryStatus == MessageDeliveryStatus.queued ||
                deliveryStatus == MessageDeliveryStatus.uploading)
              UploadProgressOverlay(
                progress: deliveryStatus == MessageDeliveryStatus.uploading
                    ? localUploadProgress
                    : null,
                onCancel: onCancelUpload,
              )
            else
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withAlpha(200),
                  ),
                  padding: const EdgeInsets.all(14),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.black87,
                    size: 32,
                  ),
                ),
              ),
            Positioned(
              left: 8,
              bottom: 8,
              child: MediaOverlayChip(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.videocam,
                      color: Colors.white,
                      size: 13,
                    ),
                    if (durationMs != null) ...[
                      const SizedBox(width: 4),
                      Text(
                        formatDurationMmSs(durationMs!),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (!hasCaption)
              Positioned(
                right: 8,
                bottom: 8,
                child: MediaOverlayChip(child: timeCheckmarkOverlay),
              ),
          ],
        ),
      ),
    );

    if (!hasCaption) {
      return GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => VideoPlayerScreen(
              videoURL: videoURL,
              localFilePath: localFilePath,
              message: message,
              chatId: chatId,
              currentUid: currentUid,
              chatName: chatName,
              senderName: senderName,
            ),
          ),
        ),
        child: videoStack,
      );
    }

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              VideoPlayerScreen(
                videoURL: videoURL,
                localFilePath: localFilePath,
                message: message,
                chatId: chatId,
                currentUid: currentUid,
                chatName: chatName,
                senderName: senderName,
              ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(bubbleRadius),
        child: Container(
          width: size.width,
          color: isMe ? kGold : kBg3,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              videoStack,
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        caption,
                        style: TextStyle(
                          color: isMe
                              ? const Color(0xFF1A0E00)
                              : kText,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    timeCheckmarkOverlay,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Full chat-bubble photo message: real image, no bubble padding, time+
// checkmark overlaid bottom-right — same treatment as VideoMessageBubble
// above, just without a play affordance or duration chip since a photo has
// neither. Sized to the photo's own as-displayed aspect ratio the same way
// (width/height read at send time, see _probeImageSize in chat_screen.dart
// — NOT derived from the CachedNetworkImage/Image.file widget itself, for
// the same before/after-upload stability reason as video), falling back to
// a fixed square when unknown (probe failed, or an older message sent
// before this field existed).
class ImageMessageBubble extends StatelessWidget {
  static const double _minSide = 120;
  static const double _maxWidth = 260;
  static const double _maxHeight = 340;
  static const double _fallbackSide = 200;

  final String? imageURL;
  final String? localFilePath;
  final int? imageWidth;
  final int? imageHeight;
  final double bubbleRadius;
  final Widget timeCheckmarkOverlay;
  final VoidCallback? onTap;
  // Single computed source of truth (see deliveryStatusFor) — the same
  // value the corner checkmark is derived from, so this widget's own
  // uploading-vs-sent decision can never visibly disagree with it.
  final MessageDeliveryStatus deliveryStatus;
  final double? localUploadProgress;
  final VoidCallback? onCancelUpload;
  // See Message.stableMediaKey — warms/looks up ImagePreviewCacheManager so
  // the pending-phase local file's bytes can seamlessly stand in for
  // CachedNetworkImage's own placeholder the moment this message's source
  // swaps to its uploaded URL (see _PendingImagePreview below).
  final String? cacheKey;
  // See _PendingImagePreview.initialBytes.
  final Uint8List? initialBytes;
  // Optional caption (Message.text) shown below the photo, same as
  // WhatsApp/Telegram — when present, the corner time/checkmark overlay
  // moves off the photo and becomes a trailing element after the caption
  // text instead (matches how a plain text bubble already places it),
  // so it never sits on top of unrelated caption text.
  final String caption;
  final bool isMe;

  const ImageMessageBubble({
    super.key,
    this.imageURL,
    this.localFilePath,
    this.imageWidth,
    this.imageHeight,
    required this.bubbleRadius,
    required this.timeCheckmarkOverlay,
    this.onTap,
    required this.deliveryStatus,
    this.localUploadProgress,
    this.onCancelUpload,
    this.cacheKey,
    this.initialBytes,
    this.caption = '',
    required this.isMe,
  });

  Size _boundedSize() {
    final w0 = imageWidth;
    final h0 = imageHeight;
    if (w0 == null || h0 == null || w0 <= 0 || h0 <= 0) {
      return const Size(_fallbackSide, _fallbackSide);
    }
    final ratio = w0 / h0;
    var w = _maxWidth;
    var h = w / ratio;
    if (h > _maxHeight) {
      h = _maxHeight;
      w = h * ratio;
    }
    if (h < _minSide) {
      h = _minSide;
      w = h * ratio;
    }
    if (w < _minSide) {
      w = _minSide;
      h = w / ratio;
    }
    // Re-clamp in case the min-side correction above pushed the other
    // dimension back past its own max (very thin/wide aspect ratios).
    if (w > _maxWidth) {
      w = _maxWidth;
      h = w / ratio;
    }
    if (h > _maxHeight) {
      h = _maxHeight;
      w = h * ratio;
    }
    return Size(w, h);
  }

  @override
  Widget build(BuildContext context) {
    final size = _boundedSize();
    final hasCaption = caption.trim().isNotEmpty;

    final imageStack = ClipRRect(
      borderRadius: hasCaption
          ? BorderRadius.only(
              topLeft: Radius.circular(bubbleRadius),
              topRight: Radius.circular(bubbleRadius),
            )
          : BorderRadius.circular(bubbleRadius),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: kBg3),
            localFilePath != null
                ? _PendingImagePreview(
                    path: localFilePath!,
                    cacheKey: cacheKey,
                    initialBytes: initialBytes,
                  )
                : CachedNetworkImage(
                    imageUrl: imageURL!,
                    fit: BoxFit.cover,
                    placeholder: (ctx, url) {
                      final cached = cacheKey != null
                          ? ImagePreviewCacheManager.instance.get(cacheKey!)
                          : null;
                      return cached != null
                          ? Image.memory(cached, fit: BoxFit.cover)
                          : const Center(
                              child: CircularProgressIndicator(color: kGold),
                            );
                    },
                    errorWidget: (ctx, url, err) => Container(
                      color: kBg3,
                      child: const Icon(Icons.broken_image, color: kMuted),
                    ),
                  ),
            if (deliveryStatus == MessageDeliveryStatus.queued ||
                deliveryStatus == MessageDeliveryStatus.uploading)
              UploadProgressOverlay(
                progress: deliveryStatus == MessageDeliveryStatus.uploading
                    ? localUploadProgress
                    : null,
                onCancel: onCancelUpload,
              ),
            if (!hasCaption)
              Positioned(
                right: 8,
                bottom: 8,
                child: MediaOverlayChip(child: timeCheckmarkOverlay),
              ),
          ],
        ),
      ),
    );

    if (!hasCaption) {
      return GestureDetector(onTap: onTap, child: imageStack);
    }

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(bubbleRadius),
        child: Container(
          width: size.width,
          color: isMe ? kGold : kBg3,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              imageStack,
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        caption,
                        style: TextStyle(
                          color: isMe
                              ? const Color(0xFF1A0E00)
                              : kText,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    timeCheckmarkOverlay,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Renders a pending (not-yet-uploaded) photo's local file exactly like a
// plain Image.file — the only difference is a one-time side effect: it
// reads the file's bytes into ImagePreviewCacheManager under cacheKey so
// they're already in memory (not at risk of the local file having been
// deleted, see PendingMessageQueueController._removeInternal) by the time
// this message's ImageMessageBubble swaps to CachedNetworkImage and needs
// a placeholder for its first, not-yet-cached fetch of the uploaded URL.
class _PendingImagePreview extends StatefulWidget {
  final String path;
  final String? cacheKey;
  // Already-decoded bytes for this exact photo, captured before this
  // message was ever enqueued and already precached into Flutter's
  // ImageCache (see chat_screen.dart's _uploadAndSendImageFile) — lets the
  // very first build paint the real photo immediately via Image.memory
  // instead of Image.file's own fresh decode gap. Null for a pending item
  // resumed after an app restart (this is never persisted), which falls
  // back to the previous Image.file + async warm-up behavior.
  final Uint8List? initialBytes;

  const _PendingImagePreview({
    required this.path,
    this.cacheKey,
    this.initialBytes,
  });

  @override
  State<_PendingImagePreview> createState() => _PendingImagePreviewState();
}

class _PendingImagePreviewState extends State<_PendingImagePreview> {
  @override
  void initState() {
    super.initState();
    final initial = widget.initialBytes;
    final key = widget.cacheKey;
    if (initial != null && key != null) {
      ImagePreviewCacheManager.instance.put(key, initial);
    } else {
      _warmCache();
    }
  }

  @override
  void didUpdateWidget(_PendingImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path && widget.initialBytes == null) {
      _warmCache();
    }
  }

  Future<void> _warmCache() async {
    final key = widget.cacheKey;
    if (key == null) return;
    if (ImagePreviewCacheManager.instance.get(key) != null) return;
    try {
      final bytes = await File(widget.path).readAsBytes();
      if (!mounted) return;
      ImagePreviewCacheManager.instance.put(key, bytes);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.initialBytes;
    return initial != null
        ? Image.memory(initial, fit: BoxFit.cover)
        : Image.file(File(widget.path), fit: BoxFit.cover);
  }
}

// Small translucent dark backdrop so white overlay text/icons stay legible
// over arbitrary video content, whatever its own colors happen to be.
class MediaOverlayChip extends StatelessWidget {
  final Widget child;
  const MediaOverlayChip({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(110),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

// WhatsApp-style upload-progress indicator, centered over a photo/video
// bubble while it's queued/uploading — replaces the old small corner clock
// icon (which only signaled "sending", not how far along it was) as the
// primary "this is still going" cue for media specifically. progress is the
// real Storage bytesTransferred/totalBytes fraction (see
// PendingMediaMessage.uploadProgress) — null (e.g. still queued, hasn't
// started uploading yet) falls back to CircularProgressIndicator's own
// indeterminate spin rather than a fake 0% ring. Tapping the square button
// cancels the upload via onCancel (wired to the same offline-queue
// remove() already used by the "Sil" option on a pending message).
class UploadProgressOverlay extends StatelessWidget {
  final double? progress;
  final VoidCallback? onCancel;

  const UploadProgressOverlay({super.key, this.progress, this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withAlpha(90),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 3,
                backgroundColor: Colors.white.withAlpha(70),
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            GestureDetector(
              onTap: onCancel,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Minimal custom-controls full-screen playback, matching the app's existing
// pattern of building lightweight custom UI over a media package (e.g. the
// voice-message player over just_audio) rather than pulling in a full
// player-UI package.
class VideoPlayerScreen extends ConsumerStatefulWidget {
  final String? videoURL;
  final String? localFilePath;
  final Message message;
  final String chatId;
  final String currentUid;
  final String chatName;
  final String senderName;

  const VideoPlayerScreen({
    super.key,
    this.videoURL,
    this.localFilePath,
    required this.message,
    required this.chatId,
    required this.currentUid,
    required this.chatName,
    required this.senderName,
  });

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen> {
  Future<void> _shareVideo() async {
    try {
      final localPath = widget.localFilePath;
      final XFile file;
      if (localPath != null) {
        file = XFile(localPath);
      } else {
        final url = widget.videoURL;
        if (url == null) return;
        final cached = await DefaultCacheManager().getSingleFile(url);
        final bytes = await cached.readAsBytes();
        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/share_${widget.message.id}.mp4';
        await File(path).writeAsBytes(bytes);
        file = XFile(path);
      }
      await SharePlus.instance.share(ShareParams(files: [file]));
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'VideoPlayerScreen: share failed',
      );
    }
  }

  void _openForward() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg2,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ForwardSheet(
        messages: [widget.message],
        sourceChatId: widget.chatId,
        currentUid: widget.currentUid,
        onDone: () {},
      ),
    );
  }

  Future<void> _toggleFavorite(bool isStarred) async {
    final service = ref.read(firestoreServiceProvider);
    if (isStarred) {
      await service.unstarMessage(
        uid: widget.currentUid,
        messageId: widget.message.id,
      );
    } else {
      await service.starMessage(
        uid: widget.currentUid,
        chatId: widget.chatId,
        chatName: widget.chatName,
        senderName: widget.senderName,
        message: widget.message,
      );
    }
  }

  void _confirmDelete() {
    final isMe = widget.message.senderId == widget.currentUid;
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
                          messageId: widget.message.id,
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
                        messageId: widget.message.id,
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

  @override
  Widget build(BuildContext context) {
    final starredAsync = ref.watch(starredMessagesProvider(widget.currentUid));
    final isStarred =
        starredAsync.value?.any((m) => m.id == widget.message.id) ?? false;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            VideoPlaybackCore(
              videoURL: widget.videoURL,
              localFilePath: widget.localFilePath,
              bottomChromeHeight: 56.0,
            ),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            // Not gated on VideoPlaybackCore's own init/error state the way
            // the old combined scrub-bar+icon-row block was — none of these
            // actions (share/forward/favorite/delete) touch playback, so
            // there's no reason to hide them while the video is still
            // loading.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.ios_share, color: Colors.white),
                      onPressed: _shareVideo,
                    ),
                    IconButton(
                      icon: const Icon(Icons.reply, color: Colors.white),
                      onPressed: _openForward,
                    ),
                    IconButton(
                      icon: Icon(
                        isStarred ? Icons.star : Icons.star_border,
                        color: isStarred ? kGold : Colors.white,
                      ),
                      onPressed: () => _toggleFavorite(isStarred),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.white,
                      ),
                      onPressed: _confirmDelete,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Playback-only core (video surface, tap-to-toggle-play overlay, scrub bar)
// with no message/chat/user coupling — VideoPlayerScreen above is now a
// thin chrome wrapper around this, and a future shared attachment-viewer
// container can host this widget directly instead of duplicating the
// controller lifecycle / scrub-throttling logic.
class VideoPlaybackCore extends ConsumerStatefulWidget {
  final String? videoURL;
  final String? localFilePath;
  // How much space the host reserves below this widget for its own bottom
  // chrome (e.g. VideoPlayerScreen's share/forward/favorite/delete icon
  // row) — the scrub bar is inset from the bottom by this amount so it
  // doesn't render underneath that chrome. Caller-supplied rather than
  // baked in, since different hosts (e.g. a future attachment-viewer
  // container) may reserve a different height or none at all.
  final double bottomChromeHeight;

  const VideoPlaybackCore({
    super.key,
    this.videoURL,
    this.localFilePath,
    required this.bottomChromeHeight,
  });

  @override
  ConsumerState<VideoPlaybackCore> createState() => _VideoPlaybackCoreState();
}

class _VideoPlaybackCoreState extends ConsumerState<VideoPlaybackCore> {
  // Nullable — building the controller now takes an async cache-lookup step
  // before it exists, so a fast back-navigation can dispose this screen
  // before _setup() ever assigns one. _disposed guards every await
  // resumption in _setup() so it never touches state (or leaks a controller
  // nothing will ever dispose) after that happens.
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _disposed = false;
  bool _wasPlaying = false;
  String? _error;
  bool _scrubbing = false;
  int? _scrubPositionMs;
  DateTime? _lastScrubSeekAt;
  bool _seekInFlight = false;

  @override
  void initState() {
    super.initState();
    // Pause any playing voice message before this screen's own AVPlayer
    // activates — two audio sessions (just_audio for voice, video_player's
    // AVPlayer for this) fighting over the shared iOS AVAudioSession was
    // the suspected cause of a real, watchdog-confirmed main-thread hang
    // reproduced by scrubbing the video progress bar right after opening
    // a video message.
    VoiceMessageCoordinator.instance.pauseActive();
    _setup();
  }

  Future<void> _setup() async {
    final localPath = widget.localFilePath;
    VideoPlayerController controller;
    if (localPath != null) {
      controller = VideoPlayerController.file(File(localPath));
    } else {
      final url = widget.videoURL!;
      unawaited(_cacheVideoInBackground(url));
      final cached = await VideoCacheManager.instance.getFileFromCache(url);
      if (_disposed) return;
      controller = cached != null
          ? VideoPlayerController.file(cached.file)
          : VideoPlayerController.networkUrl(Uri.parse(url));
    }
    if (_disposed) {
      controller.dispose();
      return;
    }
    setState(() => _controller = controller);
    controller.addListener(_onControllerTick);
    try {
      await controller.initialize();
      if (_disposed) return;
      setState(() => _initialized = true);
      controller.play();
    } catch (e, st) {
      if (!_disposed) setState(() => _error = 'Video açıla bilmədi: $e');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'VideoPlaybackCore: controller.initialize() failed',
      );
    }
  }

  // video_player never sends AVAudioSession the explicit "I'm done" signal
  // that lets iOS un-duck other apps' audio — it only engages ducking as a
  // side effect of actually outputting sound. Watching for isPlaying's
  // true->false edge here catches pause, natural end-of-video, and (via
  // dispose below) navigating away mid-playback — all the ways playback
  // can stop short of the app itself being backgrounded, which is the only
  // thing that was incidentally clearing the ducked state before this.
  void _onControllerTick() {
    final isPlaying = _controller?.value.isPlaying ?? false;
    if (_wasPlaying && !isPlaying) {
      unawaited(_deactivateAudioSession());
    }
    _wasPlaying = isPlaying;
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.removeListener(_onControllerTick);
    _controller?.dispose();
    if (_wasPlaying) unawaited(_deactivateAudioSession());
    super.dispose();
  }

  Future<void> _performSeek(int ms) async {
    if (_disposed || _controller == null) return;
    _seekInFlight = true;
    try {
      await _controller!.seekTo(Duration(milliseconds: ms));
    } catch (e, st) {
      if (!_disposed) {
        FirebaseCrashlytics.instance.recordError(
          e, st, reason: 'VideoPlaybackCore: seekTo failed during scrub',
        );
      }
    } finally {
      _seekInFlight = false;
    }
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      // Forces this Stack to size to all the space its parent gives it
      // (constraints.biggest) regardless of the video's own AspectRatio-
      // driven size — needed since this widget is nested one level inside
      // the host screen's own Stack rather than sitting directly under
      // Scaffold/SafeArea's tight constraints; without it, a non-full-
      // bleed video (letterboxed) would shrink this Stack down to the
      // video's own frame, and the scrub bar's Positioned(bottom: ...)
      // below would anchor to the bottom of that frame instead of the
      // actual screen bottom.
      fit: StackFit.expand,
      children: [
        if (_error != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          )
        else if (!_initialized)
          const Center(child: CircularProgressIndicator(color: kGold))
        else
          AnimatedBuilder(
            animation: _controller!,
            builder: (context, _) => Center(
              child: GestureDetector(
                onTap: _togglePlay,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: _controller!.value.aspectRatio,
                      child: VideoPlayer(_controller!),
                    ),
                    AnimatedOpacity(
                      opacity: _controller!.value.isPlaying ? 0 : 1,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black45,
                        ),
                        padding: const EdgeInsets.all(16),
                        child: const Icon(
                          Icons.play_arrow,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_initialized)
          Positioned(
            left: 0,
            right: 0,
            bottom: widget.bottomChromeHeight,
            child: AnimatedBuilder(
              animation: _controller!,
              builder: (context, _) {
                final position = _controller!.value.position;
                final duration = _controller!.value.duration;
                // Custom scrub bar replacing VideoProgressIndicator's
                // built-in allowScrubbing — that widget calls
                // controller.seekTo() on every single drag-update
                // tick with no throttling, which is expensive
                // enough per-call (real decode-to-frame work) that
                // debug-mode's extra overhead queued them up into
                // a full main-thread hang on-device (confirmed:
                // release mode doesn't hang, debug mode does).
                // This bar throttles real seekTo() calls to at
                // most once per 100ms during an active drag, with
                // one final precise seekTo() on release. The bar
                // and time labels show _scrubPositionMs (not the
                // controller's own lagging position) while
                // scrubbing, so the UI tracks the finger exactly
                // even though real seeks are throttled.
                final displayPositionMs = _scrubbing
                    ? (_scrubPositionMs ?? position.inMilliseconds)
                    : position.inMilliseconds;
                final displayRemaining = duration -
                    Duration(milliseconds: displayPositionMs);
                final durationMs = duration.inMilliseconds;
                final bufferedRanges = _controller!.value.buffered;
                final bufferedMs = bufferedRanges.isNotEmpty
                    ? bufferedRanges.last.end.inMilliseconds
                    : 0;
                final playedFraction = durationMs > 0
                    ? (displayPositionMs / durationMs).clamp(0.0, 1.0)
                    : 0.0;
                final bufferedFraction = durationMs > 0
                    ? (bufferedMs / durationMs).clamp(0.0, 1.0)
                    : 0.0;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: LayoutBuilder(
                        builder: (barContext, constraints) {
                          final trackWidth = constraints.maxWidth;
                          void seekToLocalDx(double dx) {
                            final newMs = (dx / trackWidth * durationMs)
                                .round()
                                .clamp(0, durationMs);
                            setState(() => _scrubPositionMs = newMs);
                            final now = DateTime.now();
                            if (!_seekInFlight &&
                                (_lastScrubSeekAt == null ||
                                    now.difference(_lastScrubSeekAt!) >
                                        const Duration(
                                            milliseconds: 100))) {
                              _lastScrubSeekAt = now;
                              unawaited(_performSeek(newMs));
                            }
                          }

                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragStart: (details) {
                              setState(() {
                                _scrubbing = true;
                                _scrubPositionMs =
                                    position.inMilliseconds;
                              });
                            },
                            onHorizontalDragUpdate: (details) {
                              if (_disposed) return;
                              final box = barContext.findRenderObject()
                                  as RenderBox;
                              final local = box.globalToLocal(
                                details.globalPosition,
                              );
                              seekToLocalDx(local.dx);
                            },
                            onHorizontalDragEnd: (details) {
                              if (_disposed || _controller == null) {
                                return;
                              }
                              final finalMs = _scrubPositionMs ??
                                  position.inMilliseconds;
                              unawaited(_performSeek(finalMs));
                              setState(() => _scrubbing = false);
                            },
                            child: SizedBox(
                              height: 12,
                              child: Stack(
                                alignment: Alignment.centerLeft,
                                children: [
                                  Container(
                                    height: 3,
                                    decoration: BoxDecoration(
                                      color: Colors.white12,
                                      borderRadius:
                                          BorderRadius.circular(2),
                                    ),
                                  ),
                                  FractionallySizedBox(
                                    widthFactor: bufferedFraction,
                                    child: Container(
                                      height: 3,
                                      decoration: BoxDecoration(
                                        color: Colors.white38,
                                        borderRadius:
                                            BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                  FractionallySizedBox(
                                    widthFactor: playedFraction,
                                    child: Container(
                                      height: 3,
                                      decoration: BoxDecoration(
                                        color: kGold,
                                        borderRadius:
                                            BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      child: Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatDurationMmSs(displayPositionMs),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '-${formatDurationMmSs(displayRemaining.inMilliseconds)}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}
