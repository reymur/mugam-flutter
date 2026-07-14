import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';
import 'dart:typed_data';

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
    // Loops: cancelling a composer (X) or an image/camera picker returns
    // here and re-shows the type-choice sheet, rather than closing this
    // whole screen — only dismissing the sheet itself (tapping outside
    // it, choice == null) or a successful post exits the loop. canPop()
    // after each iteration (not mounted) distinguishes "composer was
    // simply popped, we're still here" from "a post's popUntil(first)
    // already collapsed the whole stack including this screen's own
    // route" — mounted alone can't tell these apart, same lesson as the
    // final canPop() check below.
    while (mounted && Navigator.of(context).canPop()) {
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
      if (choice == null) break;

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
      }
      // If a post succeeded, its popUntil(first) already collapsed the
      // stack including this screen's own route — stop looping instead
      // of trying to re-show a sheet on a screen that's already gone.
      if (!mounted || !Navigator.of(context).canPop()) return;
    }
    // Loop exited via `break` (sheet itself dismissed) — nothing left to
    // show, close this screen. canPop(), not mounted: mounted only
    // reflects whether this State has been disposed yet, not whether the
    // Navigator still has a route above the current one to pop.
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
        builder: (_) => PrivacyPickerScreen(type: 'text', text: text),
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
      _showTrimChoiceDialog();
      return;
    }
    final caption = _captionController.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PrivacyPickerScreen(
          type: widget.isVideo ? 'video' : 'image',
          localFilePath: widget.filePath,
          caption: caption.isEmpty ? null : caption,
        ),
      ),
    );
  }

  // Real WhatsApp choice for over-limit video, confirmed via search: before
  // WhatsApp had a manual trim UI, it auto-split long video into
  // consecutive ≤30s segments covering the whole clip rather than
  // rejecting outright. This app offers both — a real manual trim (build
  // next) alongside the auto-split path, rather than picking only one.
  void _showTrimChoiceDialog() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text(
          'Video çox uzundur',
          style: TextStyle(color: kText),
        ),
        content: const Text(
          'Video 30 saniyədən uzun ola bilməz. Necə davam etmək istəyirsiniz?',
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _startAutoSplit();
            },
            child: const Text('Hissələrə bölmək', style: TextStyle(color: kGold)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _startManualTrim();
            },
            child: const Text('Kəsmək', style: TextStyle(color: kGold)),
          ),
        ],
      ),
    );
  }

  // Splits the whole video into consecutive ≤30s segments (e.g. a 65s
  // video -> [0,30), [30,60), [60,65)) — the last segment is whatever's
  // left over, not padded to 30s. Segment bounds are computed here in
  // Dart; the actual per-segment compress+trim happens natively when
  // _PrivacyPickerScreenState._post() iterates them.
  void _startAutoSplit() {
    final totalMs = _videoController!.value.duration.inMilliseconds;
    final segments = <(int, int)>[];
    var start = 0;
    while (start < totalMs) {
      final end = (start + 30000).clamp(0, totalMs);
      segments.add((start, end));
      start = end;
    }
    final caption = _captionController.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PrivacyPickerScreen(
          type: 'video',
          localFilePath: widget.filePath,
          caption: caption.isEmpty ? null : caption,
          videoSegments: segments,
        ),
      ),
    );
  }

  void _startManualTrim() {
    final caption = _captionController.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ManualTrimScreen(
          filePath: widget.filePath,
          totalDurationMs: _videoController!.value.duration.inMilliseconds,
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
class PrivacyPickerScreen extends ConsumerStatefulWidget {
  final String type; // 'text' | 'image' | 'video'
  final String? text;
  final String? localFilePath;
  final String? caption;
  // Non-null only for the auto-split path: a list of (startMs, endMs)
  // segments covering the whole over-30s source video. When set, _post()
  // publishes one status per segment instead of a single status.
  final List<(int, int)>? videoSegments;
  // True only when localFilePath is already a finished, compressed+
  // trimmed output (from _TrimPreviewScreen) — skips compressVideoFile
  // entirely in _post() rather than re-encoding an already-encoded file
  // a second time, which would just lose quality for no benefit.
  final bool skipVideoCompression;
  // Non-null only for the "forward chat media to status" path
  // (ForwardSheet's "Mənim statusum" entry): each entry is an already-
  // uploaded (mediaUrl, type) pair, copied server-side into statuses/
  // by copyMediaToStatus — createStatus() is called directly for each,
  // no compress/upload step at all, since the file already lives at its
  // final Storage location. Mirrors videoSegments' "one privacy choice,
  // loop-publish multiple statuses" shape, not a new architecture.
  final List<(String mediaUrl, String type)>? forwardedMedia;

  const PrivacyPickerScreen({
    super.key,
    required this.type,
    this.text,
    this.localFilePath,
    this.caption,
    this.videoSegments,
    this.skipVideoCompression = false,
    this.forwardedMedia,
  });

  @override
  ConsumerState<PrivacyPickerScreen> createState() =>
      _PrivacyPickerScreenState();
}

class _PrivacyPickerScreenState extends ConsumerState<PrivacyPickerScreen> {
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
    final privacyMode = switch (_mode) {
      _PrivacyMode.contacts => 'contacts',
      _PrivacyMode.contactsExcept => 'contactsExcept',
      _PrivacyMode.onlyShareWith => 'onlyShareWith',
    };
    final privacyList = _mode == _PrivacyMode.contacts
        ? const <String>[]
        : _selectedUids.toList();
    final firestoreService = ref.read(firestoreServiceProvider);
    final segments = widget.videoSegments;
    final forwarded = widget.forwardedMedia;
    var publishedCount = 0;
    try {
      if (forwarded != null) {
        // Each item is already at its final Storage location (copied
        // server-side by copyMediaToStatus) — createStatus() directly,
        // no compress/upload step, same shared privacyMode/privacyList/
        // caption across every item, same non-atomic "keep whatever
        // published so far on partial failure" behavior as the segments
        // branch below.
        for (final (mediaUrl, type) in forwarded) {
          final statusId = firestoreService.newStatusId(currentUid);
          await firestoreService.createStatus(
            statusId: statusId,
            ownerUid: currentUid,
            type: type,
            mediaUrl: mediaUrl,
            caption: widget.caption,
            privacyMode: privacyMode,
            privacyList: privacyList,
          );
          publishedCount++;
        }
      } else if (segments != null) {
        // Auto-split path: one status per segment, same caption/privacy
        // on every part, published sequentially — not atomic (matches
        // real WhatsApp's own non-atomic multi-status behavior). If one
        // segment fails partway through, whatever already published
        // stays published; the catch block below reports how many
        // parts made it.
        for (final (startMs, endMs) in segments) {
          final statusId = firestoreService.newStatusId(currentUid);
          final hd = ref.read(hdImageUploadProvider);
          final compressedPath = await compressVideoFile(
            widget.localFilePath!,
            hd: hd,
            startTimeMs: startMs,
            endTimeMs: endMs,
          );
          final fileName =
              '${DateTime.now().microsecondsSinceEpoch}_$startMs.mp4';
          final mediaUrl = await firestoreService.uploadStatusVideo(
            ownerUid: currentUid,
            statusId: statusId,
            filePath: compressedPath,
            fileName: fileName,
          );
          await firestoreService.createStatus(
            statusId: statusId,
            ownerUid: currentUid,
            type: 'video',
            mediaUrl: mediaUrl,
            caption: widget.caption,
            privacyMode: privacyMode,
            privacyList: privacyList,
          );
          publishedCount++;
        }
      } else {
        // Single-status path — unchanged from before.
        final statusId = firestoreService.newStatusId(currentUid);
        String? mediaUrl;
        final localFilePath = widget.localFilePath;
        if (localFilePath != null) {
          final hd = ref.read(hdImageUploadProvider);
          final isVideo = widget.type == 'video';
          final fileName =
              '${DateTime.now().microsecondsSinceEpoch}.${isVideo ? 'mp4' : 'jpg'}';
          if (isVideo) {
            final compressedPath = widget.skipVideoCompression
                ? localFilePath
                : await compressVideoFile(localFilePath, hd: hd);
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
        await firestoreService.createStatus(
          statusId: statusId,
          ownerUid: currentUid,
          type: widget.type,
          mediaUrl: mediaUrl,
          text: widget.text,
          caption: widget.caption,
          privacyMode: privacyMode,
          privacyList: privacyList,
        );
        publishedCount++;
      }
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'PrivacyPickerScreen: status post failed '
            '(published $publishedCount of ${segments?.length ?? 1})',
      );
      if (!mounted) return;
      if (publishedCount > 0) {
        // Partial success on the auto-split path: don't leave the user
        // stuck on the composer for parts that already posted — pop back
        // and report the partial failure instead of implying total
        // failure.
        Navigator.of(context).popUntil((route) => route.isFirst);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$publishedCount/${segments!.length} hissə paylaşıldı, xəta baş verdi',
            ),
            backgroundColor: kRed,
          ),
        );
        return;
      }
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

// WhatsApp's own documented trim UI (faq.whatsapp.com/643144237275579):
// "Drag the slider at the top to trim the video" — a slider with two
// handles over a live video preview. This adds a frame filmstrip along
// the slider using the already-established get_thumbnail_video package
// (see video_message_widgets.dart's VideoThumbnailImage for the existing
// convention this mirrors), which isn't explicitly documented by
// WhatsApp's help center but is standard practice in video trimmers.
class _ManualTrimScreen extends ConsumerStatefulWidget {
  final String filePath;
  final int totalDurationMs;
  final String? caption;

  const _ManualTrimScreen({
    required this.filePath,
    required this.totalDurationMs,
    this.caption,
  });

  @override
  ConsumerState<_ManualTrimScreen> createState() => _ManualTrimScreenState();
}

class _ManualTrimScreenState extends ConsumerState<_ManualTrimScreen> {
  static const int _maxWindowMs = 30000;
  static const int _thumbnailCount = 8;

  late VideoPlayerController _videoController;
  bool _videoReady = false;
  int _startMs = 0;
  late int _endMs;
  List<Uint8List?> _thumbnails = [];
  bool _thumbnailsLoading = true;
  bool _confirming = false;
  int _currentPositionMs = 0;

  @override
  void initState() {
    super.initState();
    _endMs = widget.totalDurationMs < _maxWindowMs
        ? widget.totalDurationMs
        : _maxWindowMs;
    _videoController = VideoPlayerController.file(File(widget.filePath))
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _videoReady = true);
        _videoController.setLooping(false);
        _videoController.addListener(_onPositionChanged);
        _seekAndPlayWindow();
      });
    _loadThumbnails();
  }

  @override
  void dispose() {
    _videoController.removeListener(_onPositionChanged);
    _videoController.dispose();
    super.dispose();
  }

  // Drives the playback-position cursor on the filmstrip — video_player's
  // own listener fires on every position/state change, cheap enough for
  // a single controller like this (no debouncing needed at this scale).
  void _onPositionChanged() {
    if (!mounted) return;
    setState(
      () => _currentPositionMs = _videoController.value.position.inMilliseconds,
    );
  }

  // Shared pause/resume for all three drag targets (start handle, end
  // handle, position cursor) — pausing on drag-start avoids playing
  // while also being scrubbed; resuming on drag-end restarts playback
  // from wherever the drag left off, matching standard video-scrubbing
  // UX. Each drag-end starts a fresh _watchForWindowEnd() loop; an old
  // loop from a prior drag naturally stops itself on its next 200ms poll
  // since it checks isPlaying (false during the pause that preceded
  // this resume) — a brief overlap between an old loop's stale wakeup
  // and a new one is harmless (both just re-check the same idempotent
  // reseek condition), not worth extra bookkeeping to prevent.
  void _onDragStart() {
    _videoController.pause();
  }

  void _onDragEnd() {
    _videoController.play();
    _watchForWindowEnd();
  }

  // Evenly-spaced frames across the WHOLE video (not just the current
  // selection) so the filmstrip is a stable map of the source — only the
  // drag handles move over it, the strip itself never regenerates.
  Future<void> _loadThumbnails() async {
    final thumbs = List<Uint8List?>.filled(_thumbnailCount, null);
    for (var i = 0; i < _thumbnailCount; i++) {
      final timeMs = (widget.totalDurationMs * i / (_thumbnailCount - 1))
          .round();
      try {
        final data = await VideoThumbnail.thumbnailData(
          video: widget.filePath,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 200,
          quality: 40,
          timeMs: timeMs,
        );
        thumbs[i] = data;
        if (mounted) setState(() => _thumbnails = List.of(thumbs));
      } catch (e, st) {
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          reason: '_ManualTrimScreen: thumbnail extraction failed',
        );
      }
    }
    if (mounted) setState(() => _thumbnailsLoading = false);
  }

  void _seekAndPlayWindow() {
    _videoController.seekTo(Duration(milliseconds: _startMs));
    _videoController.play();
    _watchForWindowEnd();
  }

  // No native trim-preview API is wired here — this just loops playback
  // within [_startMs, _endMs] by polling position, same coarse approach
  // status_video_player.dart's own preview-only paths use elsewhere in
  // this codebase (nothing in this screen's output is final until Paylaş
  // triggers the real native trim on the actual publish path).
  void _watchForWindowEnd() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted || !_videoController.value.isPlaying) return false;
      if (_videoController.value.position.inMilliseconds >= _endMs) {
        await _videoController.seekTo(Duration(milliseconds: _startMs));
      }
      return mounted && _videoController.value.isPlaying;
    });
  }

  void _onStartHandleDrag(double dx, double trackWidth) {
    final newStartMs = (dx / trackWidth * widget.totalDurationMs).round();
    setState(() {
      _startMs = newStartMs.clamp(0, _endMs - 1000);
      // Keep the window within the 30s cap by pulling the end handle in
      // if the gap would otherwise exceed it.
      if (_endMs - _startMs > _maxWindowMs) {
        _endMs = _startMs + _maxWindowMs;
      }
    });
    _videoController.seekTo(Duration(milliseconds: _startMs));
  }

  void _onEndHandleDrag(double dx, double trackWidth) {
    final newEndMs = (dx / trackWidth * widget.totalDurationMs).round();
    setState(() {
      _endMs = newEndMs.clamp(_startMs + 1000, widget.totalDurationMs);
      if (_endMs - _startMs > _maxWindowMs) {
        _startMs = _endMs - _maxWindowMs;
      }
    });
    _videoController.seekTo(Duration(milliseconds: _startMs));
  }

  // Manual scrub of the playback position, independent of the trim
  // handles — clamped to stay within [_startMs, _endMs] since scrubbing
  // outside the selected window doesn't make sense in this screen.
  void _onCursorDrag(double dx, double trackWidth) {
    final newPosMs = (dx / trackWidth * widget.totalDurationMs).round();
    final clamped = newPosMs.clamp(_startMs, _endMs);
    setState(() => _currentPositionMs = clamped);
    _videoController.seekTo(Duration(milliseconds: clamped));
  }

  // Compresses+trims for real here (not just live-loop-preview like the
  // dragging UX above) so the user can review the ACTUAL output on
  // _TrimPreviewScreen before it's attached to a status, per Teymur's
  // explicit request to see the real result rather than an
  // approximation. Uses the same compressVideoFile(startTimeMs:,
  // endTimeMs:) path _post() would otherwise run at publish time —
  // running it here instead (once) means _post() must NOT re-run it a
  // second time on the same file (see PrivacyPickerScreen's
  // skipVideoCompression field below).
  Future<void> _confirm() async {
    _videoController.pause();
    setState(() => _confirming = true);
    try {
      final hd = ref.read(hdImageUploadProvider);
      final trimmedPath = await compressVideoFile(
        widget.filePath,
        hd: hd,
        startTimeMs: _startMs,
        endTimeMs: _endMs,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _TrimPreviewScreen(
            trimmedFilePath: trimmedPath,
            caption: widget.caption,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: kBg2,
        title: const Text('Kəsin', style: TextStyle(color: kText)),
        actions: [
          TextButton(
            onPressed: _confirming ? null : _confirm,
            child: _confirming
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kGold,
                    ),
                  )
                : const Text('Davam et', style: TextStyle(color: kGold)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _videoReady
                  ? AspectRatio(
                      aspectRatio: _videoController.value.aspectRatio,
                      child: VideoPlayer(_videoController),
                    )
                  : const CircularProgressIndicator(color: kGold),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '${(_endMs - _startMs) / 1000} saniyə seçildi',
              style: const TextStyle(color: kMuted, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final trackWidth = constraints.maxWidth;
                final startFraction = _startMs / widget.totalDurationMs;
                final endFraction = _endMs / widget.totalDurationMs;
                return SizedBox(
                  height: 56,
                  child: Stack(
                    children: [
                      // Filmstrip background — evenly-spaced real frames.
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Row(
                          children: [
                            for (final thumb in _thumbnails)
                              Expanded(
                                child: thumb != null
                                    ? Image.memory(
                                        thumb,
                                        height: 56,
                                        fit: BoxFit.cover,
                                      )
                                    : Container(height: 56, color: kBg3),
                              ),
                          ],
                        ),
                      ),
                      if (_thumbnailsLoading)
                        const Positioned.fill(
                          child: Center(
                            child: CircularProgressIndicator(color: kGold),
                          ),
                        ),
                      // Dimmed overlays outside the selected window.
                      Positioned(
                        left: 0,
                        width: trackWidth * startFraction,
                        top: 0,
                        bottom: 0,
                        child: Container(color: Colors.black.withAlpha(160)),
                      ),
                      Positioned(
                        left: trackWidth * endFraction,
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: Container(color: Colors.black.withAlpha(160)),
                      ),
                      // Selection border.
                      Positioned(
                        left: trackWidth * startFraction,
                        width: trackWidth * (endFraction - startFraction),
                        top: 0,
                        bottom: 0,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: kGold, width: 2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      // Start handle — positioned fully to the LEFT of
                      // the selection boundary (its right edge touches
                      // startFraction exactly), so it never covers any
                      // of the actual selected footage. The selected
                      // range starts exactly at this handle's right edge.
                      Positioned(
                        left: trackWidth * startFraction - 20,
                        top: 0,
                        bottom: 0,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (_) => _onDragStart(),
                          onHorizontalDragUpdate: (details) {
                            final box = context.findRenderObject() as RenderBox;
                            final local = box.globalToLocal(details.globalPosition);
                            _onStartHandleDrag(local.dx, trackWidth);
                          },
                          onHorizontalDragEnd: (_) => _onDragEnd(),
                          child: Container(
                            width: 20,
                            decoration: const BoxDecoration(
                              color: kGold,
                              borderRadius: BorderRadius.horizontal(
                                left: Radius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // End handle — positioned fully to the RIGHT of
                      // the selection boundary (its left edge touches
                      // endFraction exactly), so it never covers any of
                      // the actual selected footage. The selected range
                      // ends exactly at this handle's left edge.
                      Positioned(
                        left: trackWidth * endFraction,
                        top: 0,
                        bottom: 0,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (_) => _onDragStart(),
                          onHorizontalDragUpdate: (details) {
                            final box = context.findRenderObject() as RenderBox;
                            final local = box.globalToLocal(details.globalPosition);
                            _onEndHandleDrag(local.dx, trackWidth);
                          },
                          onHorizontalDragEnd: (_) => _onDragEnd(),
                          child: Container(
                            width: 20,
                            decoration: const BoxDecoration(
                              color: kGold,
                              borderRadius: BorderRadius.horizontal(
                                right: Radius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Playback-position cursor — thin white line, kept
                      // visually distinct from the gold start/end trim
                      // handles. Synced to the controller's real position
                      // via _onPositionChanged. The visible line itself
                      // ignores pointer events (IgnorePointer) and sits
                      // under a separate, wider (24px) transparent
                      // GestureDetector centered on the same position —
                      // a 4px hit target would be too thin to grab
                      // reliably, so the drag target is intentionally
                      // larger than what's drawn.
                      Positioned(
                        left: trackWidth *
                                (_currentPositionMs / widget.totalDurationMs) -
                            2,
                        top: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: Container(width: 4, color: Colors.white),
                        ),
                      ),
                      Positioned(
                        left: trackWidth *
                                (_currentPositionMs / widget.totalDurationMs) -
                            12,
                        top: 0,
                        bottom: 0,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (_) => _onDragStart(),
                          onHorizontalDragUpdate: (details) {
                            final box = context.findRenderObject() as RenderBox;
                            final local = box.globalToLocal(details.globalPosition);
                            _onCursorDrag(local.dx, trackWidth);
                          },
                          onHorizontalDragEnd: (_) => _onDragEnd(),
                          child: Container(width: 24, color: Colors.transparent),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// Shows the REAL, already-compressed trim result — not the live-loop
// approximation _ManualTrimScreen's dragging UX shows. Lets the user
// confirm the actual output before it's attached to a status, per
// Teymur's explicit request to see the real result rather than an
// approximation of it. Includes its own draggable position slider (a
// plain Slider, not a filmstrip — the clip here is already ≤30s, short
// enough that a filmstrip adds little over a simple scrub bar) so the
// user can review the final clip in detail before confirming, matching
// the same pause-while-scrubbing/resume-on-release UX as
// _ManualTrimScreen's handles.
class _TrimPreviewScreen extends StatefulWidget {
  final String trimmedFilePath;
  final String? caption;

  const _TrimPreviewScreen({
    required this.trimmedFilePath,
    this.caption,
  });

  @override
  State<_TrimPreviewScreen> createState() => _TrimPreviewScreenState();
}

class _TrimPreviewScreenState extends State<_TrimPreviewScreen> {
  late VideoPlayerController _controller;
  bool _ready = false;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.trimmedFilePath))
      ..addListener(_onPositionChanged)
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _controller.setLooping(true);
        _controller.play();
      });
  }

  void _onPositionChanged() {
    if (!mounted) return;
    setState(() => _position = _controller.value.position);
  }

  @override
  void dispose() {
    _controller.removeListener(_onPositionChanged);
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PrivacyPickerScreen(
          type: 'video',
          localFilePath: widget.trimmedFilePath,
          caption: widget.caption,
          skipVideoCompression: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = _controller.value.isInitialized
        ? _controller.value.duration.inMilliseconds
        : 0;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: kBg2,
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Geri', style: TextStyle(color: kMuted)),
        ),
        title: const Text('Nəticə', style: TextStyle(color: kText)),
        actions: [
          TextButton(
            onPressed: _next,
            child: const Text('Növbəti', style: TextStyle(color: kGold)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _ready
                  ? AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    )
                  : const CircularProgressIndicator(color: kGold),
            ),
          ),
          if (_ready && durationMs > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: kGold,
                  inactiveTrackColor: kMuted,
                  thumbColor: kGold,
                ),
                child: Slider(
                  min: 0,
                  max: durationMs.toDouble(),
                  value: _position.inMilliseconds
                      .clamp(0, durationMs)
                      .toDouble(),
                  onChangeStart: (_) => _controller.pause(),
                  onChanged: (v) {
                    final ms = v.round();
                    setState(() => _position = Duration(milliseconds: ms));
                    _controller.seekTo(Duration(milliseconds: ms));
                  },
                  onChangeEnd: (v) {
                    _controller.seekTo(Duration(milliseconds: v.round()));
                    _controller.play();
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
