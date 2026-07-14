import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../../core/media/image_compressor.dart';
import '../../../core/media/video_compressor.dart';
import '../../../core/settings/image_quality_settings.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../chat/screens/custom_camera_backup/camera_capture_screen.dart';

enum _EntryChoice { text, camera, gallery }

// Entry point for posting a new status — reached from StatusFeedBar's
// onCreateStatus (chats_screen.dart). Doesn't render any content of its
// own: opens the type-choice sheet immediately on first frame and pops
// itself once that whole flow (composer -> privacy picker -> post) either
// completes or is cancelled at any step. A bare Scaffold sits behind the
// sheet only as the thing Navigator.push needs a route for.
class CreateStatusScreen extends StatefulWidget {
  const CreateStatusScreen({super.key});

  @override
  State<CreateStatusScreen> createState() => _CreateStatusScreenState();
}

class _CreateStatusScreenState extends State<CreateStatusScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showTypeSheet());
  }

  Future<void> _showTypeSheet() async {
    // Same showModalBottomSheet styling as chat_screen.dart's own
    // attach-sheet (kBg2, rounded top corners, SafeArea+Padding, a Row of
    // icon-circle options) — see _AttachOption below for the per-option
    // widget, a local equivalent of chat_screen.dart's private
    // _AttachOption (not importable across files).
    final choice = await showModalBottomSheet<_EntryChoice>(
      context: context,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _AttachOption(
                icon: Icons.text_fields,
                color: kGold,
                label: 'Mətn',
                onTap: () =>
                    Navigator.of(sheetContext).pop(_EntryChoice.text),
              ),
              _AttachOption(
                icon: Icons.camera_alt,
                color: kMuted,
                label: 'Kamera',
                onTap: () =>
                    Navigator.of(sheetContext).pop(_EntryChoice.camera),
              ),
              _AttachOption(
                icon: Icons.photo_library,
                color: const Color(0xFF2196F3),
                label: 'Qalereya',
                onTap: () =>
                    Navigator.of(sheetContext).pop(_EntryChoice.gallery),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;

    switch (choice) {
      case _EntryChoice.text:
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const _TextStatusComposer()),
        );
      case _EntryChoice.camera:
        final captured = await Navigator.of(context).push<CapturedMedia>(
          MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
        );
        if (captured != null && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _MediaStatusComposer(
                filePath: captured.path,
                isVideo: captured.isVideo,
              ),
            ),
          );
        }
      case _EntryChoice.gallery:
        final picked = await ImagePicker().pickMedia();
        if (picked != null && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _MediaStatusComposer(
                filePath: picked.path,
                isVideo: _isVideoPath(picked.path),
              ),
            ),
          );
        }
      case null:
        break;
    }
    // Whatever happened above — cancelled at any step, or a successful
    // post already popped the whole stack via popUntil(first), which also
    // removes this screen's own route (it isn't the first route either) —
    // this screen itself has nothing left to show. canPop(), not mounted:
    // mounted only reflects whether this State has been disposed yet, not
    // whether the Navigator still has a route above the current one to pop,
    // and popUntil(first) already leaving zero poppable routes was exactly
    // what triggered GoRouter's "popped the last page off of the stack"
    // assertion here.
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  // Same extension-check pattern chat_screen.dart's own _isVideoPath uses
  // to route a gallery pickMedia() result.
  bool _isVideoPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.avi');
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: kBg);
  }
}

class _AttachOption extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _AttachOption({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(color: kText, fontSize: 13)),
        ],
      ),
    );
  }
}

// Full-screen text-status composer. Fixed kBg2 background — MUST match
// StatusViewerScreen's own text-status _MediaContent background exactly,
// since that's what the viewer will render this status against later.
// TextField styling (rounded pill, kBg3 fill, borderless) mirrors
// chat_screen.dart's inline message TextField.
class _TextStatusComposer extends StatefulWidget {
  const _TextStatusComposer();

