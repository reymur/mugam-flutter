import 'package:flutter/material.dart';

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
    return Material(
      color: onPressed == null ? color.withValues(alpha: 0.4) : color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Icon(icon, color: Colors.white, size: 30),
        ),
      ),
    );
  }
}
