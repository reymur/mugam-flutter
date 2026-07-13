import 'package:flutter/material.dart';
import '../../../core/theme/colors.dart';

// WhatsApp-style row of segment bars pinned to the top of
// StatusViewerScreen — one bar per status in the currently-open author's
// group, filled solid for already-shown statuses, animating left-to-right
// for the one currently on screen, empty for ones still to come.
//
// One AnimationController for the currently-active segment only (not one
// per segment up front) — recreated whenever currentIndex or
// segmentDuration changes, following the vsync:this + Tween/
// CurvedAnimation idiom already used by chat_screen.dart's
// _pulseController/_snapController.
class StatusProgressBar extends StatefulWidget {
  final int segmentCount;
  final int currentIndex;
  // The caller is responsible for passing the right value here — the
  // fixed text/image constant, or (once known) the real video duration
  // for a video segment. This widget has no opinion on status type.
  final Duration segmentDuration;
  final bool paused;
  final VoidCallback onSegmentComplete;

  const StatusProgressBar({
    super.key,
    required this.segmentCount,
    required this.currentIndex,
    required this.segmentDuration,
    required this.paused,
    required this.onSegmentComplete,
  });

  @override
  State<StatusProgressBar> createState() => _StatusProgressBarState();
}

class _StatusProgressBarState extends State<StatusProgressBar>
    with TickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
    if (!widget.paused) _controller.forward();
  }

  AnimationController _buildController() {
    final controller = AnimationController(
      vsync: this,
      duration: widget.segmentDuration,
    );
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onSegmentComplete();
      }
    });
    return controller;
  }

  @override
  void didUpdateWidget(StatusProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final segmentChanged =
        widget.currentIndex != oldWidget.currentIndex ||
        widget.segmentDuration != oldWidget.segmentDuration;
    if (segmentChanged) {
      _controller.dispose();
      _controller = _buildController();
      if (!widget.paused) _controller.forward();
      return;
    }
    if (widget.paused != oldWidget.paused) {
      if (widget.paused) {
        _controller.stop();
      } else {
        _controller.forward();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          children: [
            for (var i = 0; i < widget.segmentCount; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: _Segment(
                  fraction: i < widget.currentIndex
                      ? 1.0
                      : i > widget.currentIndex
                      ? 0.0
                      : _controller.value,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Segment extends StatelessWidget {
  final double fraction;

  const _Segment({required this.fraction});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Stack(
        children: [
          Container(height: 2.5, color: Colors.white24),
          FractionallySizedBox(
            widthFactor: fraction.clamp(0.0, 1.0),
            child: Container(height: 2.5, color: kGold),
          ),
        ],
      ),
    );
  }
}
