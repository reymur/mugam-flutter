import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  const ChatScreen({super.key, required this.chatId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _messageController = TextEditingController();
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
    _scrollController.dispose();
    _audioRecorder.dispose();
    _recordingTimer?.cancel();
    _pulseController.dispose();
    _beepPlayer.dispose();
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
            if (msg.type == 'audio' && msg.audioURL != null)
              _VoiceMessagePlayer(audioURL: msg.audioURL!, isMe: isMe),
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
                  const SizedBox(width: 48), // placeholder to keep layout stable

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
                                      (1.0 +
                                              _dragX /
                                                  _cancelThreshold.abs())
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
                            opacity:
                                (1.0 + _dragY / _lockThreshold.abs()).clamp(
                                  0.0,
                                  1.0,
                                ),
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
