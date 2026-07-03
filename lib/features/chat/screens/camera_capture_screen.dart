import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/theme/colors.dart';

class CapturedMedia {
  final String path;
  final bool isVideo;
  const CapturedMedia({required this.path, required this.isVideo});
}

enum _CameraMode { video, photo }

const List<double> _zoomSteps = [1.0, 2.0, 3.0];

// WhatsApp-style camera screen: a Video/Photo mode switcher at the bottom
// picks what the single shutter button does (tap = photo in Photo mode,
// tap = start/stop recording in Video mode). Returns the captured file via
// Navigator.pop instead of sending anything itself; the caller decides what
// to do with it.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with SingleTickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  bool _initializing = true;
  bool _isRecordingVideo = false;
  String? _error;
  _CameraMode _mode = _CameraMode.photo;
  FlashMode _flashMode = FlashMode.auto;
  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  final ImagePicker _galleryPicker = ImagePicker();

  // Same recording-timer/pulse pattern as the voice-message recorder.
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  final Stopwatch _recordingStopwatch = Stopwatch();
  Timer? _recordingTimer;
  String _recordingDuration = '0:00';

  bool get _ready =>
      !_initializing && _controller != null && _error == null;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _pulseAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _error = 'Kamera tapılmadı');
        return;
      }
      _cameraIndex = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (_cameraIndex == -1) _cameraIndex = 0;
      await _startController(_cameras[_cameraIndex]);
    } catch (e) {
      if (mounted) setState(() => _error = 'Kamera açıla bilmədi: $e');
    }
  }

  // ResolutionPreset.max is avoided — known to crash on some newer iPhones
  // ("Unsupported pixel format type"). enableAudio is always true (also
  // sidesteps a separate known guard-condition crash when it's false) and
  // is needed for video's audio track anyway.
  Future<void> _startController(CameraDescription description) async {
    final controller = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: true,
    );
    try {
      await controller.initialize();
      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();
      _zoom = _zoom.clamp(_minZoom, _maxZoom);
      await controller.setZoomLevel(_zoom);
      await controller.setFlashMode(_flashMode);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
        _error = null;
      });
    } catch (e) {
      await controller.dispose();
      if (mounted) {
        setState(() {
          _error = 'Kamera açıla bilmədi: $e';
          _initializing = false;
        });
      }
    }
  }

  Future<void> _switchCamera() async {
    if (!_ready || _cameras.length < 2 || _isRecordingVideo) return;
    final oldController = _controller;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    setState(() {
      _controller = null;
      _initializing = true;
    });
    await oldController?.dispose();
    if (!mounted) return;
    await _startController(_cameras[_cameraIndex]);
  }

  Future<void> _cycleZoom() async {
    final controller = _controller;
    if (!_ready || controller == null) return;
    final available = _zoomSteps
        .where((z) => z >= _minZoom && z <= _maxZoom)
        .toList();
    if (available.length < 2) return;
    final currentIndex = available.indexOf(_zoom);
    final next = available[(currentIndex + 1) % available.length];
    await controller.setZoomLevel(next);
    if (mounted) setState(() => _zoom = next);
  }

  Future<void> _cycleFlash() async {
    final controller = _controller;
    if (!_ready || controller == null) return;
    const cycle = [FlashMode.auto, FlashMode.always, FlashMode.off];
    final next = cycle[(cycle.indexOf(_flashMode) + 1) % cycle.length];
    await controller.setFlashMode(next);
    if (mounted) setState(() => _flashMode = next);
  }

  @override
  void dispose() {
    _controller?.dispose();
    _recordingTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (!_ready || controller == null) return;
    if (controller.value.isTakingPicture) return;
    try {
      final file = await controller.takePicture();
      debugPrint('📸 Photo captured: ${file.path}');
      if (mounted) {
        Navigator.of(
          context,
        ).pop(CapturedMedia(path: file.path, isVideo: false));
      }
    } catch (e) {
      debugPrint('📸 Photo capture error: $e');
    }
  }

  Future<void> _startVideoRecording() async {
    final controller = _controller;
    if (!_ready || controller == null) return;
    if (controller.value.isRecordingVideo) return;
    try {
      await controller.startVideoRecording();
      if (mounted) setState(() => _isRecordingVideo = true);
      _pulseController.repeat(reverse: true);
      _recordingStopwatch
        ..reset()
        ..start();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          final s = _recordingStopwatch.elapsed.inSeconds;
          setState(
            () => _recordingDuration =
                '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
          );
        }
      });
    } catch (e) {
      debugPrint('🎥 Start recording error: $e');
    }
  }

  void _resetRecordingIndicators() {
    _pulseController.stop();
    _pulseController.reset();
    _recordingStopwatch.stop();
    _recordingTimer?.cancel();
    _recordingDuration = '0:00';
  }

  Future<void> _stopVideoRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isRecordingVideo) return;
    try {
      final file = await controller.stopVideoRecording();
      if (mounted) {
        setState(() {
          _isRecordingVideo = false;
          _resetRecordingIndicators();
        });
      }
      debugPrint('🎥 Video captured: ${file.path}');
      if (mounted) {
        Navigator.of(
          context,
        ).pop(CapturedMedia(path: file.path, isVideo: true));
      }
    } catch (e) {
      debugPrint('🎥 Stop recording error: $e');
      if (mounted) {
        setState(() {
          _isRecordingVideo = false;
          _resetRecordingIndicators();
        });
      }
    }
  }

  void _onShutterTap() {
    if (!_ready) return;
    if (_mode == _CameraMode.photo) {
      _takePhoto();
    } else if (_isRecordingVideo) {
      _stopVideoRecording();
    } else {
      _startVideoRecording();
    }
  }

  void _setMode(_CameraMode mode) {
    if (_isRecordingVideo) return;
    setState(() => _mode = mode);
  }

  Future<void> _pickFromGallery() async {
    if (_isRecordingVideo) return;
    try {
      final picked = await _galleryPicker.pickMedia();
      if (picked == null) return;
      final isVideo = _isVideoPath(picked.path);
      debugPrint(
        isVideo
            ? '🎥 Gallery video selected: ${picked.path}'
            : '📸 Gallery photo selected: ${picked.path}',
      );
      if (mounted) {
        Navigator.of(
          context,
        ).pop(CapturedMedia(path: picked.path, isVideo: isVideo));
      }
    } catch (e) {
      debugPrint('Gallery pick error: $e');
    }
  }

  bool _isVideoPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.avi');
  }

  IconData _flashIcon() {
    switch (_flashMode) {
      case FlashMode.always:
      case FlashMode.torch:
        return Icons.flash_on;
      case FlashMode.off:
        return Icons.flash_off;
      case FlashMode.auto:
        return Icons.flash_auto;
    }
  }

  void _showAspectRatioStub() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Tezliklə əlavə olunacaq'),
        backgroundColor: kBg3,
      ),
    );
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
            else if (!_ready)
              const Center(child: CircularProgressIndicator(color: kGold))
            else
              Positioned.fill(child: CameraPreview(_controller!)),

            // Top bar: close, aspect-ratio (stub), flash.
            Positioned(
              top: 4,
              left: 4,
              right: 4,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _RoundIconButton(
                    icon: Icons.close,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  Row(
                    children: [
                      _RoundIconButton(
                        icon: Icons.aspect_ratio,
                        onTap: _showAspectRatioStub,
                      ),
                      const SizedBox(width: 8),
                      _RoundIconButton(
                        icon: _flashIcon(),
                        filled: _flashMode != FlashMode.off,
                        onTap: _ready ? _cycleFlash : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            if (_isRecordingVideo)
              Positioned(
                top: 64,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: kRed,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedBuilder(
                          animation: _pulseAnimation,
                          builder: (_, _) => Opacity(
                            opacity: _pulseAnimation.value,
                            child: const Icon(
                              Icons.circle,
                              color: Colors.white,
                              size: 10,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'REC $_recordingDuration',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Bottom controls: gallery, zoom, shutter, flip — then mode switch.
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _RoundIconButton(
                          icon: Icons.photo_library_outlined,
                          onTap: _isRecordingVideo ? null : _pickFromGallery,
                        ),
                        _ZoomButton(
                          zoom: _zoom,
                          enabled: _ready && _zoomSteps.any(
                            (z) => z > _minZoom && z <= _maxZoom,
                          ),
                          onTap: _cycleZoom,
                        ),
                        GestureDetector(
                          onTap: _onShutterTap,
                          child: Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 4,
                              ),
                            ),
                            child: Center(
                              // Standard record-button affordance: a full
                              // white disc normally, shrinking down to a
                              // small rounded red square (stop icon) while
                              // recording — same idea as iOS/Material stop
                              // buttons, instead of a square filling the
                              // whole ring.
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: _isRecordingVideo ? 28 : 60,
                                height: _isRecordingVideo ? 28 : 60,
                                decoration: BoxDecoration(
                                  color: _isRecordingVideo
                                      ? kRed
                                      : (_ready ? Colors.white : Colors.white38),
                                  borderRadius: BorderRadius.circular(
                                    _isRecordingVideo ? 8 : 30,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        _RoundIconButton(
                          icon: Icons.cameraswitch,
                          onTap: (_ready && _cameras.length > 1)
                              ? _switchCamera
                              : null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ModeLabel(
                        label: 'VİDEO',
                        selected: _mode == _CameraMode.video,
                        onTap: () => _setMode(_CameraMode.video),
                      ),
                      const SizedBox(width: 28),
                      _ModeLabel(
                        label: 'ŞƏKİL',
                        selected: _mode == _CameraMode.photo,
                        onTap: () => _setMode(_CameraMode.photo),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;

  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? kGold : Colors.black45,
        ),
        child: Icon(
          icon,
          color: onTap == null
              ? Colors.white30
              : (filled ? const Color(0xFF1A0E00) : Colors.white),
          size: 22,
        ),
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  final double zoom;
  final bool enabled;
  final VoidCallback onTap;

  const _ZoomButton({
    required this.zoom,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black45,
        ),
        alignment: Alignment.center,
        child: Text(
          '${zoom.toStringAsFixed(0)}x',
          style: TextStyle(
            color: enabled ? Colors.white : Colors.white30,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _ModeLabel extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeLabel({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? kGold : Colors.white70,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            fontSize: 13,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