  @override
  State<_TextStatusComposer> createState() => _TextStatusComposerState();
}

class _TextStatusComposerState extends State<_TextStatusComposer> {
  final TextEditingController _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PrivacyPickerScreen(type: 'text', text: text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg2,
      appBar: AppBar(
        backgroundColor: kBg2,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: kText),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _hasText ? _next : null,
            child: Text(
              'İrəli',
              style: TextStyle(
                color: kGold.withAlpha(_hasText ? 255 : 100),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: TextField(
            controller: _controller,
            autofocus: true,
            maxLines: null,
            textAlign: TextAlign.center,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(
              color: kText,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
            decoration: InputDecoration(
              hintText: 'Status yazın...',
              hintStyle: const TextStyle(color: kMuted),
              filled: true,
              fillColor: kBg3,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Full-screen preview for a picked/captured photo or video, with an
// optional caption field. Video preview is a plain local VideoPlayerController
// — no caching, no duration-reporting, no pause-on-long-press chrome like
// StatusVideoPlayer has, since none of that applies to a local file being
// previewed once before upload.
class _MediaStatusComposer extends StatefulWidget {
  final String filePath;
  final bool isVideo;

  const _MediaStatusComposer({
    required this.filePath,
    required this.isVideo,
  });

  @override
  State<_MediaStatusComposer> createState() => _MediaStatusComposerState();
}

class _MediaStatusComposerState extends State<_MediaStatusComposer> {
  static const Duration _maxVideoDuration = Duration(seconds: 30);

  final TextEditingController _captionController = TextEditingController();
  VideoPlayerController? _videoController;
  bool _videoTooLong = false;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) _setupVideo();
  }

  Future<void> _setupVideo() async {
    final controller = VideoPlayerController.file(File(widget.filePath));
    try {
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _videoController = controller;
        _videoTooLong = controller.value.duration > _maxVideoDuration;
      });
      // Preview-only convenience so the user can see the whole clip
      // without manually replaying it — no bearing on what gets uploaded.
      controller.setLooping(true);
      controller.play();
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: '_MediaStatusComposer: video initialize failed',
      );
    }
  }

  @override
  void dispose() {
    _captionController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  void _next() {
    // Duration isn't known until the controller finishes initializing —
    // block Next until then rather than risk letting an over-limit video
    // through on a fast tap before _setupVideo's setState lands.
    if (widget.isVideo && _videoController == null) return;
    if (widget.isVideo && _videoTooLong) {
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: kBg2,
          title: const Text(
            'Video çox uzundur',
            style: TextStyle(color: kText),
          ),
          content: const Text(
            'Video 30 saniyədən uzun ola bilməz.',
            style: TextStyle(color: kMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Tamam', style: TextStyle(color: kGold)),
            ),
          ],
        ),
      );
      return;
    }
    final caption = _captionController.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PrivacyPickerScreen(
          type: widget.isVideo ? 'video' : 'image',
          localFilePath: widget.filePath,
          caption: caption.isEmpty ? null : caption,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.isVideo)
            (_videoController != null && _videoController!.value.isInitialized)
                ? Center(
                    child: AspectRatio(
                      aspectRatio: _videoController!.value.aspectRatio,
                      child: VideoPlayer(_videoController!),
                    ),
                  )
                : const Center(
                    child: CircularProgressIndicator(color: kGold),
                  )
          else
            Center(
              child: Image.file(File(widget.filePath), fit: BoxFit.contain),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _captionController,
                      style: const TextStyle(color: kText, fontSize: 14),
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Başlıq əlavə edin...',
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
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _next,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: kGold,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_forward,
                        color: Color(0xFF1A0E00),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _PrivacyMode { contacts, contactsExcept, onlyShareWith }

// Last step before a status actually posts — reached from either
// composer's "next" action, not a separate detour after. Its own
// "Paylaş" action is what triggers compress -> upload -> createStatus
// (see _post), then pops the entire pushed stack back to ChatsScreen in
// one go on success.
class _PrivacyPickerScreen extends ConsumerStatefulWidget {
  final String type; // 'text' | 'image' | 'video'
  final String? text;
  final String? localFilePath;
  final String? caption;

  const _PrivacyPickerScreen({
    required this.type,
    this.text,
    this.localFilePath,
    this.caption,
  });

  @override
  ConsumerState<_PrivacyPickerScreen> createState() =>
      _PrivacyPickerScreenState();
}

class _PrivacyPickerScreenState extends ConsumerState<_PrivacyPickerScreen> {
  _PrivacyMode _mode = _PrivacyMode.contacts;
  final Set<String> _selectedUids = {};
  bool _posting = false;

  void _toggleUser(String uid) {
    setState(() {
      if (_selectedUids.contains(uid)) {
        _selectedUids.remove(uid);
      } else {
        _selectedUids.add(uid);
      }
    });
  }

  Future<void> _post() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) return;
    setState(() => _posting = true);
    try {
      final firestoreService = ref.read(firestoreServiceProvider);
      final statusId = firestoreService.newStatusId(currentUid);
      String? mediaUrl;
      final localFilePath = widget.localFilePath;
      if (localFilePath != null) {
        final hd = ref.read(hdImageUploadProvider);
        final isVideo = widget.type == 'video';
        final fileName =
            '${DateTime.now().microsecondsSinceEpoch}.${isVideo ? 'mp4' : 'jpg'}';
        if (isVideo) {
          final compressedPath = await compressVideoFile(
            localFilePath,
            hd: hd,
          );
          mediaUrl = await firestoreService.uploadStatusVideo(
            ownerUid: currentUid,
            statusId: statusId,
            filePath: compressedPath,
            fileName: fileName,
          );
        } else {
          final compressedPath = await compressImageFile(
            localFilePath,
            hd: hd,
          );
          mediaUrl = await firestoreService.uploadStatusImage(
            ownerUid: currentUid,
            statusId: statusId,
            filePath: compressedPath,
            fileName: fileName,
          );
        }
      }
      final privacyMode = switch (_mode) {
        _PrivacyMode.contacts => 'contacts',
        _PrivacyMode.contactsExcept => 'contactsExcept',
        _PrivacyMode.onlyShareWith => 'onlyShareWith',
      };
      await firestoreService.createStatus(
        statusId: statusId,
        ownerUid: currentUid,
        type: widget.type,
        mediaUrl: mediaUrl,
        text: widget.text,
        caption: widget.caption,
        privacyMode: privacyMode,
        privacyList: _mode == _PrivacyMode.contacts
            ? const []
            : _selectedUids.toList(),
      );
      if (!mounted) return;
      // One pop all the way back to ChatsScreen instead of unwinding the
      // composer -> type-sheet-screen chain one route at a time — this is
      // the flow's actual terminal success state.
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: '_PrivacyPickerScreen: status post failed',
      );
      if (!mounted) return;
      setState(() => _posting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Status paylaşılmadı'),
          backgroundColor: kRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final contactsAsync = ref.watch(myContactsProvider(currentUid));
    final showMultiselect = _mode != _PrivacyMode.contacts;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        automaticallyImplyLeading: false,
        leading: TextButton(
          onPressed: _posting ? null : () => Navigator.of(context).pop(),
          child: const Text('Geri', style: TextStyle(color: kMuted)),
        ),
        title: const Text(
          'Kim görə bilər?',
          style: TextStyle(color: kText, fontSize: 16),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _posting ? null : _post,
            child: _posting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kGold,
                    ),
                  )
                : const Text(
                    'Paylaş',
                    style: TextStyle(
                      color: kGold,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          _PrivacyOptionTile(
            label: 'Kontaktlar',
            subtitle: 'Bütün kontaktlarınız görə bilər',
            selected: _mode == _PrivacyMode.contacts,
            onTap: () => setState(() => _mode = _PrivacyMode.contacts),
          ),
          _PrivacyOptionTile(
            label: 'Kontaktlar, xaric...',
            subtitle: 'Seçilmiş kontaktlar istisna olmaqla',
            selected: _mode == _PrivacyMode.contactsExcept,
            onTap: () =>
                setState(() => _mode = _PrivacyMode.contactsExcept),
          ),
          _PrivacyOptionTile(
            label: 'Yalnız seçilmiş...',
            subtitle: 'Yalnız seçilmiş kontaktlar görə bilər',
            selected: _mode == _PrivacyMode.onlyShareWith,
            onTap: () => setState(() => _mode = _PrivacyMode.onlyShareWith),
          ),
          if (showMultiselect) ...[
            const Divider(color: kBorder, height: 1),
            // Removable-chip row for already-selected contacts — same
            // visual language as CreateGroupScreen's own selected-member
            // chip row, reused directly rather than reinvented.
            if (_selectedUids.isNotEmpty)
              Container(
                height: 52,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: kBorder)),
                ),
                child: contactsAsync.when(
                  data: (contacts) {
                    final selected = contacts.where(
                      (u) => _selectedUids.contains(u.id),
                    );
                    return ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        for (final u in selected)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            child: GestureDetector(
                              onTap: () => _toggleUser(u.id),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: kBg3,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: kBorder),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      u.emoji,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                    const SizedBox(width: 4),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 80,
                                      ),
                                      child: Text(
                                        u.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: kText,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    const Text(
                                      '✕',
                                      style: TextStyle(
                                        color: kMuted,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                ),
              ),
            Expanded(
              child: contactsAsync.when(
                data: (contacts) {
                  if (contacts.isEmpty) {
                    return const Center(
                      child: Text(
                        'Kontakt tapılmadı',
                        style: TextStyle(color: kMuted),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: contacts.length,
                    itemBuilder: (context, index) {
                      final u = contacts[index];
                      final selected = _selectedUids.contains(u.id);
                      return ListTile(
                        onTap: () => _toggleUser(u.id),
                        leading: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: kBg3,
                            shape: BoxShape.circle,
                            border: selected
                                ? Border.all(color: kGold, width: 2)
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            u.emoji,
                            style: const TextStyle(fontSize: 20),
                          ),
                        ),
                        title: Text(
                          u.name,
                          style: const TextStyle(color: kText, fontSize: 14),
                        ),
                        trailing: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected ? kGold : Colors.transparent,
                            border: Border.all(
                              color: selected ? kGold : kBorder,
                              width: 2,
                            ),
                          ),
                          child: selected
                              ? const Icon(
                                  Icons.check,
                                  size: 14,
                                  color: Color(0xFF1A0E00),
                                )
                              : null,
                        ),
                      );
                    },
                  );
                },
                loading: () =>
                    const Center(child: CircularProgressIndicator(color: kGold)),
                error: (_, _) => const Center(
                  child: Text(
                    'Xəta baş verdi',
                    style: TextStyle(color: kMuted),
                  ),
                ),
              ),
            ),
          ] else
            const Spacer(),
        ],
      ),
    );
  }
}

// Radio-style single-select indicator (empty ring vs. gold-filled dot) —
// deliberately distinct from the multiselect list's gold-filled-checkmark
// tiles below, matching the plan's own "radio-style, single-select" call
// for these three top-level options vs. the contacts multiselect.
class _PrivacyOptionTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _PrivacyOptionTile({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      title: Text(
        label,
        style: const TextStyle(
          color: kText,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(subtitle, style: const TextStyle(color: kMuted, fontSize: 12)),
      trailing: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? kGold : kBorder, width: 2),
        ),
        alignment: Alignment.center,
        child: selected
            ? Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: kGold,
                ),
              )
            : null,
      ),
    );
  }
}
