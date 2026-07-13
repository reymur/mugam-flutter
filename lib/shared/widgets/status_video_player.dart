import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:video_player/video_player.dart';
import '../../core/theme/colors.dart';

// Embeddable video surface for StatusViewerScreen's PageView pages — same
// cache-first setup, disposal-race guards (_disposed), and AVAudioSession
// un-ducking as VideoPlayerScreen (features/chat/screens/
// video_message_widgets.dart), but with all Scaffold/close-button/
// tap-to-play chrome stripped out: the container screen owns every bit of
// UI decoration here, this widget is only the video surface plus its
// native audio-session side effects. VideoPlayerScreen itself is
// deliberately left untouched (still used unmodified for chat media
// attachments) — this is a new, separate widget, not a refactor of it.
//
// Uses its own VideoCacheManager instance rather than importing the one in
// video_message_widgets.dart: shared/ doesn't import from features/
// anywhere else in this codebase (confirmed via search), and this widget
// lives in shared/. The cost is a second on-disk cache store for video
// files instead of one shared store — acceptable for now, revisit if that
// ever actually matters.
class StatusVideoPlayer extends StatefulWidget {
  final String? videoURL;
  final String? localFilePath;
  final VoidCallback? onVideoEnded;
  // Fires exactly once, right after controller.initialize() resolves —
  // the outer progress-bar AnimationController needs the real video
  // duration, not a guessed constant.
  final ValueChanged<Duration>? onDurationKnown;
  // Driven by the outer long-press-to-pause gesture.
  final bool paused;

  const StatusVideoPlayer({
    super.key,
    this.videoURL,
    this.localFilePath,
    this.onVideoEnded,
    this.onDurationKnown,
    this.paused = false,
  });

  @override
  State<StatusVideoPlayer> createState() => _StatusVideoPlayerState();
}

class _StatusVideoPlayerState extends State<StatusVideoPlayer> {
  // Nullable for the same reason as VideoPlayerScreen's _controller — the
  // cache lookup in _setup() is async, so a fast dismiss can dispose this
  // widget before a controller ever gets assigned. _disposed guards every
  // await resumption below.
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _disposed = false;
  bool _wasPlaying = false;
  bool _endedFired = false;
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
    controller.addListener(_onControllerTick);
    try {
      await controller.initialize();
      if (_disposed) return;
      widget.onDurationKnown?.call(controller.value.duration);
      setState(() => _initialized = true);
      if (!widget.paused) controller.play();
    } catch (e, st) {
      if (!_disposed) setState(() => _error = 'Video açıla bilmədi: $e');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'StatusVideoPlayer: controller.initialize() failed',
      );
    }
  }

  // Same isPlaying true->false edge-watching as VideoPlayerScreen's own
  // _onControllerTick, for the same AVAudioSession un-ducking reason (see
  // that widget's comment) — plus this widget's own end-of-video edge,
  // watched the same way (once true, stays true) so onVideoEnded fires
  // exactly once per playthrough instead of on every frame after the
  // video ends.
  void _onControllerTick() {
    final value = _controller?.value;
    if (value == null) return;
    final isPlaying = value.isPlaying;
    if (_wasPlaying && !isPlaying) {
      unawaited(_deactivateAudioSession());
    }
    _wasPlaying = isPlaying;

    if (!_endedFired &&
        value.duration > Duration.zero &&
        value.position >= value.duration) {
      _endedFired = true;
      widget.onVideoEnded?.call();
    }
  }

  @override
  void didUpdateWidget(StatusVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controller = _controller;
    if (controller == null || !_initialized) return;
    if (widget.paused != oldWidget.paused) {
      if (widget.paused) {
        controller.pause();
      } else {
        controller.play();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.removeListener(_onControllerTick);
    _controller?.dispose();
    if (_wasPlaying) unawaited(_deactivateAudioSession());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
    if (!_initialized) {
      return const Center(child: CircularProgressIndicator(color: kGold));
    }
    return Center(
      child: AspectRatio(
        aspectRatio: _controller!.value.aspectRatio,
        child: VideoPlayer(_controller!),
      ),
    );
  }
}

Future<void> _deactivateAudioSession() async {
  try {
    final session = await AudioSession.instance;
    await session.setActive(false);
  } catch (e, st) {
    FirebaseCrashlytics.instance.recordError(
      e,
      st,
      reason: 'status_video_player: _deactivateAudioSession failed',
    );
  }
}

// Separate from both the chat feature's VideoCacheManager and the image
// cache — see this file's own top-of-file comment for why.
class VideoCacheManager {
  static const key = 'mugamStatusVideoCache';
  static final CacheManager instance = CacheManager(
    Config(key, stalePeriod: const Duration(days: 7), maxNrOfCacheObjects: 30),
  );
}

// Playback always starts immediately via network stream — this just warms
// the cache in the background so re-opening the same status later can skip
// the network entirely. Guarded against piling up duplicate downloads if
// the same video is opened/closed several times before the first download
// finishes — same pattern as video_message_widgets.dart's own version.
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
