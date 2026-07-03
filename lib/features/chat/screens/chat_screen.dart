import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:super_clipboard/super_clipboard.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import 'message_info_screen.dart';

enum _SelectionPurpose { forward, delete }

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  const ChatScreen({super.key, required this.chatId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  bool _composerHadFocusBeforeMenu = false;
  final ScrollController _scrollController = ScrollController();
  bool _sending = false;
  bool _uploadingImage = false;
  final ImagePicker _picker = ImagePicker();
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  bool _uploadingAudio = false;
  String? _recordingPath;
  bool _hasText = false;
  final Stopwatch _recordingStopwatch = Stopwatch();
  Timer? _recordingTimer;
  String _recordingDuration = '0:00';
  bool _isLocked = false;
  double _dragX = 0.0;
  double _dragY = 0.0;
  static const double _cancelThreshold = -80.0;
  static const double _lockThreshold = -60.0;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  final AudioPlayer _beepPlayer = AudioPlayer();
  Message? _replyingTo;
  final Map<String, GlobalKey> _messageKeys = {};
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  List<Message> _lastMessages = [];
  final Map<String, Timer> _purgeTimers = {};
  bool _selectionMode = false;
  _SelectionPurpose _selectionPurpose = _SelectionPurpose.forward;
  final Set<String> _selectedMessageIds = {};
  static const List<String> _quickReactions = [
    '👍',
    '❤️',
    '😂',
    '😮',
    '😢',
    '🙏',
  ];

  @override
  void initState() {
    super.initState();
    _messageController.addListener(() {
      final hasText = _messageController.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
    });
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _pulseAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initBeepPlayer();
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid != null && currentUid.isNotEmpty) {
      ref
          .read(firestoreServiceProvider)
          .markChatAsDelivered(chatId: widget.chatId, uid: currentUid);
    }
  }

  void _initBeepPlayer() async {
    try {
      await _beepPlayer.setAsset('assets/sounds/record_start.wav');
      await _beepPlayer.setVolume(1.0);
      debugPrint('🔊 Beep player initialized');
    } catch (e) {
      debugPrint('🔊 Beep init error: $e');
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _recordingTimer?.cancel();
    _pulseController.dispose();
    _beepPlayer.dispose();
    _highlightTimer?.cancel();
    for (final timer in _purgeTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  // Opportunistic client-side purge, matching mugam-v2 exactly: schedules a
  // hard delete 5 minutes after deletedAt. If the chat is reopened after
  // that window has already passed, the purge fires immediately (delay 0)
  // instead of being handled by any server-side TTL.
  void _schedulePurgeTimers(List<Message> messages) {
    for (final m in messages) {
      if (!m.deletedForAll || m.deletedAt == null) continue;
      if (_purgeTimers.containsKey(m.id)) continue;
      final deletedAt = DateTime.tryParse(m.deletedAt!);
      if (deletedAt == null) continue;
      final remaining = deletedAt
          .add(const Duration(minutes: 5))
          .difference(DateTime.now());
      final delay = remaining.isNegative ? Duration.zero : remaining;
      final chatId = widget.chatId;
      _purgeTimers[m.id] = Timer(delay, () {
        _purgeTimers.remove(m.id);
        ref
            .read(firestoreServiceProvider)
            .deleteMessagePermanently(chatId: chatId, messageId: m.id);
      });
    }
  }

  void _showMessageOptionsSheet(Message msg, bool isMe, {String? otherUid}) {
    _composerHadFocusBeforeMenu = _messageFocusNode.hasFocus;
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
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final emoji in _quickReactions)
                    GestureDetector(
                      onTap: () => _reactToMessage(msg, emoji),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 26),
                        ),
                      ),
                    ),
                  GestureDetector(
                    onTap: () => _openFullEmojiPicker(msg),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: kBorder),
                      ),
                      child: const Icon(Icons.add, color: kMuted, size: 20),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: kBorder, height: 1),
            ListTile(
              leading: const Icon(Icons.reply, color: kGold),
              title: const Text('Cavabla', style: TextStyle(color: kText)),
              onTap: () => _replyFromMenu(msg),
            ),
            ListTile(
              leading: const Icon(Icons.forward, color: kGold),
              title: const Text('Göndər', style: TextStyle(color: kText)),
              onTap: () =>
                  _enterSelectionMode(msg, purpose: _SelectionPurpose.forward),
            ),
            if (msg.text.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy, color: kGold),
                title: const Text('Kopyala', style: TextStyle(color: kText)),
                onTap: () => _copyMessageText(msg),
              )
            else if (msg.type == 'image' && msg.imageURL != null)
              ListTile(
                leading: const Icon(Icons.copy, color: kGold),
                title: const Text('Kopyala', style: TextStyle(color: kText)),
                onTap: () => _copyMessageImage(msg),
              ),
            if (isMe && otherUid != null)
              ListTile(
                leading: const Icon(Icons.info_outline, color: kGold),
                title: const Text('Məlumat', style: TextStyle(color: kText)),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MessageInfoScreen(
                        chatId: widget.chatId,
                        message: msg,
                      ),
                    ),
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Sil', style: TextStyle(color: Colors.red)),
              onTap: () =>
                  _enterSelectionMode(msg, purpose: _SelectionPurpose.delete),
            ),
          ],
        ),
      ),
    );
  }

  // showModalBottomSheet doesn't restore focus to whatever had it before the
  // sheet opened; without this the message composer silently loses focus
  // (and dismisses the keyboard) after a Copy action.
  void _restoreComposerFocusIfNeeded() {
    if (_composerHadFocusBeforeMenu && mounted) {
      _messageFocusNode.requestFocus();
    }
  }

  // Floating + a margin tall enough to clear the composer (and the reply
  // preview bar, when visible) so the confirmation doesn't sit on top of the
  // input the way the default fixed/4s SnackBar did.
  void _showCopySnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          bottom: _replyingTo != null ? 160 : 90,
          left: 16,
          right: 16,
        ),
      ),
    );
  }

  void _copyMessageText(Message msg) {
    Navigator.of(context).pop();
    Clipboard.setData(ClipboardData(text: msg.text));
    _showCopySnackBar('Kopyalandı');
    _restoreComposerFocusIfNeeded();
  }

  Future<void> _copyMessageImage(Message msg) async {
    Navigator.of(context).pop();
    final imageURL = msg.imageURL;
    if (imageURL == null) return;
    try {
      final file = await DefaultCacheManager().getSingleFile(imageURL);
      final bytes = await file.readAsBytes();
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) return;
      final item = DataWriterItem();
      item.add(Formats.jpeg(bytes));
      await clipboard.write([item]);
      if (!mounted) return;
      _showCopySnackBar('Kopyalandı');
      _restoreComposerFocusIfNeeded();
    } catch (_) {
      if (!mounted) return;
      _showCopySnackBar('Xəta baş verdi');
      _restoreComposerFocusIfNeeded();
    }
  }

  void _openForwardSheet(List<Message> messages) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: SizedBox(
          height: 400,
          child: Consumer(
            builder: (context, ref, _) {
              final chatsAsync = ref.watch(chatsProvider(currentUid));
              return chatsAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(color: kGold),
                ),
                error: (_, _) => const Center(
                  child: Text('Xəta', style: TextStyle(color: kMuted)),
                ),
                data: (chats) {
                  final targets = chats
                      .where((c) => c.id != widget.chatId)
                      .toList();
                  if (targets.isEmpty) {
                    return const Center(
                      child: Text(
                        'Söhbət tapılmadı',
                        style: TextStyle(color: kMuted),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: targets.length,
                    itemBuilder: (ctx, i) {
                      final chat = targets[i];
                      return ListTile(
                        leading: Text(
                          chat.emoji,
                          style: const TextStyle(fontSize: 24),
                        ),
                        title: Text(
                          chat.name,
                          style: const TextStyle(color: kText),
                        ),
                        onTap: () async {
                          Navigator.of(context).pop();
                          for (final msg in messages) {
                            await _forwardMessage(msg, chat.id, currentUid);
                          }
                          _exitSelectionMode();
                        },
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _forwardMessage(
    Message msg,
    String targetChatId,
    String currentUid,
  ) async {
    final service = ref.read(firestoreServiceProvider);
    try {
      switch (msg.type) {
        case 'image':
          final imageURL = msg.imageURL;
          if (imageURL != null) {
            await service.sendImageMessage(
              chatId: targetChatId,
              senderId: currentUid,
              imageURL: imageURL,
            );
          }
          break;
        case 'audio':
          final audioURL = msg.audioURL;
          if (audioURL != null) {
            await service.sendAudioMessage(
              chatId: targetChatId,
              senderId: currentUid,
              audioURL: audioURL,
            );
          }
          break;
        default:
          await service.sendMessage(
            chatId: targetChatId,
            senderId: currentUid,
            text: msg.text,
          );
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Yönləndirildi')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Yönləndirmə uğursuz oldu'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteSelectedForMe() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (currentUid.isEmpty) return;
    final service = ref.read(firestoreServiceProvider);
    for (final msg in _selectedMessages) {
      await service.deleteMessageForMe(
        chatId: widget.chatId,
        messageId: msg.id,
        uid: currentUid,
      );
    }
    _exitSelectionMode();
  }

  Future<void> _deleteSelectedForAll() async {
    final service = ref.read(firestoreServiceProvider);
    for (final msg in _selectedMessages) {
      await service.deleteMessageForAll(
        chatId: widget.chatId,
        messageId: msg.id,
      );
    }
    _exitSelectionMode();
  }

  void _showDeleteSelectedSheet() {
    final messages = _selectedMessages;
    if (messages.isEmpty) return;
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final allMine = messages.every((m) => m.senderId == currentUid);
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(width: 40),
                  const Expanded(
                    child: Text(
                      'Mesajı silmək?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: kText,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: kMuted),
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (allMine)
                ListTile(
                  title: const Text(
                    'Hamıdan sil',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _deleteSelectedForAll();
                  },
                ),
              ListTile(
                title: const Text(
                  'Yalnız məndən sil',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _deleteSelectedForMe();
                },
              ),
            ],
          ),
        ),
      ),
    );
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

  String _replyPreviewText(Message msg) {
    switch (msg.type) {
      case 'image':
        return '🖼 Şəkil';
      case 'audio':
        return '🎤 Səs mesajı';
      default:
        return msg.text;
    }
  }

  String _replySenderName(Message msg, String currentUid) {
    if (msg.senderId == currentUid) {
      return FirebaseAuth.instance.currentUser?.displayName ?? '';
    }
    final chatData = ref.read(chatDataProvider(widget.chatId)).value;
    return chatData?['name'] as String? ?? '';
  }

  String? _replyImageURL(Message msg) {
    return msg.type == 'image' ? msg.imageURL : null;
  }

  void _startReply(Message msg) {
    setState(() => _replyingTo = msg);
  }

  void _replyFromMenu(Message msg) {
    Navigator.of(context).pop();
    _startReply(msg);
  }

  void _enterSelectionMode(Message msg, {required _SelectionPurpose purpose}) {
    Navigator.of(context).pop();
    setState(() {
      _selectionMode = true;
      _selectionPurpose = purpose;
      _selectedMessageIds
        ..clear()
        ..add(msg.id);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedMessageIds.clear();
    });
  }

  void _toggleMessageSelection(String messageId) {
    setState(() {
      if (_selectedMessageIds.contains(messageId)) {
        _selectedMessageIds.remove(messageId);
      } else {
        _selectedMessageIds.add(messageId);
      }
    });
  }

  List<Message> get _selectedMessages =>
      _lastMessages.where((m) => _selectedMessageIds.contains(m.id)).toList();

  void _forwardSelected() {
    final messages = _selectedMessages;
    if (messages.isEmpty) return;
    _openForwardSheet(messages);
  }

  Future<void> _shareSelected() async {
    final messages = _selectedMessages;
    if (messages.isEmpty) return;
    final texts = <String>[];
    final files = <XFile>[];
    try {
      final tempDir = await getTemporaryDirectory();
      for (final msg in messages) {
        switch (msg.type) {
          case 'image':
            final imageURL = msg.imageURL;
            if (imageURL != null) {
              final cached = await DefaultCacheManager().getSingleFile(
                imageURL,
              );
              final bytes = await cached.readAsBytes();
              final path = '${tempDir.path}/share_${msg.id}.jpg';
              await File(path).writeAsBytes(bytes);
              files.add(XFile(path));
            }
            break;
          case 'audio':
            final audioURL = msg.audioURL;
            if (audioURL != null) {
              final cached = await DefaultCacheManager().getSingleFile(
                audioURL,
              );
              final bytes = await cached.readAsBytes();
              final path = '${tempDir.path}/share_${msg.id}.m4a';
              await File(path).writeAsBytes(bytes);
              files.add(XFile(path));
            }
            break;
          default:
            if (msg.text.isNotEmpty) texts.add(msg.text);
        }
      }
      if (files.isNotEmpty) {
        await SharePlus.instance.share(
          ShareParams(
            files: files,
            text: texts.isNotEmpty ? texts.join('\n') : null,
          ),
        );
      } else if (texts.isNotEmpty) {
        await SharePlus.instance.share(ShareParams(text: texts.join('\n')));
      }
      _exitSelectionMode();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Xəta baş verdi')));
    }
  }

  void _reactToMessage(Message msg, String emoji) {
    Navigator.of(context).pop();
    _toggleReaction(msg, emoji);
  }

  void _openFullEmojiPicker(Message msg) {
    Navigator.of(context).pop();
    showModalBottomSheet(
      context: context,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SizedBox(
        height: 320,
        child: EmojiPicker(
          onEmojiSelected: (category, emoji) {
            Navigator.of(context).pop();
            _toggleReaction(msg, emoji.emoji);
          },
        ),
      ),
    );
  }

  void _toggleReaction(Message msg, String emoji) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    ref
        .read(firestoreServiceProvider)
        .toggleReaction(
          chatId: widget.chatId,
          messageId: msg.id,
          uid: uid,
          emoji: emoji,
        );
  }

  void _cancelReply() {
    setState(() => _replyingTo = null);
  }

  void _scrollToMessage(String messageId) {
    final index = _lastMessages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final ctx = _messageKeys[messageId]?.currentContext;
    if (ctx != null) {
      _doScrollAndHighlight(ctx, messageId);
      return;
    }
    if (!_scrollController.hasClients) return;
    final estimate =
        (index / _lastMessages.length) *
        _scrollController.position.maxScrollExtent;
    unawaited(_scrollThenHighlight(estimate, messageId));
  }

  Future<void> _scrollThenHighlight(double estimate, String messageId) async {
    await _scrollController.animateTo(
      estimate.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    if (!mounted) return;
    final retryCtx = _messageKeys[messageId]?.currentContext;
    if (retryCtx != null && retryCtx.mounted) {
      _doScrollAndHighlight(retryCtx, messageId);
    } else {
      _flashHighlight(messageId);
    }
  }

  void _doScrollAndHighlight(BuildContext ctx, String messageId) {
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.5,
    );
    _flashHighlight(messageId);
  }

  void _flashHighlight(String messageId) {
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending) return;
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final replyingTo = _replyingTo;
    setState(() => _sending = true);
    _messageController.clear();
    _cancelReply();
    try {
      await ref
          .read(firestoreServiceProvider)
          .sendMessage(
            chatId: widget.chatId,
            senderId: currentUid,
            text: text,
            replyToId: replyingTo?.id,
            replyToText: replyingTo != null
                ? _replyPreviewText(replyingTo)
                : null,
            replyToSenderName: replyingTo != null
                ? _replySenderName(replyingTo, currentUid)
                : null,
            replyToImageURL: replyingTo != null
                ? _replyImageURL(replyingTo)
                : null,
          );
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
    final replyingTo = _replyingTo;
    setState(() => _uploadingImage = true);
    _cancelReply();
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
            replyToId: replyingTo?.id,
            replyToText: replyingTo != null
                ? _replyPreviewText(replyingTo)
                : null,
            replyToSenderName: replyingTo != null
                ? _replySenderName(replyingTo, currentUid)
                : null,
            replyToImageURL: replyingTo != null
                ? _replyImageURL(replyingTo)
                : null,
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
                  child: CachedNetworkImage(
                    imageUrl: imageURL,
                    fit: BoxFit.contain,
                  ),
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

  Future<void> _startRecording() async {
    // hasPermission() also requests permission on first call on iOS
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mikrofon icazəsi verilmədi'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    // Play beep BEFORE recorder (recorder changes audio session to record mode)
    try {
      await _beepPlayer.setAsset('assets/sounds/record_start.wav');
      await _beepPlayer.play();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 150));
    await _audioRecorder.start(
      RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
      ),
      path: _recordingPath!,
    );
    if (mounted) setState(() => _isRecording = true);
    _pulseController.repeat(reverse: true);
    _recordingStopwatch.reset();
    _recordingStopwatch.start();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        final s = _recordingStopwatch.elapsed.inSeconds;
        setState(
          () => _recordingDuration =
              '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
        );
      }
    });
  }

  Future<void> _stopAndSendRecording() async {
    setState(() {
      _dragX = 0.0;
      _dragY = 0.0;
      _isLocked = false;
    });
    _pulseController.stop();
    _pulseController.reset();
    if (!_isRecording) return;
    _recordingStopwatch.stop();
    _recordingTimer?.cancel();
    setState(() => _recordingDuration = '0:00');
    final path = await _audioRecorder.stop();
    if (mounted) {
      setState(() {
        _isRecording = false;
        _uploadingAudio = true;
      });
    }
    if (path == null) {
      if (mounted) setState(() => _uploadingAudio = false);
      return;
    }
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final replyingTo = _replyingTo;
    _cancelReply();
    try {
      final audioURL = await ref
          .read(firestoreServiceProvider)
          .uploadChatAudio(chatId: widget.chatId, filePath: path);
      await ref
          .read(firestoreServiceProvider)
          .sendAudioMessage(
            chatId: widget.chatId,
            senderId: currentUid,
            audioURL: audioURL,
            replyToId: replyingTo?.id,
            replyToText: replyingTo != null
                ? _replyPreviewText(replyingTo)
                : null,
            replyToSenderName: replyingTo != null
                ? _replySenderName(replyingTo, currentUid)
                : null,
            replyToImageURL: replyingTo != null
                ? _replyImageURL(replyingTo)
                : null,
          );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Səs mesajı göndərilmədi: $e'),
            backgroundColor: kRed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingAudio = false);
    }
  }

  Future<void> _cancelRecording() async {
    _recordingStopwatch.stop();
    _recordingTimer?.cancel();
    await _audioRecorder.stop();
    if (mounted) {
      setState(() {
        _isRecording = false;
        _isLocked = false;
        _dragX = 0.0;
        _dragY = 0.0;
        _recordingDuration = '0:00';
      });
    }
    _pulseController.stop();
    _pulseController.reset();
  }

  void _lockRecording() {
    setState(() {
      _isLocked = true;
      _dragX = 0.0;
      _dragY = 0.0;
    });
  }

  Widget _buildMessageBubble(
    Message msg,
    int index,
    List<String> allMsgIds,
    String currentUid,
    String? otherUid,
    Map<String, dynamic> deliveredTo,
    Map<String, dynamic> lastReadMsgId,
  ) {
    final isMe = msg.senderId == currentUid;
    final time = msg.timestamp != null
        ? DateFormat('HH:mm').format(msg.timestamp!.toDate())
        : '';
    Widget? checkMark;
    bool isRead = false;
    bool isDelivered = false;
    if (isMe && otherUid != null) {
      final lastReadId = lastReadMsgId[otherUid] as String?;
      final lastReadIndex = lastReadId != null
          ? allMsgIds.indexOf(lastReadId)
          : -1;
      isRead = lastReadIndex >= index && index != -1;
      isDelivered = deliveredTo[otherUid] != null || isRead;
      checkMark = Icon(
        isDelivered ? Icons.done_all : Icons.done,
        size: 14,
        color: isRead ? kReadBlue : const Color(0xFF1A0E00).withAlpha(128),
      );
    }
    final messageKey = _messageKeys.putIfAbsent(msg.id, () => GlobalKey());
    final isHighlighted = _highlightedMessageId == msg.id;
    if (msg.deletedForAll) {
      final content = AnimatedContainer(
        key: messageKey,
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: isHighlighted ? kBorder : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: _SwipeableMessageBubble(
          onReply: () => _startReply(msg),
          child: Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: EdgeInsets.only(
                top: 4,
                bottom: 4,
                left: isMe ? 60 : 0,
                right: isMe ? 0 : 60,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: kBg3,
                border: Border.all(color: kBorder),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(18),
                ),
              ),
              child: const Text(
                '🚫 Bu mesaj silindi',
                style: TextStyle(
                  color: kMuted,
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
        ),
      );
      return _wrapSelectableMessage(msg, content);
    }
    final content = AnimatedContainer(
      key: messageKey,
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        color: isHighlighted ? kBorder : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: _SwipeableMessageBubble(
        onReply: () => _startReply(msg),
        onLongPress: () =>
            _showMessageOptionsSheet(msg, isMe, otherUid: otherUid),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: isMe
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: EdgeInsets.only(
                  top: 4,
                  bottom: 4,
                  left: isMe ? 60 : 0,
                  right: isMe ? 0 : 60,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
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
                    if (msg.replyToId != null)
                      GestureDetector(
                        onTap: () => _scrollToMessage(msg.replyToId!),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          clipBehavior: Clip.antiAlias,
                          decoration: const BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.only(
                              topRight: Radius.circular(6),
                              bottomRight: Radius.circular(6),
                            ),
                          ),
                          child: IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  width: 4,
                                  color: isMe ? const Color(0xFF1A0E00) : kGold,
                                ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      10,
                                      10,
                                      10,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          msg.replyToSenderName ?? '',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: isMe
                                                ? const Color(0xFF1A0E00)
                                                : kGold,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          msg.replyToText ?? '',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: isMe
                                                ? const Color(
                                                    0xFF1A0E00,
                                                  ).withAlpha(180)
                                                : kMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (msg.replyToImageURL != null)
                                  SizedBox(
                                    width: 60,
                                    height: 60,
                                    child: CachedNetworkImage(
                                      imageUrl: msg.replyToImageURL!,
                                      width: 60,
                                      height: 60,
                                      fit: BoxFit.cover,
                                      placeholder: (ctx, url) =>
                                          Container(color: kBg3),
                                      errorWidget: (ctx, url, err) => Container(
                                        color: kBg3,
                                        child: const Icon(
                                          Icons.broken_image,
                                          color: kMuted,
                                          size: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
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
                              child: const Icon(
                                Icons.broken_image,
                                color: kMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (msg.type == 'audio' && msg.audioURL != null)
                      _VoiceMessagePlayer(audioURL: msg.audioURL!, isMe: isMe),
                    const SizedBox(height: 2),
                    GestureDetector(
                      onTap: isMe && otherUid != null
                          ? () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => MessageInfoScreen(
                                  chatId: widget.chatId,
                                  message: msg,
                                ),
                              ),
                            )
                          : null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            time,
                            style: TextStyle(
                              color: isMe
                                  ? const Color(0xFF1A0E00).withAlpha(150)
                                  : kMuted,
                              fontSize: 10,
                            ),
                          ),
                          if (checkMark != null) ...[
                            const SizedBox(width: 3),
                            checkMark,
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (msg.reactions.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(
                    top: 4,
                    left: isMe ? 60 : 14,
                    right: isMe ? 14 : 60,
                  ),
                  child: _buildReactionsRow(msg, currentUid, isMe),
                ),
            ],
          ),
        ),
      ),
    );
    return _wrapSelectableMessage(msg, content);
  }

  Widget _buildSelectionBar() {
    final isDelete = _selectionPurpose == _SelectionPurpose.delete;
    return Container(
      color: kBg2,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Row(
        children: [
          GestureDetector(
            onTap: isDelete ? _showDeleteSelectedSheet : _forwardSelected,
            child: Icon(
              isDelete ? Icons.delete_outline : Icons.forward,
              color: kGold,
            ),
          ),
          Expanded(
            child: Center(
              child: Text(
                'Seçilib: ${_selectedMessageIds.length}',
                style: const TextStyle(color: kText, fontSize: 14),
              ),
            ),
          ),
          if (!isDelete)
            GestureDetector(
              onTap: _shareSelected,
              child: const Icon(Icons.ios_share, color: kGold),
            ),
        ],
      ),
    );
  }

  Widget _wrapSelectableMessage(Message msg, Widget content) {
    if (!_selectionMode) return content;
    final selected = _selectedMessageIds.contains(msg.id);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 8),
          child: GestureDetector(
            onTap: () => _toggleMessageSelection(msg.id),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? kGold : Colors.transparent,
                border: Border.all(
                  color: selected ? kGold : kMuted,
                  width: 1.5,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 14, color: Color(0xFF1A0E00))
                  : null,
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: () => _toggleMessageSelection(msg.id),
            behavior: HitTestBehavior.opaque,
            child: IgnorePointer(child: content),
          ),
        ),
      ],
    );
  }

  Widget _buildReactionsRow(Message msg, String currentUid, bool isMe) {
    return Wrap(
      alignment: isMe ? WrapAlignment.end : WrapAlignment.start,
      spacing: 4,
      runSpacing: 4,
      children: msg.reactions.entries.map((entry) {
        final emoji = entry.key;
        final uids = entry.value;
        final reactedByMe = uids.contains(currentUid);
        return GestureDetector(
          onTap: () => _toggleReaction(msg, emoji),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: reactedByMe ? kGold.withAlpha(60) : kBg3,
              border: Border.all(color: reactedByMe ? kGold : kBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(emoji, style: const TextStyle(fontSize: 13)),
                if (uids.length > 1) ...[
                  const SizedBox(width: 3),
                  Text(
                    '${uids.length}',
                    style: const TextStyle(fontSize: 11, color: kMuted),
                  ),
                ],
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final chatDataAsync = ref.watch(chatDataProvider(widget.chatId));

    ref.listen(messagesProvider(widget.chatId), (previous, next) {
      next.whenData((messages) {
        // Only auto-scroll when a message was actually appended — deletes,
        // reactions and other field-only updates re-emit the same count and
        // must not yank the view back to the bottom.
        final previousCount = previous?.value?.length ?? 0;
        if (messages.length > previousCount) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToBottom();
          });
        }
      });
      next.whenData((messages) {
        if (messages.isEmpty) return;
        Message? lastOtherMsg;
        for (final m in messages.reversed) {
          if (m.senderId != currentUid) {
            lastOtherMsg = m;
            break;
          }
        }
        if (lastOtherMsg != null && currentUid.isNotEmpty) {
          ref
              .read(firestoreServiceProvider)
              .markChatAsReadBy(
                chatId: widget.chatId,
                uid: currentUid,
                lastMsgId: lastOtherMsg.id,
              );
        }
      });
    });

    final chatMetaAsync = ref.watch(chatMetaProvider(widget.chatId));
    final deliveredTo =
        chatMetaAsync.value?['deliveredTo'] as Map<String, dynamic>? ?? {};
    final lastReadMsgId =
        chatMetaAsync.value?['lastReadMsgId'] as Map<String, dynamic>? ?? {};
    final members = (chatMetaAsync.value?['members'] as List?)?.cast<String>();
    final otherUid = members?.firstWhere(
      (m) => m != currentUid,
      orElse: () => '',
    );
    final otherUidResolved = (otherUid != null && otherUid.isNotEmpty)
        ? otherUid
        : null;

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
        actions: [
          if (_selectionMode)
            TextButton(
              onPressed: _exitSelectionMode,
              child: const Text('Ləğv et', style: TextStyle(color: kGold)),
            ),
        ],
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
                  data: (messages) {
                    final visibleMessages = messages
                        .where((m) => !m.deletedFor.contains(currentUid))
                        .toList();
                    _lastMessages = visibleMessages;
                    _schedulePurgeTimers(visibleMessages);
                    final allMsgIds = visibleMessages.map((m) => m.id).toList();
                    return ListView.builder(
                      controller: _scrollController,
                      reverse: false,
                      itemCount: visibleMessages.length,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      itemBuilder: (ctx, i) => _buildMessageBubble(
                        visibleMessages[i],
                        i,
                        allMsgIds,
                        currentUid,
                        otherUidResolved,
                        deliveredTo,
                        lastReadMsgId,
                      ),
                    );
                  },
                ),
          ),
          if (_replyingTo != null)
            Container(
              decoration: const BoxDecoration(
                color: kBg2,
                border: Border(top: BorderSide(color: kBorder)),
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 4, color: kGold),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _replyingTo!.senderId == currentUid
                                  ? 'Siz'
                                  : (chatDataAsync.value?['name'] as String? ??
                                        ''),
                              style: const TextStyle(
                                fontSize: 12,
                                color: kGold,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              _replyPreviewText(_replyingTo!),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: kMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_replyingTo!.type == 'image' &&
                        _replyingTo!.imageURL != null)
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: CachedNetworkImage(
                          imageUrl: _replyingTo!.imageURL!,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          placeholder: (ctx, url) => Container(color: kBg3),
                          errorWidget: (ctx, url, err) => Container(
                            color: kBg3,
                            child: const Icon(
                              Icons.broken_image,
                              color: kMuted,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Center(
                        child: GestureDetector(
                          onTap: _cancelReply,
                          child: const Icon(
                            Icons.close,
                            color: kMuted,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_selectionMode)
            _buildSelectionBar()
          else
            Container(
              color: kBg2,
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Left button — attach (hidden during recording) or cancel (locked mode)
                  if (!_isRecording)
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
                    )
                  else if (_isLocked)
                    GestureDetector(
                      onTap: _cancelRecording,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: kBg3,
                          shape: BoxShape.circle,
                          border: Border.all(color: kBorder),
                        ),
                        child: const Icon(
                          Icons.delete_outline,
                          color: kRed,
                          size: 22,
                        ),
                      ),
                    )
                  else
                    const SizedBox(
                      width: 48,
                    ), // placeholder to keep layout stable

                  const SizedBox(width: 4),

                  // Center — text field (normal) or recording indicator (recording)
                  Expanded(
                    child: _isRecording
                        ? Container(
                            height: 44,
                            decoration: BoxDecoration(
                              color: kBg3,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                AnimatedBuilder(
                                  animation: _pulseAnimation,
                                  builder: (_, _) => Opacity(
                                    opacity: _pulseAnimation.value,
                                    child: const Icon(
                                      Icons.circle,
                                      color: kRed,
                                      size: 10,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _recordingDuration,
                                  style: const TextStyle(
                                    color: kRed,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                if (!_isLocked)
                                  Opacity(
                                    opacity:
                                        (1.0 + _dragX / _cancelThreshold.abs())
                                            .clamp(0.0, 1.0),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.chevron_left,
                                          color: kMuted,
                                          size: 16,
                                        ),
                                        const Text(
                                          'Sürüşdür',
                                          style: TextStyle(
                                            color: kMuted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          )
                        : TextField(
                            controller: _messageController,
                            focusNode: _messageFocusNode,
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

                  // Right button — send (has text or locked recording) or mic (empty/recording)
                  if (_hasText && !_isRecording)
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
                    )
                  else if (_isLocked)
                    GestureDetector(
                      onTap: _stopAndSendRecording,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          color: kGold,
                          shape: BoxShape.circle,
                        ),
                        child: _uploadingAudio
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
                    )
                  else
                    // Mic button with lock icon above (Stack)
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onLongPressStart: (_) => _startRecording(),
                          onLongPressMoveUpdate: (details) {
                            if (!_isRecording || _isLocked) return;
                            setState(() {
                              _dragX = details.offsetFromOrigin.dx;
                              _dragY = details.offsetFromOrigin.dy;
                            });
                            if (_dragX < _cancelThreshold) {
                              _cancelRecording();
                            } else if (_dragY < _lockThreshold) {
                              _lockRecording();
                            }
                          },
                          onLongPressEnd: (_) {
                            if (_isLocked) return;
                            if (_isRecording) _stopAndSendRecording();
                          },
                          onLongPressCancel: () {
                            if (_isLocked) return;
                            if (_isRecording) _cancelRecording();
                          },
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: _isRecording ? kRed : kBg3,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _isRecording ? kRed : kBorder,
                              ),
                            ),
                            child: _uploadingAudio
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: kGold,
                                    ),
                                  )
                                : Icon(
                                    Icons.mic,
                                    color: _isRecording ? Colors.white : kGold,
                                    size: 22,
                                  ),
                          ),
                        ),
                        // Lock icon above mic button — only shown during unlocked recording
                        if (_isRecording && !_isLocked)
                          Positioned(
                            top: -48,
                            left: 0,
                            right: 0,
                            child: Opacity(
                              opacity: (1.0 + _dragY / _lockThreshold.abs())
                                  .clamp(0.0, 1.0),
                              child: Column(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: kBg3,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: kBorder),
                                    ),
                                    child: const Icon(
                                      Icons.lock_outline,
                                      color: kMuted,
                                      size: 18,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  const Text(
                                    'Kilid',
                                    style: TextStyle(
                                      color: kMuted,
                                      fontSize: 9,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SwipeableMessageBubble extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  final VoidCallback? onLongPress;
  const _SwipeableMessageBubble({
    required this.child,
    required this.onReply,
    this.onLongPress,
  });

  @override
  State<_SwipeableMessageBubble> createState() =>
      _SwipeableMessageBubbleState();
}

class _SwipeableMessageBubbleState extends State<_SwipeableMessageBubble>
    with SingleTickerProviderStateMixin {
  double _dragX = 0.0;
  late final AnimationController _snapController;
  Animation<double>? _snapAnimation;
  static const double _maxDrag = 80.0;
  static const double _triggerThreshold = 60.0;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  void _snapBack() {
    _snapAnimation = Tween<double>(begin: _dragX, end: 0.0).animate(
      CurvedAnimation(parent: _snapController, curve: Curves.easeOut),
    )..addListener(() => setState(() => _dragX = _snapAnimation!.value));
    _snapController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dragX / _maxDrag).clamp(0.0, 1.0);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (_dragX > 0)
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: Opacity(
                opacity: progress,
                child: Transform.scale(
                  scale: 0.5 + progress * 0.5,
                  child: const Icon(Icons.reply, color: kGold, size: 22),
                ),
              ),
            ),
          ),
        GestureDetector(
          onLongPress: widget.onLongPress,
          onHorizontalDragUpdate: (details) {
            final next = (_dragX + details.delta.dx).clamp(0.0, _maxDrag);
            if (next != _dragX) setState(() => _dragX = next);
          },
          onHorizontalDragEnd: (_) {
            if (_dragX >= _triggerThreshold) {
              widget.onReply();
            }
            _snapBack();
          },
          child: Transform.translate(
            offset: Offset(_dragX, 0),
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _VoiceMessagePlayer extends StatefulWidget {
  final String audioURL;
  final bool isMe;
  const _VoiceMessagePlayer({required this.audioURL, required this.isMe});

  @override
  State<_VoiceMessagePlayer> createState() => _VoiceMessagePlayerState();
}

class _VoiceMessagePlayerState extends State<_VoiceMessagePlayer> {
  late final AudioPlayer _player;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => _duration = dur);
    });
    _player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state.playing);
        if (state.processingState == ProcessingState.completed) {
          _player.seek(Duration.zero);
          setState(() => _isPlaying = false);
        }
      }
    });
    _player.setUrl(widget.audioURL);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isMe ? const Color(0xFF1A0E00) : kText;
    final sliderColor = widget.isMe ? const Color(0xFF1A0E00) : kGold;
    final total = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : 1.0;
    final current = _position.inMilliseconds.toDouble().clamp(0.0, total);

    return SizedBox(
      width: 200,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () async {
                  if (_isPlaying) {
                    await _player.pause();
                  } else {
                    await _player.play();
                  }
                },
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: sliderColor.withAlpha(30),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    color: sliderColor,
                    size: 22,
                  ),
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: SliderComponentShape.noOverlay,
                    activeTrackColor: sliderColor,
                    inactiveTrackColor: sliderColor.withAlpha(60),
                    thumbColor: sliderColor,
                  ),
                  child: Slider(
                    value: current,
                    min: 0,
                    max: total,
                    onChanged: (v) =>
                        _player.seek(Duration(milliseconds: v.toInt())),
                  ),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${_fmt(_position)} / ${_fmt(_duration)}',
              style: TextStyle(color: color.withAlpha(150), fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}
