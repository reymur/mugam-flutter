import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  const ChatScreen({super.key, required this.chatId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _sending = false;
  bool _uploadingImage = false;
  final ImagePicker _picker = ImagePicker();

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending) return;
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    setState(() => _sending = true);
    _messageController.clear();
    try {
      await ref
          .read(firestoreServiceProvider)
          .sendMessage(chatId: widget.chatId, senderId: currentUid, text: text);
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    Navigator.of(context).pop(); // close bottom sheet
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 70,
      maxWidth: 1200,
    );
    if (picked == null) return;
    if (!mounted) return;
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    setState(() => _uploadingImage = true);
    try {
      final imageURL = await ref
          .read(firestoreServiceProvider)
          .uploadChatImage(chatId: widget.chatId, filePath: picked.path);
      await ref
          .read(firestoreServiceProvider)
          .sendImageMessage(
            chatId: widget.chatId,
            senderId: currentUid,
            imageURL: imageURL,
          );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Şəkil göndərilmədi: $e'),
            backgroundColor: kRed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  void _showAttachSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library, color: kGold),
              title: const Text('Qalereya', style: TextStyle(color: kText)),
              onTap: () => _pickAndSendImage(ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: kGold),
              title: const Text('Kamera', style: TextStyle(color: kText)),
              onTap: () => _pickAndSendImage(ImageSource.camera),
            ),
          ],
        ),
      ),
    );
  }

  void _showFullImage(BuildContext context, String imageURL) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: SizedBox.expand(
          child: Stack(
            children: [
              InteractiveViewer(
                panEnabled: true,
                minScale: 0.5,
                maxScale: 5.0,
                child: Center(
                  child: CachedNetworkImage(imageUrl: imageURL, fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: 40,
                right: 16,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(Message msg, String currentUid) {
    final isMe = msg.senderId == currentUid;
    final time = msg.timestamp != null
        ? DateFormat('HH:mm').format(msg.timestamp!.toDate())
        : '';
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          top: 4,
          bottom: 4,
          left: isMe ? 60 : 0,
          right: isMe ? 0 : 60,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isMe ? kGold : kBg3,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isMe ? 18 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (msg.type == 'text')
              Text(
                msg.text,
                style: TextStyle(
                  color: isMe ? const Color(0xFF1A0E00) : kText,
                  fontSize: 14,
                ),
              ),
            if (msg.type == 'image' && msg.imageURL != null)
              GestureDetector(
                onTap: () => _showFullImage(context, msg.imageURL!),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedNetworkImage(
                    imageUrl: msg.imageURL!,
                    width: 200,
                    height: 200,
                    fit: BoxFit.cover,
                    placeholder: (ctx, url) => Container(
                      width: 200,
                      height: 200,
                      color: kBg3,
                      child: const Center(
                        child: CircularProgressIndicator(color: kGold),
                      ),
                    ),
                    errorWidget: (ctx, url, err) => Container(
                      width: 200,
                      height: 200,
                      color: kBg3,
                      child: const Icon(Icons.broken_image, color: kMuted),
                    ),
                  ),
                ),
              ),
            if (msg.type == 'audio')
              Text(
                '🎤 Səs mesajı',
                style: TextStyle(
                  color: isMe ? const Color(0xFF1A0E00) : kMuted,
                  fontSize: 14,
                ),
              ),
            const SizedBox(height: 2),
            Text(
              time,
              style: TextStyle(
                color: isMe ? const Color(0xFF1A0E00).withAlpha(150) : kMuted,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final chatDataAsync = ref.watch(chatDataProvider(widget.chatId));

    ref.listen(messagesProvider(widget.chatId), (previous, next) {
      next.whenData((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });
      });
    });

    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg2,
        elevation: 0,
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
        title: chatDataAsync.when(
          data: (data) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                data?['name'] ?? 'Chat',
                style: GoogleFonts.playfairDisplay(fontSize: 16, color: kText),
              ),
              if (data?['isGroup'] == false)
                Text(
                  data?['online'] == true ? '● Onlayn' : '○ Oflayn',
                  style: TextStyle(
                    fontSize: 11,
                    color: data?['online'] == true
                        ? const Color(0xFF4CAF50)
                        : kMuted,
                  ),
                ),
            ],
          ),
          loading: () => const Text('...', style: TextStyle(color: kText)),
          error: (_, _) => const Text('Chat', style: TextStyle(color: kText)),
        ),
      ),
      backgroundColor: kBg,
      body: Column(
        children: [
          Expanded(
            child: ref
                .watch(messagesProvider(widget.chatId))
                .when(
                  loading: () => const Center(
                    child: CircularProgressIndicator(color: kGold),
                  ),
                  error: (err, stack) => const Center(
                    child: Text('Xəta', style: TextStyle(color: kMuted)),
                  ),
                  data: (messages) => ListView.builder(
                    controller: _scrollController,
                    reverse: false,
                    itemCount: messages.length,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemBuilder: (ctx, i) =>
                        _buildMessageBubble(messages[i], currentUid),
                  ),
                ),
          ),
          Container(
            color: kBg2,
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 24),
            child: Row(
              children: [
                IconButton(
                  icon: _uploadingImage
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: kGold,
                          ),
                        )
                      : const Icon(Icons.attach_file, color: kGold),
                  onPressed: _uploadingImage ? null : _showAttachSheet,
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    style: const TextStyle(color: kText, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Mesaj yazın...',
                      hintStyle: const TextStyle(color: kMuted),
                      filled: true,
                      fillColor: kBg3,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    maxLines: null,
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _sendMessage,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: kGold,
                      shape: BoxShape.circle,
                    ),
                    child: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF1A0E00),
                            ),
                          )
                        : const Icon(
                            Icons.send,
                            color: Color(0xFF1A0E00),
                            size: 20,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
