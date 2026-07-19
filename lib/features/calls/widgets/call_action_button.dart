import 'package:flutter/material.dart';
import '../../../core/theme/colors.dart';

class CallActionButton extends StatelessWidget {
  final Color color;
  final IconData icon;
  final VoidCallback? onPressed;

  const CallActionButton({
    super.key,
    required this.color,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final bg = onPressed == null ? color.withValues(alpha: 0.4) : color;
    // Icon color adapts to background contrast — white icon on a white
    // background (the "active" state for camera/speaker toggles) was
    // invisible, confirmed live during testing. Every other button color
    // in this app (kRed, kGreen, kBg3) is dark enough for a white icon.
    final iconColor = color == Colors.white ? kBg : Colors.white;
    return Material(
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Icon(icon, color: iconColor, size: 30),
        ),
      ),
    );
  }
}
