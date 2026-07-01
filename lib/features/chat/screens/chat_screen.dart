import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/colors.dart';

class ChatScreen extends StatelessWidget {
  final String chatId;
  const ChatScreen({super.key, required this.chatId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg2,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/chats');
            }
          },
        ),
        title: Text('Chat $chatId', style: const TextStyle(color: kText)),
      ),
      backgroundColor: kBg,
      body: const Center(
        child: Text('Chat coming soon...', style: TextStyle(color: kMuted)),
      ),
    );
  }
}
