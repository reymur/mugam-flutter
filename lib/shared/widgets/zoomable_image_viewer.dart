import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

void showFullImage(BuildContext context, String imageURL) {
  showDialog(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Stack(
          children: [
            ZoomableImage(imageURL: imageURL),
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).pop(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class ZoomableImage extends StatefulWidget {
  final String imageURL;
  // Fires only on an actual zoomed-in/zoomed-out state transition (not on
  // every transform-matrix tick during an active pinch/pan), so a parent
  // wiring this into setState doesn't rebuild on every frame of a zoom
  // gesture. Null by default — every existing call site (StatusViewerScreen,
  // profile_screen.dart's showFullImage, etc.) keeps working with zero
  // behavior change; only a caller that needs to know (e.g. to gate its own
  // competing gesture, like a drag-to-dismiss recognizer, while the user is
  // zoomed in here) opts in by passing this.
  final ValueChanged<bool>? onZoomChanged;

  const ZoomableImage({super.key, required this.imageURL, this.onZoomChanged});

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transformationController =
      TransformationController();
  late final AnimationController _animationController;
  Animation<Matrix4>? _zoomAnimation;
  Offset _doubleTapLocalPosition = Offset.zero;
  bool _isZoomed = false;

  static const double _doubleTapScale = 3.0;
  // 1.01, not 1.0 exactly, to tolerate InteractiveViewer's own
  // floating-point drift back toward (but not exactly) identity scale
  // after a pinch releases — without this slack, onZoomChanged could keep
  // flip-flopping true/false around the resting state.
  static const double _zoomedThreshold = 1.01;

  @override
  void initState() {
    super.initState();
    _animationController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
        )..addListener(() {
          if (_zoomAnimation != null) {
            _transformationController.value = _zoomAnimation!.value;
          }
        });
    _transformationController.addListener(_handleTransformChanged);
  }

  void _handleTransformChanged() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    final nowZoomed = scale > _zoomedThreshold;
    if (nowZoomed == _isZoomed) return;
    _isZoomed = nowZoomed;
    widget.onZoomChanged?.call(nowZoomed);
  }

  @override
  void dispose() {
    _transformationController.removeListener(_handleTransformChanged);
    _animationController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  void _animateTo(Matrix4 end) {
    _zoomAnimation = Matrix4Tween(
      begin: _transformationController.value,
      end: end,
    ).animate(CurveTween(curve: Curves.easeOut).animate(_animationController));
    _animationController.forward(from: 0);
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapLocalPosition = details.localPosition;
  }

  void _handleDoubleTap() {
    final isZoomedIn = _transformationController.value != Matrix4.identity();
    if (isZoomedIn) {
      _animateTo(Matrix4.identity());
      return;
    }
    final position = _doubleTapLocalPosition;
    final zoomed = Matrix4.identity()
      ..translateByDouble(
        -position.dx * (_doubleTapScale - 1),
        -position.dy * (_doubleTapScale - 1),
        0,
        1,
      )
      ..scaleByDouble(_doubleTapScale, _doubleTapScale, _doubleTapScale, 1);
    _animateTo(zoomed);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: _handleDoubleTapDown,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformationController,
        panEnabled: true,
        minScale: 0.5,
        maxScale: 5.0,
        child: Center(
          child: CachedNetworkImage(
            imageUrl: widget.imageURL,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
