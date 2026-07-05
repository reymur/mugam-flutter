import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../../core/theme/colors.dart';

// In-memory only — good enough to avoid regenerating a thumbnail every time
// a message scrolls back into view within the same session.
final Map<String, Uint8List> _thumbnailCache = {};

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

  const VideoThumbnailImage({
    super.key,
    this.videoURL,
    this.localFilePath,
    this.size,
  });

  @override
  State<VideoThumbnailImage> createState() => _VideoThumbnailImageState();
}

class _VideoThumbnailImageState extends State<VideoThumbnailImage> {
  Uint8List? _thumb;

  String get _source => widget.localFilePath ?? widget.videoURL ?? '';

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  @override
  void didUpdateWidget(VideoThumbnailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A message's videoURL can change under an already-mounted bubble (e.g.
    // a queued send's synthetic localFilePath being replaced by the real
    // uploaded URL) — reload instead of leaving a stale/never-resolving
    // thumbnail for the new source.
    final oldSource = oldWidget.localFilePath ?? oldWidget.videoURL ?? '';
    if (oldSource != _source) {
      setState(() => _thumb = null);
      _loadThumb();
    }
  }

  Future<void> _loadThumb() async {
    final source = _source;
    if (source.isEmpty) return;
    final cached = _thumbnailCache[source];
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
      if (data != null) {
        _thumbnailCache[source] = data;
        if (mounted) setState(() => _thumb = data);
      }
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

String _formatDuration(int ms) {
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

  const VideoMessageBubble({
    super.key,
    this.videoURL,
    this.localFilePath,
    this.durationMs,
    this.videoWidth,
    this.videoHeight,
    required this.bubbleRadius,
    required this.timeCheckmarkOverlay,
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
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              VideoPlayerScreen(videoURL: videoURL, localFilePath: localFilePath),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(bubbleRadius),
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoThumbnailImage(videoURL: videoURL, localFilePath: localFilePath),
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
                child: _MediaOverlayChip(
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
                          _formatDuration(durationMs!),
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
              Positioned(
                right: 8,
                bottom: 8,
                child: _MediaOverlayChip(child: timeCheckmarkOverlay),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Small translucent dark backdrop so white overlay text/icons stay legible
// over arbitrary video content, whatever its own colors happen to be.
class _MediaOverlayChip extends StatelessWidget {
  final Widget child;
  const _MediaOverlayChip({required this.child});

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

// Minimal custom-controls full-screen playback, matching the app's existing
// pattern of building lightweight custom UI over a media package (e.g. the
// voice-message player over just_audio) rather than pulling in a full
// player-UI package.
class VideoPlayerScreen extends StatefulWidget {
  final String? videoURL;
  final String? localFilePath;

  const VideoPlayerScreen({super.key, this.videoURL, this.localFilePath});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  // Nullable — building the controller now takes an async cache-lookup step
  // before it exists, so a fast back-navigation can dispose this screen
  // before _setup() ever assigns one. _disposed guards every await
  // resumption in _setup() so it never touches state (or leaks a controller
  // nothing will ever dispose) after that happens.
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _disposed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
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
    try {
      await controller.initialize();
      if (_disposed) return;
      setState(() => _initialized = true);
      controller.play();
    } catch (e) {
      if (!_disposed) setState(() => _error = 'Video açıla bilmədi: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.dispose();
    super.dispose();
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
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
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            if (_initialized)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: VideoProgressIndicator(
                  _controller!,
                  allowScrubbing: true,
                  padding: const EdgeInsets.all(12),
                  colors: const VideoProgressColors(
                    playedColor: kGold,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
