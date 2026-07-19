import 'package:flutter/material.dart';
import '../../../core/theme/colors.dart';

class CallTopBar extends StatelessWidget {
  final Widget titleContent;
  final VoidCallback onMinimize;
  final VoidCallback onAddParticipant;
  final VoidCallback onChat;

  const CallTopBar({
    super.key,
    required this.titleContent,
    required this.onMinimize,
    required this.onAddParticipant,
    required this.onChat,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CallTopIconButton(icon: Icons.close_fullscreen, onPressed: onMinimize),
            Expanded(child: titleContent),
            Column(
              children: [
                _CallTopIconButton(icon: Icons.person_add_alt_1, onPressed: onAddParticipant),
                const SizedBox(height: 10),
                _CallTopIconButton(icon: Icons.chat_bubble_outline, onPressed: onChat),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CallTopIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  const _CallTopIconButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kBg2.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(width: 40, height: 40, child: Icon(icon, color: kText, size: 20)),
      ),
    );
  }
}
