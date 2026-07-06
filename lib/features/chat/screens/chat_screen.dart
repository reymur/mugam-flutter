import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_session/audio_session.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:exif/exif.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_video_info/flutter_video_info.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:super_clipboard/super_clipboard.dart';
import '../../../core/cache/message_cache_service.dart';
import '../../../core/queue/pending_message_queue_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import 'about_contact_screen.dart';
import 'custom_camera_backup/camera_capture_screen.dart';
import 'message_info_screen.dart';
import 'video_message_widgets.dart';

enum _SelectionPurpose { forward, delete }

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  // Set when opened from the Starred Messages list: scrolls to and briefly
  // highlights this message on first load instead of jumping to the bottom.
  final String? initialHighlightMessageId;
  const ChatScreen({
    super.key,
    required this.chatId,
    this.initialHighlightMessageId,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

// Neither `record` nor `just_audio` ever sends AVAudioSession the explicit
// "I'm done" signal on stop/pause — they set category/options and activate
// on start, but never deactivate. Without this, background audio (Spotify
// etc.) stays ducked until the app is backgrounded/foregrounded, which
// happens to force a session reset as a side effect. Calling this
// ourselves right after stop/pause releases ducking immediately instead of
// relying on that incidental reset. Shared by _ChatScreenState (recording)
// and _VoiceMessagePlayerState (playback) below.
Future<void> _deactivateAudioSession() async {
  try {
    final session = await AudioSession.instance;
    await session.setActive(false);
  } catch (_) {}
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  bool _composerHadFocusBeforeMenu = false;
  final ScrollController _scrollController = ScrollController();
  bool _sending = false;
  bool _uploadingImage = false;
  bool _uploadingVideo = false;
  final ImagePicker _picker = ImagePicker();
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  bool _uploadingAudio = false;
  String? _recordingPath;
  bool _hasText = false;
  final Stopwatch _recordingStopwatch = Stopwatch();
  Timer? _recordingTimer;
  String _recordingDuration = '0:00';
  StreamSubscription<Amplitude>? _amplitudeSub;
  final List<double> _rawAmplitudes = [];
  bool _isLocked = false;
  double _dragX = 0.0;
  double _dragY = 0.0;
  static const double _cancelThreshold = -80.0;
  static const double _lockThreshold = -60.0;
  // Uniform on all four corners for every bubble type (text/image/audio/
  // video) and both senders — WhatsApp's current bubbles have no tail.
  static const double _kBubbleRadius = 12.0;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  final AudioPlayer _beepPlayer = AudioPlayer();
  Message? _replyingTo;
  final Map<String, GlobalKey> _messageKeys = {};
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  List<Message> _lastMessages = [];
  List<Message>? _messagesPendingCacheFlush;
  final Map<String, Timer> _purgeTimers = {};
  bool _selectionMode = false;
  _SelectionPurpose _selectionPurpose = _SelectionPurpose.forward;
  final Set<String> _selectedMessageIds = {};
  bool _hasJumpedToBottomInitially = false;
  static const List<String> _quickReactions = [
    '👍',
    '❤️',
    '😂',
    '😮',
    '😢',
    '🙏',
  ];

  late final FirestoreService _firestoreService;
  late final MessageCacheService _messageCacheService;

  @override
  void initState() {
    super.initState();
    _firestoreService = ref.read(firestoreServiceProvider);
    _messageCacheService = ref.read(messageCacheServiceProvider);
    _messageController.addListener(() {
      final hasText = _messageController.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
    });
    // Keep the last message visible once the keyboard opens, matching
    // WhatsApp's behavior of shifting content up rather than covering it.
    _messageFocusNode.addListener(() {
      if (_messageFocusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
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
      _firestoreService.markChatAsDelivered(
        chatId: widget.chatId,
        uid: currentUid,
      );
      _firestoreService.addActiveUser(chatId: widget.chatId, uid: currentUid);
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
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid != null && currentUid.isNotEmpty) {
      _firestoreService.removeActiveUser(
        chatId: widget.chatId,
        uid: currentUid,
      );
    }
    final pendingMessages = _messagesPendingCacheFlush;
    if (pendingMessages != null) {
      _messageCacheService.flush(widget.chatId, pendingMessages);
    }
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _recordingTimer?.cancel();
    _amplitudeSub?.cancel();
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
    if (msg.localSendStatus != null) {
      _showPendingMessageOptionsSheet(msg);
      return;
    }
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
            ListTile(
              leading: Icon(
                _isMessageStarred(msg.id) ? Icons.star : Icons.star_border,
                color: kGold,
              ),
              title: Text(
                _isMessageStarred(msg.id)
                    ? 'Seçilmişlərdən sil'
                    : 'Seçilmişlər',
                style: const TextStyle(color: kText),
              ),
              onTap: () => _toggleStarMessage(msg),
            ),
            if (isMe && otherUid != null)
              ListTile(
                leading: const Icon(Icons.info_outline, color: kGold),
                title: const Text('Məlumat', style: TextStyle(color: kText)),
                onTap: () {
                  Navigator.of(context).pop();
                  _openMessageInfo(msg);
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

  // A pending-queue message (queued/uploading/failed) has no Firestore
  // document yet — reactions, reply, forward, copy, star and delivery info
  // don't apply to it, so it gets its own minimal sheet instead of hiding
  // items one by one in the main sheet above. "Sil" here must remove the
  // item from the local queue (pendingMessageQueueProvider), not call the
  // Firestore delete used by the main sheet — that path looks up msg.id,
  // which for a synthetic queue message is 'local_<localId>' and matches no
  // document, so it would silently do nothing. "Yenidən göndər" only makes
  // sense once the item has actually failed — for queued/uploading the
  // automatic per-chat loop is already retrying it.
  void _showPendingMessageOptionsSheet(Message msg) {
    final localId = msg.id.replaceFirst('local_', '');
    final isFailed = msg.localSendStatus == 'failed';
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
            if (isFailed)
              ListTile(
                leading: const Icon(Icons.refresh, color: kGold),
                title: const Text(
                  'Yenidən göndər',
                  style: TextStyle(color: kText),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  ref
                      .read(pendingMessageQueueProvider.notifier)
                      .retry(localId);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Sil', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.of(context).pop();
                ref.read(pendingMessageQueueProvider.notifier).remove(localId);
              },
            ),
          ],
        ),
      ),
    );
  }

  // Runs on every raw touch-down anywhere over the message list — the empty
  // background, a plain message bubble, or the start of a long-press that's
  // about to open the options sheet. A tap-based GestureDetector can't do
  // this job: any descendant with its own tap or long-press recognizer
  // (image preview, reaction chips, the reply-jump row, the options menu
  // itself) wins the gesture arena and the outer onTap never fires, so only
  // the few spots with no recognizer of their own would dismiss the
  // keyboard. Listener sees the pointer-down before any recognizer resolves,
  // so by the time a long-press's onLongPress actually fires and opens a
  // menu, the composer has already lost focus — there is nothing left for
  // Flutter's modal-route default behavior to restore once that menu closes.
  // Captures whether the composer had focus first, since _messageFocusNode
  // .unfocus() below makes hasFocus false for anything that reads it after.
  void _dismissComposerFocusOnOutsideTap() {
    _composerHadFocusBeforeMenu = _messageFocusNode.hasFocus;
    _messageFocusNode.unfocus();
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

  bool _isMessageStarred(String messageId) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final starred =
        ref.read(starredMessagesProvider(currentUid)).value ?? const [];
    return starred.any((m) => m.id == messageId);
  }

  Future<void> _toggleStarMessage(Message msg) async {
    Navigator.of(context).pop();
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final service = ref.read(firestoreServiceProvider);
    if (_isMessageStarred(msg.id)) {
      await service.unstarMessage(uid: currentUid, messageId: msg.id);
      if (mounted) _showCopySnackBar('Seçilmişlərdən silindi');
    } else {
      final chatName =
          ref.read(chatDataProvider(widget.chatId)).value?['name'] as String? ??
          '';
      await service.starMessage(
        uid: currentUid,
        chatId: widget.chatId,
        chatName: chatName,
        senderName: _replySenderName(msg, currentUid),
        message: msg,
      );
      if (mounted) _showCopySnackBar('Seçilmişlərə əlavə edildi');
    }
    _restoreComposerFocusIfNeeded();
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
      // mediaOriginChatId/mediaFileName let firestore.rules confirm this
      // media really was a validated upload (see onChatMediaUploaded)
      // rather than trusting the URL string alone — a forward has to carry
      // them through from the original message, not just its URL. Messages
      // sent before this field existed don't have them and can no longer
      // be forwarded; surfaced as the same generic forward-failed error
      // below rather than attempting a write the server will reject
      // anyway.
      final isMedia =
          msg.type == 'image' || msg.type == 'audio' || msg.type == 'video';
      if (isMedia &&
          (msg.mediaOriginChatId == null || msg.mediaFileName == null)) {
        throw Exception('Media message predates forward-validation fields');
      }
      switch (msg.type) {
        case 'image':
          final imageURL = msg.imageURL;
          if (imageURL != null) {
            await service.sendImageMessage(
              chatId: targetChatId,
              senderId: currentUid,
              imageURL: imageURL,
              mediaOriginChatId: msg.mediaOriginChatId,
              mediaFileName: msg.mediaFileName,
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
              mediaOriginChatId: msg.mediaOriginChatId,
              mediaFileName: msg.mediaFileName,
            );
          }
          break;
        case 'video':
          final videoURL = msg.videoURL;
          if (videoURL != null) {
            await service.sendVideoMessage(
              chatId: targetChatId,
              senderId: currentUid,
              videoURL: videoURL,
              mediaOriginChatId: msg.mediaOriginChatId,
              mediaFileName: msg.mediaFileName,
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

  // Chats should open already at the bottom, no visible scrolling — unlike
  // the animated _scrollToBottom used for new incoming/outgoing messages.
  void _jumpToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  String _replyPreviewText(Message msg) {
    switch (msg.type) {
      case 'image':
        return '🖼 Şəkil';
      case 'audio':
        return '🎤 Səs mesajı';
      case 'video':
        return '🎥 Video';
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

  String? _replyVideoURL(Message msg) {
    return msg.type == 'video' ? msg.videoURL : null;
  }

  void _startReply(Message msg) {
    setState(() => _replyingTo = msg);
  }

  void _openMessageInfo(Message msg) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MessageInfoScreen(chatId: widget.chatId, message: msg),
      ),
    );
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
          case 'video':
            final videoURL = msg.videoURL;
            if (videoURL != null) {
              final cached = await DefaultCacheManager().getSingleFile(
                videoURL,
              );
              final bytes = await cached.readAsBytes();
              final path = '${tempDir.path}/share_${msg.id}.mp4';
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

  void _toggleReaction(Message msg, String emoji) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    try {
      await ref
          .read(firestoreServiceProvider)
          .toggleReaction(chatId: widget.chatId, messageId: msg.id, emoji: emoji);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reaksiya əlavə edilmədi'),
          backgroundColor: kRed,
        ),
      );
    }
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
            replyToVideoURL: replyingTo != null
                ? _replyVideoURL(replyingTo)
                : null,
          );
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // Opens the custom camera screen (live preview + Video/Photo mode
  // switcher) as a front end, but the actual capture now hands off to the
  // system camera on shutter tap — see CameraCaptureScreen's own class doc
  // comment (lib/features/chat/screens/custom_camera_backup/) for why:
  // system capture quality (HDR, processing) matters more here than a
  // fully custom capture path. Routes the result to the matching
  // upload+send helper exactly as before, regardless of which camera UI
  // actually produced the file.
  Future<void> _openCamera() async {
    final result = await Navigator.push<CapturedMedia>(
      context,
      MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
    );
    if (result == null) return;
    if (!mounted) return;
    if (result.isVideo) {
      await _uploadAndSendVideoFile(result.path);
    } else {
      await _uploadAndSendImageFile(result.path);
    }
  }

  // Hands the file to the offline-aware pending-send queue instead of
  // uploading inline — enqueue() only fails synchronously if the queue is
  // full; the actual upload/retry/backoff happens in the background and is
  // reflected per-message (clock/error icon), not blocked on here.
  Future<void> _uploadAndSendVideoFile(String filePath) async {
    if (!mounted) return;
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final replyingTo = _replyingTo;
    setState(() => _uploadingVideo = true);
    _cancelReply();
    // Reads duration and dimensions straight from the file's own container
    // metadata (AVAsset.duration/naturalSize / MediaMetadataRetriever under
    // the hood) — no player/texture setup, near-instant for a local file.
    // width/height are the raw encoded buffer size, not the as-displayed
    // one — orientation 90/270 (portrait recordings) means the buffer is
    // actually rotated 90°, so the visual width/height are swapped relative
    // to what's reported. Null on failure just means the bubble falls back
    // to its fixed-square placeholder, same as an old message queued before
    // this field existed.
    int? videoDurationMs;
    int? videoWidth;
    int? videoHeight;
    try {
      final info = await FlutterVideoInfo().getVideoInfo(filePath);
      final durationMs = info?.duration;
      if (durationMs != null) videoDurationMs = durationMs.round();
      final rawWidth = info?.width;
      final rawHeight = info?.height;
      final rotated = info?.orientation == 90 || info?.orientation == 270;
      if (rawWidth != null && rawHeight != null) {
        videoWidth = rotated ? rawHeight : rawWidth;
        videoHeight = rotated ? rawWidth : rawHeight;
      }
    } catch (_) {}
    final error = await ref
        .read(pendingMessageQueueProvider.notifier)
        .enqueue(
          chatId: widget.chatId,
          senderId: currentUid,
          type: 'video',
          sourceFilePath: filePath,
          videoDurationMs: videoDurationMs,
          videoWidth: videoWidth,
          videoHeight: videoHeight,
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
          replyToVideoURL: replyingTo != null
              ? _replyVideoURL(replyingTo)
              : null,
        );
    if (mounted) setState(() => _uploadingVideo = false);
    if (error != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: kRed),
        );
      }
    } else {
      _scrollToBottom();
    }
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 70,
      maxWidth: 1200,
    );
    if (picked == null) return;
    if (!mounted) return;
    await _uploadAndSendImageFile(picked.path);
  }

  // Reads the picked file's own pixel dimensions via a real (if cheap,
  // since image_picker already downsizes to maxWidth 1200) decode via
  // dart:ui — but that decode reports the RAW stored buffer size, not the
  // as-displayed one: confirmed on-device that a landscape photo decodes
  // as e.g. 720x1280 (portrait-shaped raw buffer) with EXIF Orientation 6
  // ("rotate 90° CW to display correctly"), which the Image/
  // CachedNetworkImage widgets used to actually render it DO apply, but
  // dart:ui's raw decode does not. Reading EXIF Orientation separately
  // (via the exif package — metadata-only parse, no extra decode cost)
  // and swapping width/height for the four orientation values that
  // involve a 90/270 transpose (5, 6, 7, 8) gives the true as-displayed
  // size, matching how the photo actually renders. Same rationale as
  // _uploadAndSendVideoFile's own rotated-swap for videoWidth/
  // videoHeight, just sourced from EXIF instead of container metadata.
  // Null on failure just means the bubble falls back to its fixed-square
  // placeholder, same as an old message queued before this field existed.
  Future<(int, int)?> _probeImageSize(String filePath) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      var width = frame.image.width;
      var height = frame.image.height;
      frame.image.dispose();
      try {
        final tags = await readExifFromBytes(bytes);
        final orientation = tags['Image Orientation']?.values.firstAsInt();
        if (orientation != null && {5, 6, 7, 8}.contains(orientation)) {
          final w = width;
          width = height;
          height = w;
        }
      } catch (_) {
        // No/unreadable EXIF just means we keep the raw decoded size —
        // correct for the common case of an image with no rotation tag.
      }
      return (width, height);
    } catch (_) {
      return null;
    }
  }

  // Shared by the gallery/camera picker and by clipboard image paste.
  // Hands the file to the offline-aware pending-send queue — see
  // _uploadAndSendVideoFile for why this doesn't upload inline anymore.
  Future<void> _uploadAndSendImageFile(String filePath) async {
    if (!mounted) return;
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final replyingTo = _replyingTo;
    setState(() => _uploadingImage = true);
    _cancelReply();
    final imageSize = await _probeImageSize(filePath);
    final error = await ref
        .read(pendingMessageQueueProvider.notifier)
        .enqueue(
          chatId: widget.chatId,
          senderId: currentUid,
          type: 'image',
          sourceFilePath: filePath,
          imageWidth: imageSize?.$1,
          imageHeight: imageSize?.$2,
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
          replyToVideoURL: replyingTo != null
              ? _replyVideoURL(replyingTo)
              : null,
        );
    if (mounted) setState(() => _uploadingImage = false);
    if (error != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: kRed),
        );
      }
    } else {
      _scrollToBottom();
    }
  }

  // Only ever invoked from the context menu's explicit "Paste" tap
  // (see the TextField's contextMenuBuilder) — never on focus/timers.
  Future<void> _sendPastedImage(DataReaderFile file) async {
    final bytes = await file.readAll();
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/pasted_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(path).writeAsBytes(bytes);
    await _uploadAndSendImageFile(path);
  }

  // Replaces only the Paste entry of the context menu (native iOS system menu
  // when supported, Flutter-drawn toolbar otherwise) so we can detect a
  // clipboard image and send it as a photo. Falls back to the field's own
  // paste callback untouched when the clipboard holds text (or nothing).
  void _handlePasteButton(VoidCallback? originalOnPressed) {
    () async {
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        originalOnPressed?.call();
        return;
      }
      final reader = await clipboard.read();
      final format = reader.canProvide(Formats.png)
          ? Formats.png
          : (reader.canProvide(Formats.jpeg) ? Formats.jpeg : null);
      if (format == null) {
        originalOnPressed?.call();
        return;
      }
      reader.getFile(format, _sendPastedImage);
    }();
  }

  // Mirrors SystemContextMenu.getDefaultItems' mapping for every button type
  // except paste, which the caller substitutes with a custom item.
  IOSSystemContextMenuItem? _nativeMenuItemFor(ContextMenuButtonType type) {
    switch (type) {
      case ContextMenuButtonType.copy:
        return const IOSSystemContextMenuItemCopy();
      case ContextMenuButtonType.cut:
        return const IOSSystemContextMenuItemCut();
      case ContextMenuButtonType.selectAll:
        return const IOSSystemContextMenuItemSelectAll();
      case ContextMenuButtonType.lookUp:
        return const IOSSystemContextMenuItemLookUp();
      case ContextMenuButtonType.searchWeb:
        return const IOSSystemContextMenuItemSearchWeb();
      case ContextMenuButtonType.share:
        return const IOSSystemContextMenuItemShare();
      case ContextMenuButtonType.liveTextInput:
        return const IOSSystemContextMenuItemLiveText();
      case ContextMenuButtonType.paste:
      case ContextMenuButtonType.delete:
      case ContextMenuButtonType.custom:
        return null;
    }
  }

  // Keeps the real native iOS context menu (and its Copy/Cut/Select All/etc.)
  // wherever the platform supports it; only the Paste entry becomes a custom
  // item so we get a callback to inspect the clipboard. On platforms without
  // the native system menu, the same substitution is applied to Flutter's
  // own toolbar instead.
  //
  // Flutter only includes a paste button in contextMenuButtonItems when
  // Clipboard.hasStrings() is true, i.e. it never accounts for an image sitting
  // in the clipboard. So Paste is added unconditionally here (as long as the
  // field isn't read-only) instead of being derived from that list.
  Widget _buildMessageContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final canPaste = !editableTextState.widget.readOnly;
    void pasteFallback() =>
        editableTextState.pasteText(SelectionChangedCause.toolbar);

    if (SystemContextMenu.isSupportedByField(editableTextState)) {
      final localizations = WidgetsLocalizations.of(context);
      final items = <IOSSystemContextMenuItem>[];
      var pasteAdded = false;
      for (final button in editableTextState.contextMenuButtonItems) {
        if (button.type == ContextMenuButtonType.paste) {
          items.add(
            IOSSystemContextMenuItemCustom(
              title: localizations.pasteButtonLabel,
              onPressed: () => _handlePasteButton(pasteFallback),
            ),
          );
          pasteAdded = true;
        } else {
          final item = _nativeMenuItemFor(button.type);
          if (item != null) items.add(item);
        }
      }
      if (!pasteAdded && canPaste) {
        items.add(
          IOSSystemContextMenuItemCustom(
            title: localizations.pasteButtonLabel,
            onPressed: () => _handlePasteButton(pasteFallback),
          ),
        );
      }
      return SystemContextMenu.editableText(
        editableTextState: editableTextState,
        items: items,
      );
    }
    final items = <ContextMenuButtonItem>[];
    var pasteAdded = false;
    for (final button in editableTextState.contextMenuButtonItems) {
      if (button.type == ContextMenuButtonType.paste) {
        items.add(
          button.copyWith(onPressed: () => _handlePasteButton(button.onPressed)),
        );
        pasteAdded = true;
      } else {
        items.add(button);
      }
    }
    if (!pasteAdded && canPaste) {
      items.add(
        ContextMenuButtonItem(
          onPressed: () => _handlePasteButton(pasteFallback),
          type: ContextMenuButtonType.paste,
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
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
              onTap: () {
                Navigator.of(context).pop();
                _pickAndSendImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: kGold),
              title: const Text('Kamera', style: TextStyle(color: kText)),
              onTap: () {
                Navigator.of(context).pop();
                _openCamera();
              },
            ),
          ],
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
        // record sets its own AVAudioSessionCategoryOptions outright
        // (replacing, not merging with, whatever main.dart's shared
        // audio_session config set) — duckOthers has to be requested here
        // explicitly too, alongside the package's existing defaults, or
        // background audio wouldn't duck during recording specifically.
        iosConfig: const IosRecordConfig(
          categoryOptions: [
            IosAudioCategoryOption.defaultToSpeaker,
            IosAudioCategoryOption.allowBluetooth,
            IosAudioCategoryOption.allowBluetoothA2DP,
            IosAudioCategoryOption.duckOthers,
          ],
        ),
      ),
      path: _recordingPath!,
    );
    if (mounted) setState(() => _isRecording = true);
    _pulseController.repeat(reverse: true);
    _recordingStopwatch.reset();
    _recordingStopwatch.start();
    _rawAmplitudes.clear();
    _amplitudeSub = _audioRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen((amp) => _rawAmplitudes.add(amp.current));
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
    await _amplitudeSub?.cancel();
    setState(() => _recordingDuration = '0:00');
    final path = await _audioRecorder.stop();
    unawaited(_deactivateAudioSession());
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
    final waveform = _downsampleWaveform(_rawAmplitudes, 40);
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final replyingTo = _replyingTo;
    _cancelReply();
    // Hands the file to the offline-aware pending-send queue — see
    // _uploadAndSendVideoFile for why this doesn't upload inline anymore.
    final error = await ref
        .read(pendingMessageQueueProvider.notifier)
        .enqueue(
          chatId: widget.chatId,
          senderId: currentUid,
          type: 'audio',
          sourceFilePath: path,
          waveform: waveform,
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
          replyToVideoURL: replyingTo != null
              ? _replyVideoURL(replyingTo)
              : null,
        );
    if (mounted) setState(() => _uploadingAudio = false);
    if (error != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: kRed),
        );
      }
    } else {
      _scrollToBottom();
    }
  }

  Future<void> _cancelRecording() async {
    _recordingStopwatch.stop();
    _recordingTimer?.cancel();
    await _amplitudeSub?.cancel();
    await _audioRecorder.stop();
    unawaited(_deactivateAudioSession());
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


  // Collapses the raw dBFS samples captured during recording (one every
  // 100ms via onAmplitudeChanged) into a fixed number of bars for the
  // waveform display — WhatsApp shows the same bar count regardless of
  // clip length. Takes the peak within each bucket rather than the
  // average, matching how a waveform visually reads (loud transients
  // stay visible instead of getting smoothed away). floorDb/ceilDb are a
  // rough estimate of quiet-room/loud-speech mic levels; tune after
  // checking real recordings on-device.
  List<int> _downsampleWaveform(List<double> raw, int targetCount) {
    if (raw.isEmpty) return List.filled(targetCount, 0);
    const floorDb = -50.0;
    const ceilDb = -5.0;
    return List.generate(targetCount, (b) {
      final start = (b * raw.length / targetCount).floor();
      final end = (((b + 1) * raw.length / targetCount).ceil()).clamp(
        start + 1,
        raw.length,
      );
      final peak = raw.sublist(start, end).reduce((x, y) => x > y ? x : y);
      final norm =
          ((peak.clamp(floorDb, ceilDb) - floorDb) / (ceilDb - floorDb) * 100)
              .round();
      return norm.clamp(0, 100);
    });
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
    String? prevSenderId,
  ) {
    final isMe = msg.senderId == currentUid;
    // Tight vertical gap within a run of consecutive messages from the same
    // sender, wider gap when the sender changes — matches WhatsApp's
    // grouping. Controlled entirely by top margin so it only depends on the
    // relationship with the previous message, not the next.
    final isFirstInGroup = prevSenderId != msg.senderId;
    final time = msg.timestamp != null
        ? DateFormat('HH:mm').format(msg.timestamp!.toDate())
        : '';
    // checkIconData/isRead/isDelivered are the single source of truth for
    // delivery status — checkMark renders it in the bubble's own text color
    // (for text/audio/image bubbles), overlayCheckMark in a white-friendly
    // color for the video bubble's overlay atop arbitrary video content
    // (see VideoMessageBubble). Same status, two color treatments.
    IconData? checkIconData;
    Color checkColor = kMuted;
    Color overlayCheckColor = Colors.white70;
    bool isRead = false;
    bool isDelivered = false;
    if (msg.localSendStatus == 'queued' || msg.localSendStatus == 'uploading') {
      checkIconData = Icons.access_time;
      checkColor = const Color(0xFF1A0E00);
      overlayCheckColor = Colors.white70;
    } else if (msg.localSendStatus == 'failed') {
      checkIconData = Icons.error_outline;
      checkColor = kRed;
      overlayCheckColor = kRed;
    } else if (isMe && otherUid != null) {
      final lastReadId = lastReadMsgId[otherUid] as String?;
      final lastReadIndex = lastReadId != null
          ? allMsgIds.indexOf(lastReadId)
          : -1;
      isRead = lastReadIndex >= index && index != -1;
      isDelivered = deliveredTo[otherUid] != null || isRead;
      checkIconData = isDelivered ? Icons.done_all : Icons.done;
      checkColor = isRead ? kReadBlue : const Color(0xFF1A0E00).withAlpha(128);
      overlayCheckColor = isRead ? kReadBlue : Colors.white70;
    }
    final checkMark = checkIconData != null
        ? Icon(checkIconData, size: 14, color: checkColor)
        : null;
    final overlayCheckMark = checkIconData != null
        ? Icon(checkIconData, size: 14, color: overlayCheckColor)
        : null;
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
                top: isFirstInGroup ? 8 : 2,
                left: isMe ? 60 : 0,
                right: isMe ? 0 : 60,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: kBg3,
                border: Border.all(color: kBorder),
                borderRadius: BorderRadius.circular(_kBubbleRadius),
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
        onInfo: isMe && otherUid != null ? () => _openMessageInfo(msg) : null,
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
                  top: isFirstInGroup ? 8 : 2,
                  left: isMe ? 60 : 0,
                  right: isMe ? 0 : 60,
                ),
                // Video/photo fill the bubble edge-to-edge, like WhatsApp's
                // media bubbles — no inset chrome around them. Only when
                // there's no reply-to-quote card sharing the bubble; with
                // one present, the media keeps the normal padded chrome so
                // the quote card above it still reads correctly (a
                // chromeless-media-plus-quote layout is a separate,
                // not-yet-designed case).
                padding:
                    ((msg.type == 'video' || msg.type == 'image') &&
                        msg.replyToId == null)
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                decoration: BoxDecoration(
                  color: isMe ? kGold : kBg3,
                  borderRadius: BorderRadius.circular(_kBubbleRadius),
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
                                if (msg.replyToVideoURL != null)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: VideoThumbnailImage(
                                      videoURL: msg.replyToVideoURL!,
                                      size: 60,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (msg.type == 'text')
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: msg.text,
                              style: TextStyle(
                                color: isMe
                                    ? const Color(0xFF1A0E00)
                                    : kText,
                                fontSize: 14,
                              ),
                            ),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: _timeCheckmarkRow(
                                  isMe,
                                  otherUid,
                                  msg,
                                  time,
                                  checkMark,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (msg.type == 'image' &&
                        (msg.imageURL != null || msg.localFilePath != null))
                      ImageMessageBubble(
                        imageURL: msg.imageURL,
                        localFilePath: msg.localFilePath,
                        imageWidth: msg.imageWidth,
                        imageHeight: msg.imageHeight,
                        bubbleRadius: _kBubbleRadius,
                        onTap: msg.imageURL != null
                            ? () => showFullImage(context, msg.imageURL!)
                            : null,
                        timeCheckmarkOverlay: _timeCheckmarkRow(
                          isMe,
                          otherUid,
                          msg,
                          time,
                          overlayCheckMark,
                          textColor: Colors.white,
                        ),
                      ),
                    if (msg.type == 'audio' &&
                        (msg.audioURL != null || msg.localFilePath != null))
                      _VoiceMessagePlayer(
                        audioURL: msg.audioURL,
                        localFilePath: msg.localFilePath,
                        isMe: isMe,
                        waveform: msg.waveform,
                        senderId: msg.senderId,
                        // Sender-side "did they actually listen" status —
                        // only meaningful for a 1-1 chat's own sent
                        // message, same gating as the checkmarks above.
                        showListenedStatus: isMe && otherUid != null,
                        isRead: isRead,
                        listenedByOther:
                            otherUid != null &&
                            msg.listenedBy.contains(otherUid),
                        listenedByMe: msg.listenedBy.contains(currentUid),
                        onListened:
                            msg.type == 'audio' &&
                                msg.senderId != currentUid &&
                                msg.localSendStatus == null &&
                                !msg.listenedBy.contains(currentUid)
                            ? () => ref
                                  .read(firestoreServiceProvider)
                                  .markVoiceMessageListened(
                                    chatId: widget.chatId,
                                    messageId: msg.id,
                                    uid: currentUid,
                                  )
                            : null,
                        timeCheckmarkRow: _timeCheckmarkRow(
                          isMe,
                          otherUid,
                          msg,
                          time,
                          checkMark,
                        ),
                      ),
                    if (msg.type == 'video' &&
                        (msg.videoURL != null || msg.localFilePath != null))
                      VideoMessageBubble(
                        videoURL: msg.videoURL,
                        localFilePath: msg.localFilePath,
                        durationMs: msg.videoDurationMs,
                        videoWidth: msg.videoWidth,
                        videoHeight: msg.videoHeight,
                        bubbleRadius: _kBubbleRadius,
                        timeCheckmarkOverlay: _timeCheckmarkRow(
                          isMe,
                          otherUid,
                          msg,
                          time,
                          overlayCheckMark,
                          textColor: Colors.white,
                        ),
                      ),
                    if (msg.type != 'text' &&
                        msg.type != 'video' &&
                        msg.type != 'image' &&
                        msg.type != 'audio') ...[
                      const SizedBox(height: 2),
                      _timeCheckmarkRow(isMe, otherUid, msg, time, checkMark),
                    ],
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

  // Shared by every bubble type's time+checkmark display — text renders it
  // inline via a WidgetSpan (see _buildMessageBubble), every other type
  // renders it as its own row. checkMark/time are passed in already computed
  // so this stays pure layout, no duplicated status logic. textColor
  // defaults to the normal bubble-background-aware color; the video bubble
  // overrides it to white since this row sits as an overlay atop arbitrary
  // video content there instead of the bubble's flat background.
  Widget _timeCheckmarkRow(
    bool isMe,
    String? otherUid,
    Message msg,
    String time,
    Widget? checkMark, {
    Color? textColor,
  }) {
    return GestureDetector(
      onTap: isMe && otherUid != null ? () => _openMessageInfo(msg) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            time,
            style: TextStyle(
              color:
                  textColor ??
                  (isMe ? const Color(0xFF1A0E00).withAlpha(150) : kMuted),
              fontSize: 10,
            ),
          ),
          if (checkMark != null) ...[const SizedBox(width: 3), checkMark],
        ],
      ),
    );
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
    final liveMessagesAsync = ref.watch(messagesProvider(widget.chatId));
    // Before the live stream has delivered its first snapshot (cold start,
    // or currently offline), fall back to the last cached messages so the
    // screen doesn't just show a spinner. The live stream always wins once
    // it has data — this never overrides it.
    AsyncValue<List<Message>> messagesAsync = liveMessagesAsync;
    if (!liveMessagesAsync.hasValue) {
      final cachedMessages = ref.watch(cachedMessagesProvider(widget.chatId));
      if (cachedMessages != null) {
        messagesAsync = AsyncValue.data(cachedMessages);
      }
    }
    final chatDataAsync = ref.watch(chatDataProvider(widget.chatId));
    // Keeps the starred-ids stream subscribed so _isMessageStarred's
    // ref.read reflects live data in the message options sheet.
    ref.watch(starredMessagesProvider(currentUid));

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
      next.whenData((messages) {
        _messagesPendingCacheFlush = messages;
        _messageCacheService.writeDebounced(widget.chatId, messages);
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
    // mugam-v2 writes a 1:1 chat's `name` field from the initiator's
    // perspective at creation time (the other participant's name) and never
    // updates it — the recipient reading it back sees their OWN name
    // instead of the initiator's (same root cause fixed for the chat list
    // in _ChatListItem; the AppBar title here was never updated to match).
    final otherUser = otherUidResolved != null
        ? ref.watch(userByIdProvider(otherUidResolved)).value
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
          data: (data) {
            final isGroup = data?['isGroup'] == true;
            final displayName = (!isGroup && otherUser != null)
                ? otherUser.name
                : (data?['name'] ?? 'Chat');
            final titleColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  style: GoogleFonts.playfairDisplay(fontSize: 16, color: kText),
                ),
                if (!isGroup)
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
            );
            // Group chats don't have a single "contact" to show info about —
            // the About Contact screen is scoped to 1:1 chats for now.
            if (isGroup || otherUidResolved == null) return titleColumn;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AboutContactScreen(
                    chatId: widget.chatId,
                    contactUid: otherUidResolved,
                  ),
                ),
              ),
              child: titleColumn,
            );
          },
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
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _dismissComposerFocusOnOutsideTap(),
              child: messagesAsync.when(
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
                      // Not-yet-sent photo/voice/video messages, rendered as
                      // synthetic Messages through the same bubble/checkmark
                      // pipeline — always after every confirmed message,
                      // matching how an outgoing send-in-progress sits at
                      // the bottom until it's confirmed.
                      final pendingForChat = ref.watch(
                        pendingMessagesForChatProvider(widget.chatId),
                      );
                      final combinedMessages = [
                        ...visibleMessages,
                        ...pendingForChat.map((p) => p.toSyntheticMessage()),
                      ];
                      _lastMessages = combinedMessages;
                      _schedulePurgeTimers(visibleMessages);
                      if (!_hasJumpedToBottomInitially &&
                          combinedMessages.isNotEmpty) {
                        _hasJumpedToBottomInitially = true;
                        final targetId = widget.initialHighlightMessageId;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (targetId != null) {
                            _scrollToMessage(targetId);
                          } else {
                            _jumpToBottom();
                          }
                        });
                      }
                      final allMsgIds = combinedMessages
                          .map((m) => m.id)
                          .toList();
                      return ListView.builder(
                        controller: _scrollController,
                        reverse: false,
                        itemCount: combinedMessages.length,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        itemBuilder: (ctx, i) => _buildMessageBubble(
                          combinedMessages[i],
                          i,
                          allMsgIds,
                          currentUid,
                          otherUidResolved,
                          deliveredTo,
                          lastReadMsgId,
                          i > 0 ? combinedMessages[i - 1].senderId : null,
                        ),
                      );
                    },
                  ),
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
                    if (_replyingTo!.type == 'video' &&
                        _replyingTo!.videoURL != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: VideoThumbnailImage(
                          videoURL: _replyingTo!.videoURL!,
                          size: 44,
                        ),
                      ),
                    Center(
                      child: GestureDetector(
                        onTap: _cancelReply,
                        behavior: HitTestBehavior.opaque,
                        child: const SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(Icons.close, color: kMuted, size: 18),
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
                      icon: (_uploadingImage || _uploadingVideo)
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: kGold,
                              ),
                            )
                          : const Icon(Icons.attach_file, color: kGold),
                      onPressed: (_uploadingImage || _uploadingVideo)
                          ? null
                          : _showAttachSheet,
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
                            contextMenuBuilder: _buildMessageContextMenu,
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

                  const SizedBox(width: 4),

                  // Camera — same slot/visibility as the mic button, matching
                  // WhatsApp's camera-next-to-mic layout. "Kamera" stays in
                  // the attach sheet too (WhatsApp keeps it in both places).
                  if (!_hasText && !_isRecording)
                    IconButton(
                      icon: const Icon(Icons.camera_alt, color: kGold),
                      onPressed: (_uploadingImage || _uploadingVideo)
                          ? null
                          : _openCamera,
                    ),

                  const SizedBox(width: 4),

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
  final VoidCallback? onInfo;
  const _SwipeableMessageBubble({
    required this.child,
    required this.onReply,
    this.onLongPress,
    this.onInfo,
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
    final rightProgress = (_dragX / _maxDrag).clamp(0.0, 1.0);
    final leftProgress = (-_dragX / _maxDrag).clamp(0.0, 1.0);
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
                opacity: rightProgress,
                child: Transform.scale(
                  scale: 0.5 + rightProgress * 0.5,
                  child: const Icon(Icons.reply, color: kGold, size: 22),
                ),
              ),
            ),
          ),
        if (_dragX < 0 && widget.onInfo != null)
          Positioned(
            right: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: Opacity(
                opacity: leftProgress,
                child: Transform.scale(
                  scale: 0.5 + leftProgress * 0.5,
                  child: const Icon(Icons.info_outline, color: kGold, size: 22),
                ),
              ),
            ),
          ),
        GestureDetector(
          onLongPress: widget.onLongPress,
          onHorizontalDragUpdate: (details) {
            final minDrag = widget.onInfo != null ? -_maxDrag : 0.0;
            final next = (_dragX + details.delta.dx).clamp(minDrag, _maxDrag);
            if (next != _dragX) setState(() => _dragX = next);
          },
          onHorizontalDragEnd: (_) {
            if (_dragX >= _triggerThreshold) {
              widget.onReply();
            } else if (_dragX <= -_triggerThreshold && widget.onInfo != null) {
              widget.onInfo!();
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
  final String? audioURL;
  final String? localFilePath;
  final bool isMe;
  final List<int>? waveform;
  final String senderId;
  final Widget timeCheckmarkRow;
  // Sender-side "did the recipient actually listen" status — see
  // markVoiceMessageListened. Only meaningful (and only passed as true)
  // for a 1-1 chat's own sent message; group chats/incoming bubbles get
  // showListenedStatus: false and render exactly as before.
  final bool showListenedStatus;
  final bool isRead;
  final bool listenedByOther;
  // Recipient-side "have I (the current user) listened to this incoming
  // message" status — mirrors listenedByOther but checks currentUid
  // instead of otherUid against the same listenedBy array. Only
  // meaningful for !isMe; harmless (unused) otherwise.
  final bool listenedByMe;
  final VoidCallback? onListened;
  const _VoiceMessagePlayer({
    this.audioURL,
    this.localFilePath,
    required this.isMe,
    this.waveform,
    required this.senderId,
    required this.timeCheckmarkRow,
    this.showListenedStatus = false,
    this.isRead = false,
    this.listenedByOther = false,
    this.listenedByMe = false,
    this.onListened,
  });

  @override
  State<_VoiceMessagePlayer> createState() => _VoiceMessagePlayerState();
}

// Ensures only one voice message plays at a time app-wide, mirroring
// WhatsApp: starting a new one pauses whatever was previously playing,
// regardless of which chat it's in. A plain singleton rather than Riverpod
// state — this coordinates transient in-memory playback, not app data, and
// only ever has at most one interested reader (the currently active
// player) at a time.
class _VoiceMessageCoordinator {
  _VoiceMessageCoordinator._();
  static final instance = _VoiceMessageCoordinator._();

  _VoiceMessagePlayerState? _active;

  void starting(_VoiceMessagePlayerState player) {
    if (_active != null && _active != player) {
      _active!._pauseFromCoordinator();
    }
    _active = player;
  }

  void stopped(_VoiceMessagePlayerState player) {
    if (_active == player) _active = null;
  }
}

class _VoiceMessagePlayerState extends State<_VoiceMessagePlayer> {
  // +30% over the previous 44, per feedback that the avatar read too
  // small next to the play button/waveform.
  static const double _avatarSize = 57;
  late final AudioPlayer _player;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _listenedFired = false;
  // Set right before the coordinator pauses this player to hand off to a
  // different message. Suppresses the deactivateAudioSession() call below
  // for that one transition — the incoming player is about to activate the
  // shared session again immediately, and racing our own deactivate against
  // its activate was silencing audio while still visually "playing" (same
  // race as the loop/alternation bug, triggered here by fast play-switching
  // between messages instead of natural completion).
  bool _pausedByCoordinator = false;

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
        // just_audio's audio_session integration handles responding to
        // interruptions (calls, etc.) but never sends the explicit "I'm
        // done" signal that lets iOS un-duck other apps on pause — same
        // gap already fixed for recording and video playback elsewhere in
        // this file/video_message_widgets.dart. Catch the true->false
        // edge here before overwriting _isPlaying below.
        final wasPlaying = _isPlaying;
        setState(() => _isPlaying = state.playing);
        if (wasPlaying && !state.playing) {
          if (_pausedByCoordinator) {
            _pausedByCoordinator = false;
          } else {
            unawaited(_deactivateAudioSession());
          }
        }
        if (state.playing && !_listenedFired) {
          _listenedFired = true;
          widget.onListened?.call();
        }
        if (state.processingState == ProcessingState.completed) {
          // just_audio doesn't clear its own `playing` flag on completion —
          // only pause()/stop() do. Without an explicit pause() here,
          // seeking back to zero while `playing` is still true makes the
          // player resume from the new position, i.e. loop forever instead
          // of stopping.
          unawaited(_player.pause());
          _player.seek(Duration.zero);
          setState(() => _isPlaying = false);
        }
      }
    });
    final localPath = widget.localFilePath;
    if (localPath != null) {
      _player.setFilePath(localPath);
    } else if (widget.audioURL != null) {
      _player.setUrl(widget.audioURL!);
    }
  }

  void _pauseFromCoordinator() {
    if (mounted) {
      _pausedByCoordinator = true;
      _player.pause();
    }
  }

  @override
  void dispose() {
    if (_isPlaying) unawaited(_deactivateAudioSession());
    _VoiceMessageCoordinator.instance.stopped(this);
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
    final labelColor = widget.isMe ? const Color(0xFF1A0E00) : kText;
    final accentColor = widget.isMe ? const Color(0xFF1A0E00) : kGold;
    final total = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : 1.0;
    final current = _position.inMilliseconds.toDouble().clamp(0.0, total);
    final playedFraction = (current / total).clamp(0.0, 1.0);

    final playButton = GestureDetector(
      onTap: () async {
        if (_isPlaying) {
          await _player.pause();
        } else {
          _VoiceMessageCoordinator.instance.starting(this);
          await _player.play();
        }
      },
      child: Icon(
        _isPlaying ? Icons.pause : Icons.play_arrow,
        color: accentColor,
        size: 32,
      ),
    );

    // Sender-only listened-status coloring — same three states as
    // WhatsApp's own read receipts, layered on top of (not replacing) the
    // existing isRead/isDelivered checkmark logic: not read yet (dark
    // gray — kUnreadGray, not kMuted, which is too close to the gold
    // bubble's own brightness to read as "unread"), read but not listened
    // to (blue dot, kMuted wave — deliberately a different, lighter gray
    // than kUnreadGray so the two states don't look the same), read and
    // listened to (blue dot and wave). Group chats (no otherUid) keep
    // today's plain accent look untouched.
    Color dotColor = kReadBlue;
    Color playedColor = accentColor;
    if (widget.showListenedStatus) {
      if (!widget.isRead) {
        dotColor = kUnreadGray;
        playedColor = kUnreadGray;
      } else if (!widget.listenedByOther) {
        dotColor = kReadBlue;
        playedColor = kMuted;
      } else {
        dotColor = kReadBlue;
        playedColor = kListenedBlue;
      }
    } else if (!widget.isMe) {
      // Recipient-side status for an incoming message: bold saturated
      // blue (same kListenedBlue as the sender-side "listened" state)
      // while I haven't played it yet — attention-grabbing, "new" — then
      // dark gray once I have, same listenedBy array as showListenedStatus
      // above, just checked against currentUid (listenedByMe) instead of
      // otherUid.
      dotColor = widget.listenedByMe ? kUnreadGray : kListenedBlue;
      playedColor = widget.listenedByMe ? kUnreadGray : kListenedBlue;
    }
    // Widens the wave's bars — same "listened" signal as the color above,
    // just inverted for the incoming case: sender-side thick means the
    // recipient already listened (settled), incoming-side thick means I
    // HAVEN'T yet (still demanding attention) and reverts to normal width
    // once I have.
    final isThickWave = widget.showListenedStatus
        ? (widget.isRead && widget.listenedByOther)
        : (!widget.isMe && !widget.listenedByMe);

    final wave = Expanded(
      child: _WaveformSeekBar(
        levels: widget.waveform,
        playedFraction: playedFraction,
        playedColor: playedColor,
        dotColor: dotColor,
        thick: isThickWave,
        onSeek: (fraction) =>
            _player.seek(Duration(milliseconds: (fraction * total).round())),
      ),
    );

    final avatar = _VoiceSenderAvatar(
      senderId: widget.senderId,
      size: _avatarSize,
    );

    // Avatar sits toward the middle of the screen in both cases — right of
    // the wave for an incoming (left-aligned) bubble, left of it for an
    // outgoing (right-aligned) one — matching the reference screenshots.
    final row = widget.isMe
        ? [avatar, const SizedBox(width: 8), playButton, const SizedBox(width: 6), wave]
        : [playButton, const SizedBox(width: 6), wave, const SizedBox(width: 8), avatar];

    // Position label always sits under the play button specifically, not
    // just at the row's leading edge — when isMe puts the avatar first,
    // it needs a leading indent matching the avatar's width + spacing to
    // land in the same place it already does for the !isMe case (where
    // the play button already is the leading element).
    final positionIndent = widget.isMe ? _avatarSize + 8 : 0.0;

    return SizedBox(
      width: 230,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: row),
          const SizedBox(height: 2),
          Row(
            children: [
              Padding(
                padding: EdgeInsets.only(left: positionIndent),
                child: Text(
                  _fmt(_position),
                  style: TextStyle(
                    color: labelColor.withAlpha(150),
                    fontSize: 10,
                  ),
                ),
              ),
              const Spacer(),
              // Mirrors positionIndent above: !isMe's avatar sits flush at
              // the row's right edge (see `row` above), so without this
              // the time+checkmark ends up right underneath it with no
              // gap. isMe doesn't need this — its avatar is at the left,
              // nowhere near this right-aligned element.
              Padding(
                padding: EdgeInsets.only(
                  right: widget.isMe ? 0 : _avatarSize + 8,
                ),
                child: widget.timeCheckmarkRow,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Static bars + draggable position dot, replacing the old continuous
// Slider — matches WhatsApp's segmented-waveform look. levels is the
// 0-100 normalized amplitude captured during recording (see
// _downsampleWaveform); null (message sent before that field existed)
// falls back to a flat, honest "no data" bar pattern rather than
// pretending to show a real waveform.
class _WaveformSeekBar extends StatefulWidget {
  final List<int>? levels;
  final double playedFraction;
  final Color playedColor;
  final Color dotColor;
  // Widens every bar (played and unplayed alike) once the recipient has
  // listened — independent of the played/unplayed color split below, which
  // stays keyed off playedFraction regardless of this flag.
  final bool thick;
  final ValueChanged<double> onSeek;

  const _WaveformSeekBar({
    required this.levels,
    required this.playedFraction,
    required this.playedColor,
    required this.dotColor,
    required this.thick,
    required this.onSeek,
  });

  @override
  State<_WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<_WaveformSeekBar> {
  static const double _barAreaHeight = 22;
  static const double _minBarHeight = 3;
  static const double _dotVisualSize = 14;
  // Bigger than the visual dot, per Apple/Material minimum-touch-target
  // guidance — the drawn circle stays small so it doesn't dominate the
  // waveform, but the draggable hit region around it is generous.
  static const double _dotHitSize = 44;

  // Absolute bar-local x of the dot while a drag on it is in progress —
  // set on drag start and accumulated by delta.dx on each update (rather
  // than derived from widget.playedFraction, which only updates once the
  // async player.seek()'s position-stream round trip lands, too slow to
  // track a fast finger movement 1:1). Stays set after the finger lifts,
  // too — cleared below once the real position stream catches up, rather
  // than immediately on release, so the dot doesn't snap back to the
  // stale pre-seek position and then jump forward again once the seek
  // resolves. Null when not mid-drag and not waiting on a catch-up.
  double? _dragX;

  @override
  Widget build(BuildContext context) {
    final bars = widget.levels ?? List.filled(28, 35);
    return LayoutBuilder(
      builder: (context, constraints) {
        void seekAtX(double dx) {
          widget.onSeek((dx / constraints.maxWidth).clamp(0.0, 1.0));
        }

        if (_dragX != null &&
            (widget.playedFraction * constraints.maxWidth - _dragX!).abs() <
                3) {
          _dragX = null;
        }
        final dotCenterX =
            _dragX ?? widget.playedFraction * constraints.maxWidth;
        // Same visual-vs-real split as the dot above, applied to the
        // played/unplayed bar coloring too — without this the bars' fill
        // boundary was still driven straight off widget.playedFraction (the
        // real, stream-lagged position), so the wave's own color edge kept
        // jumping/lagging behind the finger even after the dot itself
        // started following it immediately.
        final visualFraction = dotCenterX / constraints.maxWidth;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: [
            // Tap/drag anywhere on the bar seeks there — this is the
            // OUTER detector; the dot below gets its own nested one so
            // grabbing the dot specifically is a Flutter gesture-arena
            // child, which takes priority over both this bar detector and
            // the ancestor bubble's long-press/swipe-to-reply detectors,
            // isolating a dot-drag from triggering either of those.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                // A tap has no separate "end" event, so commit the real
                // seek right away — this is a single discrete action, not
                // a per-frame stream of them, so there's no jank risk here.
                setState(() => _dragX = d.localPosition.dx);
                seekAtX(d.localPosition.dx);
              },
              onHorizontalDragUpdate: (d) {
                // Visual only during the drag itself — move the dot/wave
                // immediately, in step with the touch. The real seek() is
                // deliberately NOT called per-frame here: firing it dozens
                // of times a second was hammering the native audio engine
                // via the platform channel, which was the actual source of
                // the stutter/hesitation, not the visual state update
                // itself. It fires once, on release, in onHorizontalDragEnd
                // below — matching WhatsApp's own scrub behavior (silent
                // while dragging, seeks once on release).
                setState(() => _dragX = d.localPosition.dx);
              },
              onHorizontalDragEnd: (_) {
                if (_dragX != null) seekAtX(_dragX!);
              },
              onHorizontalDragCancel: () {
                if (_dragX != null) seekAtX(_dragX!);
              },
              child: SizedBox(
                height: _barAreaHeight,
                width: double.infinity,
                child: Row(
                  children: [
                    for (var i = 0; i < bars.length; i++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: widget.thick ? 0.5 : 1,
                          ),
                          child: Container(
                            height:
                                _minBarHeight +
                                (bars[i].clamp(0, 100) / 100) *
                                    (_barAreaHeight - _minBarHeight),
                            decoration: BoxDecoration(
                              // 150 rather than the previous 70 — at
                              // position 0 (not yet playing), every bar is
                              // "unplayed" and was rendering the whole
                              // wave at low alpha, making it barely
                              // visible before playback starts.
                              color: (i / bars.length) <= visualFraction
                                  ? widget.playedColor
                                  : widget.playedColor.withAlpha(150),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: (dotCenterX - _dotHitSize / 2).clamp(
                -_dotHitSize / 2,
                constraints.maxWidth - _dotHitSize / 2,
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) =>
                    setState(() => _dragX = dotCenterX),
                onHorizontalDragUpdate: (d) {
                  // Visual only, same reasoning as the outer detector above
                  // — no per-frame seek() call, just the local dot/wave
                  // position, to keep dragging jank-free.
                  final next = (_dragX ?? dotCenterX) + d.delta.dx;
                  setState(() => _dragX = next);
                },
                // Deliberately NOT clearing _dragX here — see the field's
                // doc comment. It's released once widget.playedFraction
                // (driven by the player's position stream) catches up to
                // wherever the finger let go, in the build method above.
                // The real seek() fires exactly once here, on release.
                onHorizontalDragEnd: (_) {
                  if (_dragX != null) seekAtX(_dragX!);
                },
                onHorizontalDragCancel: () {
                  if (_dragX != null) seekAtX(_dragX!);
                },
                child: SizedBox(
                  width: _dotHitSize,
                  height: _dotHitSize,
                  child: Center(
                    child: Container(
                      width: _dotVisualSize,
                      height: _dotVisualSize,
                      decoration: BoxDecoration(
                        color: widget.dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// Sender's avatar with a small mic badge, matching the reference. Uses
// userByIdProvider(senderId) uniformly for every sender — own messages,
// 1-1 chat partners, and group members alike — so group chats need no
// special-casing here; the provider already memoizes per uid, so repeated
// voice messages from the same sender share one fetch.
class _VoiceSenderAvatar extends ConsumerWidget {
  final String senderId;
  final double size;
  const _VoiceSenderAvatar({required this.senderId, required this.size});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userByIdProvider(senderId)).value;
    final photoURL = user?.photoURL;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: kBg3,
              shape: BoxShape.circle,
              image: photoURL != null
                  ? DecorationImage(
                      image: NetworkImage(photoURL),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: photoURL == null
                ? Center(
                    child: Text(
                      user?.emoji ?? '🎵',
                      style: const TextStyle(fontSize: 22),
                    ),
                  )
                : null,
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: const BoxDecoration(
                color: kBg2,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.mic, size: 14, color: kReadBlue),
            ),
          ),
        ],
      ),
    );
  }
}
