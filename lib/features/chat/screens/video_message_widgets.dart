import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../../core/theme/colors.dart';

// In-memory only — good enough to avoid regenerating a thumbnail every time
// a message scrolls back into view within the same session.
final Map<String, Uint8List> _thumbnailCache = {};

// Plain thumbnail frame, no tap handler and no play icon — used both by the
// full-size chat bubble (wrapped with a play icon by VideoMessageBubble) and
// by the small quote-card previews, which don't need a play affordance.
// VideoThumbnail.thumbnailData's `video` param accepts either a network URL
// or a local file path, so a not-yet-uploaded pending video's thumbnail
// renders exactly the same way as a sent one.
class VideoThumbnailImage extends StatefulWidget {
  final String? videoURL;
  final String? localFilePath;
  final double size;

  const VideoThumbnailImage({
    super.key,
    this.videoURL,
    this.localFilePath,
    required this.size,
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

// Full chat-bubble video message: thumbnail + play icon, tap opens playback.
// Works identically for an already-sent video (videoURL) or one still
// queued/uploading (localFilePath) — tapping either previews the video, a
// message doesn't have to finish sending before it can be watched.
class VideoMessageBubble extends StatelessWidget {
  final String? videoURL;
  final String? localFilePath;

  const VideoMessageBubble({super.key, this.videoURL, this.localFilePath});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              VideoPlayerScreen(videoURL: videoURL, localFilePath: localFilePath),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 200,
          height: 200,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoThumbnailImage(
                videoURL: videoURL,
                localFilePath: localFilePath,
                size: 200,
              ),
              Center(
                child: Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black45,
                  ),
                  padding: const EdgeInsets.all(12),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 32,
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
  late final VideoPlayerController _controller;
  bool _initialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final localPath = widget.localFilePath;
    _controller = localPath != null
        ? VideoPlayerController.file(File(localPath))
        : VideoPlayerController.networkUrl(Uri.parse(widget.videoURL!));
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() => _initialized = true);
          _controller.play();
        })
        .catchError((e) {
          if (mounted) setState(() => _error = 'Video açıla bilmədi: $e');
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
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
                animation: _controller,
                builder: (context, _) => Center(
                  child: GestureDetector(
                    onTap: _togglePlay,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AspectRatio(
                          aspectRatio: _controller.value.aspectRatio,
                          child: VideoPlayer(_controller),
                        ),
                        AnimatedOpacity(
                          opacity: _controller.value.isPlaying ? 0 : 1,
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
                  _controller,
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
