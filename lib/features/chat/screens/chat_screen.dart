import 'package:flutter/material.dart';
import '../../../core/theme/colors.dart';

class ChatScreen extends StatelessWidget {
  final String chatId;
  const ChatScreen({super.key, required this.chatId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        title: const Text('Mugam', style: TextStyle(color: kGold, letterSpacing: 4)),
        iconTheme: const IconThemeData(color: kGold),
      ),
      body: const Center(
        child: Text(
          'Mugam',
          style: TextStyle(
            color: kGold,
            fontSize: 32,
            fontWeight: FontWeight.bold,
            letterSpacing: 4,
          ),
        ),
      ),
    );
  }
}
