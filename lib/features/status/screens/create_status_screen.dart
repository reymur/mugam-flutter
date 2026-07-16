import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_storage/firebase_storage.dart';
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
import '../../../shared/widgets/status_video_player.dart' as status_video;
import '../../chat/screens/custom_camera_backup/camera_capture_screen.dart';
import '../../chat/screens/video_message_widgets.dart' show UploadProgressOverlay;

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
    // Pushing forward doesn't pop this composer — it stays alive
    // underneath the new route, so the looping preview keeps playing
    // off-screen unless explicitly paused first (null on an image
    // preview, so this is a no-op there).
    _videoController?.pause();
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
    // Same reason as _next() — this composer stays alive underneath the
    // pushed route, so the looping preview must be paused explicitly.
    _videoController?.pause();
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
          caption: caption.isEmpty ? null : caption,
          videoSegmentGroups: [
            (localFilePath: widget.filePath, segments: segments),
          ],
        ),
      ),
    );
  }

  void _startManualTrim() {
    // Same reason as _next() — this composer stays alive underneath the
    // pushed route, so the looping preview must be paused explicitly.
    _videoController?.pause();
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
  // Non-null only for the auto-split path(s): each group is one source
  // video (localFilePath) plus the (startMs, endMs) segments to split it
  // into. Multiple groups let several over-30s videos be auto-split and
  // published together behind one shared privacy choice (e.g. ForwardSheet
  // forwarding several long videos to Status at once) rather than being
  // limited to a single source video's own segments. When set, _post()
  // publishes one status per segment across every group.
  final List<({String localFilePath, List<(int, int)> segments})>?
  videoSegmentGroups;
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
  // final Storage location. Mirrors videoSegmentGroups' "one privacy
  // choice, loop-publish multiple statuses" shape, not a new
  // architecture — and can be combined with videoSegmentGroups in the
  // same _post() call (ForwardSheet may forward a mix of already-short
  // media alongside over-30s videos that still need splitting).
  final List<(String mediaUrl, String type)>? forwardedMedia;

  const PrivacyPickerScreen({
    super.key,
    required this.type,
    this.text,
    this.localFilePath,
    this.caption,
    this.videoSegmentGroups,
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

  // Shared by _post() (single-item path) and _handlePost's push into
  // UploadProgressScreen (forwarded/videoSegmentGroups path) so both read
  // the same privacy choice off _mode/_selectedUids the same way.
  (String, List<String>) _computePrivacy() {
    final privacyMode = switch (_mode) {
      _PrivacyMode.contacts => 'contacts',
      _PrivacyMode.contactsExcept => 'contactsExcept',
      _PrivacyMode.onlyShareWith => 'onlyShareWith',
    };
    final privacyList = _mode == _PrivacyMode.contacts
        ? const <String>[]
        : _selectedUids.toList();
    return (privacyMode, privacyList);
  }

  // "Paylaş" AppBar action. Forwarded/split media goes through
  // UploadProgressScreen first (numbered pieces, real upload progress,
  // explicit confirm tap) — only the plain text/image/single-video path
  // still posts immediately via _post(), since that path has nothing to
  // show progress for (text: no upload at all; single image/video: one
  // status, not a numbered batch UploadProgressScreen is meant for).
  void _handlePost() {
    final forwarded = widget.forwardedMedia;
    final groups = widget.videoSegmentGroups;
    if (forwarded == null && groups == null) {
      _post();
      return;
    }
    final (privacyMode, privacyList) = _computePrivacy();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UploadProgressScreen(
          privacyMode: privacyMode,
          privacyList: privacyList,
          caption: widget.caption,
          forwardedMedia: forwarded,
          videoSegmentGroups: groups,
        ),
      ),
    );
  }

  Future<void> _post() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) return;
    setState(() => _posting = true);
    final (privacyMode, privacyList) = _computePrivacy();
    final firestoreService = ref.read(firestoreServiceProvider);
    final groups = widget.videoSegmentGroups;
    final forwarded = widget.forwardedMedia;
    // Used for the catch block's partial-failure message below — computed
    // up front rather than derived from whichever branch happened to run,
    // since forwarded and videoSegmentGroups can now both be non-null in
    // the same call (see this widget's own forwardedMedia doc comment)
    // and a failure could happen partway through either.
    final totalPublishTarget =
        (forwarded?.length ?? 0) +
        (groups?.fold<int>(0, (sum, g) => sum + g.segments.length) ?? 0) +
        (forwarded == null && groups == null ? 1 : 0);
    var publishedCount = 0;
    try {
      if (forwarded != null || groups != null) {
        if (forwarded != null) {
          // Each item is already at its final Storage location (copied
          // server-side by copyMediaToStatus) — createStatus() directly,
          // no compress/upload step, same shared privacyMode/privacyList/
          // caption across every item, same non-atomic "keep whatever
          // published so far on partial failure" behavior as the groups
          // loop below.
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
        }
        if (groups != null) {
          // Auto-split path: one status per segment per group, same
          // caption/privacy on every part, published sequentially — not
          // atomic (matches real WhatsApp's own non-atomic multi-status
          // behavior). If one segment fails partway through, whatever
          // already published (across forwarded and every prior group)
          // stays published; the catch block below reports how many
          // parts made it against totalPublishTarget.
          for (final group in groups) {
            for (final (startMs, endMs) in group.segments) {
              final statusId = firestoreService.newStatusId(currentUid);
              final hd = ref.read(hdImageUploadProvider);
              final compressedPath = await compressVideoFile(
                group.localFilePath,
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
          }
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
            '(published $publishedCount of $totalPublishTarget)',
      );
      if (!mounted) return;
      if (publishedCount > 0) {
        // Partial success: don't leave the user stuck on the composer
        // for parts that already posted — pop back and report the
        // partial failure instead of implying total failure.
        Navigator.of(context).popUntil((route) => route.isFirst);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$publishedCount/$totalPublishTarget hissə paylaşıldı, xəta baş verdi',
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
            onPressed: _posting ? null : _handlePost,
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

enum _UploadPhase { pending, compressing, uploading, paused, ready, failed }

// One numbered row in UploadProgressScreen: either an already-uploaded
// forwardedMedia entry (starts at UploadPhase.ready — copyMediaToStatus
// already put it at its final Storage location, nothing left to do here)
// or a videoSegmentGroups segment that still needs compressVideoFile +
// uploadStatusVideo run against it. statusId is allocated eagerly for
// every item — newStatusId() is a local Firestore doc-id allocation, not
// a network write — so the same id threads through uploadStatusVideo's
// metadata now and createStatus() later, matching _post()'s original
// one-id-per-item shape.
class _UploadItem {
  final String statusId;
  final String? localFilePath;
  final int? startTimeMs;
  final int? endTimeMs;
  final String type;
  _UploadPhase phase;
  double progress;
  String? mediaUrl;
  // Live handle to the in-flight Storage upload, set via
  // uploadStatusVideo's onTaskStarted — lets _togglePause/_cancelItem call
  // pause()/resume()/cancel() straight on it.
  UploadTask? uploadTask;
  // Completed by _cancelItem to trigger the native "cancel" method-channel
  // case mid-compression (see compressVideoFile's cancelSignal parameter).
  // Fresh per compress attempt — a Completer can only complete once, so
  // _retryItem gets a new one each time.
  Completer<void>? compressCancelSignal;
  // Set by _cancelItem right before it triggers a real cancel, so
  // _uploadItem's catch block can tell "the user cancelled this" apart
  // from "this genuinely failed" without guessing at exception shapes it
  // doesn't fully control (e.g. UploadTask.cancel()'s resulting exception).
  bool cancelledByUser = false;
  // Toggled by _togglePause while this item is still 'pending' — true
  // means _uploadItem() must not proceed into compression yet (checked
  // before it even asks for the compression lock).
  bool queuePaused = false;
  // Live only while _uploadItem() is actually blocked waiting on this item
  // (queuePaused was true when it got there) — completed by _togglePause
  // (resume), _playNow (play-now overrides a manual pause), or _cancelItem
  // (delete while blocked) to let it proceed. Cleared back to null right
  // after each wait resolves, since a Completer can only complete once and
  // a later re-pause needs a fresh one.
  Completer<void>? resumeSignal;
  // Completed by _releaseCompressionLock/_playNow when the single shared
  // compression lock is actually granted to this item while it's sitting
  // in _compressionWaitQueue. Non-null only while genuinely queued for
  // the lock; cleared back to null once _acquireCompressionLock's wait
  // resolves (a Completer can only complete once).
  Completer<void>? lockGrantedSignal;
  // Set by _playNow right before preempting this item's in-progress
  // compression to hand the lock to a different item — lets
  // _uploadItem's catch block tell "bumped by another item jumping the
  // queue, requeue automatically" apart from a genuine user cancel or a
  // real failure.
  bool preempted = false;
  // Set by the upload-phase stall watchdog in _uploadItem when 15s pass
  // with zero progress movement — Firebase Storage's UploadTask is
  // documented to hang forever with no error/progress callback when the
  // connection drops mid-upload (FlutterFire SDK-level gap, both
  // platforms), so this is the only way to detect it. While true, the
  // item sits at phase 'pending' (not 'failed' — this isn't a dead-end)
  // until _onConnectivityChanged sees a real reconnect and restarts it.
  bool connectivityStuck = false;
  // Let _togglePause reach into the SAME watchdog instance across a
  // manual pause/resume cycle, which happens entirely outside
  // _uploadItem's own call scope. Assigned inside _uploadItem's
  // upload-phase try block, right alongside armStallTimer.
  // pauseStallWatchdog stops the countdown on pause — a paused transfer
  // producing zero progress is expected, not suspicious, so leaving the
  // timer running (as it did before this fix) would misfire on any pause
  // longer than the watchdog's own window. resumeStallWatchdog re-arms a
  // fresh countdown on resume — necessary because UploadTask.resume()
  // can itself silently fail to actually restart the transfer (the same
  // class of SDK flakiness this watchdog exists for in the first place);
  // without re-arming, a broken resume() would leave the item completely
  // unsupervised, since nothing else would ever rearm it without a fresh
  // onProgress tick that may never come.
  void Function()? pauseStallWatchdog;
  void Function()? resumeStallWatchdog;

  _UploadItem.forwarded({
    required this.statusId,
    required this.mediaUrl,
    required this.type,
  }) : localFilePath = null,
       startTimeMs = null,
       endTimeMs = null,
       phase = _UploadPhase.ready,
       progress = 1.0;

  _UploadItem.segment({
    required this.statusId,
    required this.localFilePath,
    required this.startTimeMs,
    required this.endTimeMs,
  }) : type = 'video',
       phase = _UploadPhase.pending,
       progress = 0.0,
       mediaUrl = null;
}

// Intermediate screen between "Paylaş" and the actual createStatus() calls,
// pushed only for the forwarded/videoSegmentGroups (multi-item) path — see
// _handlePost's doc comment. Splits what _post() used to do as one
// invisible compress->upload->createStatus loop into two visible phases:
// upload everything first (with real per-item progress, kicked off in
// initState), then require an explicit confirm tap before any createStatus()
// call runs.
class UploadProgressScreen extends ConsumerStatefulWidget {
  final String privacyMode;
  final List<String> privacyList;
  final String? caption;
  final List<(String mediaUrl, String type)>? forwardedMedia;
  final List<({String localFilePath, List<(int, int)> segments})>?
  videoSegmentGroups;

  const UploadProgressScreen({
    super.key,
    required this.privacyMode,
    required this.privacyList,
    this.caption,
    this.forwardedMedia,
    this.videoSegmentGroups,
  });

  @override
  ConsumerState<UploadProgressScreen> createState() =>
      _UploadProgressScreenState();
}

class _UploadProgressScreenState extends ConsumerState<UploadProgressScreen> {
  late final List<_UploadItem> _items;
  bool _confirming = false;
  // The single shared compression lock — only one item may actually be
  // inside compressVideoFile at a time (its native side is a strict
  // one-at-a-time resource on both platforms, see video_compressor.dart's
  // own doc comment on the BUSY fallback), but everything downstream of
  // compression (the real Storage upload) is fully independent and
  // concurrent across items once each one gets there.
  _UploadItem? _activeCompressingItem;
  // FIFO by default (preserves the old sequential processing order when
  // nothing is manually reordered) — _playNow can jump an item to the
  // front to preempt whoever currently holds the lock.
  final List<_UploadItem> _compressionWaitQueue = [];
  // Same listener pattern as PendingMessageQueueController's own
  // Connectivity().onConnectivityChanged.listen(...) — restarts any item
  // the upload-phase stall watchdog parked at connectivityStuck once a
  // real reconnect is seen, rather than leaving it sitting forever.
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final firestoreService = ref.read(firestoreServiceProvider);
    _items = [
      for (final (mediaUrl, type)
          in widget.forwardedMedia ?? const <(String, String)>[])
        _UploadItem.forwarded(
          statusId: firestoreService.newStatusId(currentUid),
          mediaUrl: mediaUrl,
          type: type,
        ),
      for (final group
          in widget.videoSegmentGroups ??
              const <({String localFilePath, List<(int, int)> segments})>[])
        for (final (startMs, endMs) in group.segments)
          _UploadItem.segment(
            statusId: firestoreService.newStatusId(currentUid),
            localFilePath: group.localFilePath,
            startTimeMs: startMs,
            endTimeMs: endMs,
          ),
    ];
    // Fully concurrent launch: every segment starts racing for the single
    // compression lock immediately (see _acquireCompressionLock) instead
    // of being sequenced by a loop here — only one item's compress call
    // actually runs at a time, but each item's own upload (once its
    // compression finishes) proceeds fully independently of every other
    // item, including whichever one is still compressing.
    for (final item in _items) {
      if (item.localFilePath != null) unawaited(_uploadItem(item));
    }
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      _onConnectivityChanged,
    );
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  // Mirrors PendingMessageQueueController._onConnectivityChanged's own
  // hasConnection check. Only items the stall watchdog actually parked
  // (connectivityStuck) get restarted here — every other pending item
  // (never started, manually queuePaused, or requeued after a _playNow
  // preemption) is left exactly as-is; this listener's only job is
  // un-sticking uploads the watchdog stopped waiting on.
  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (!_hasConnection(results)) return;
    for (final item in _items) {
      if (!item.connectivityStuck) continue;
      setState(() => item.connectivityStuck = false);
      unawaited(_uploadItem(item));
    }
  }

  bool _hasConnection(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  // Grants the shared compression lock to `item`, waiting in FIFO order
  // behind whoever already holds it (or is already queued). The
  // `_activeCompressingItem == item` branch matters even on first call —
  // _playNow can pre-grant the lock directly (setting
  // _activeCompressingItem before this item ever calls in), and this lets
  // that later call recognize it already has the lock instead of queuing
  // a second, never-completed wait behind itself.
  Future<void> _acquireCompressionLock(_UploadItem item) async {
    if (_activeCompressingItem == null || _activeCompressingItem == item) {
      _activeCompressingItem = item;
      return;
    }
    if (!_compressionWaitQueue.contains(item)) {
      _compressionWaitQueue.add(item);
    }
    final lockGrantedSignal = Completer<void>();
    item.lockGrantedSignal = lockGrantedSignal;
    await lockGrantedSignal.future;
    item.lockGrantedSignal = null;
  }

  // Called from every exit path of _uploadItem's compression stage
  // (success, real failure, user-cancel, preemption) for whichever item
  // currently holds the lock. No-ops if `item` isn't actually the current
  // holder (e.g. a defensive double-call), so it's always safe to call.
  void _releaseCompressionLock(_UploadItem item) {
    if (_activeCompressingItem != item) return;
    _activeCompressingItem = null;
    if (_compressionWaitQueue.isNotEmpty) {
      final next = _compressionWaitQueue.removeAt(0);
      _activeCompressingItem = next;
      final lockGrantedSignal = next.lockGrantedSignal;
      if (lockGrantedSignal != null && !lockGrantedSignal.isCompleted) {
        lockGrantedSignal.complete();
      }
    }
  }

  // "Play now" — jumps `item` to the front of the compression queue,
  // preempting whoever currently holds the lock if anyone does.
  void _playNow(_UploadItem item) {
    if (item.phase == _UploadPhase.compressing ||
        item.phase == _UploadPhase.uploading ||
        item.phase == _UploadPhase.paused ||
        item.phase == _UploadPhase.ready) {
      return; // already running or done
    }
    if (_activeCompressingItem == item) return; // already holds the lock
    // Play-now overrides a manual pending-pause too — leaving queuePaused
    // set would grant this item the lock while it's still blocked on its
    // own resumeSignal-wait (that wait runs before _acquireCompressionLock
    // in _uploadItem), which would stall every other item behind a lock
    // nobody is actually using.
    if (item.queuePaused) {
      setState(() => item.queuePaused = false);
      final resumeSignal = item.resumeSignal;
      if (resumeSignal != null && !resumeSignal.isCompleted) {
        resumeSignal.complete();
      }
    }
    _compressionWaitQueue.remove(item);
    final holder = _activeCompressingItem;
    if (holder != null) {
      holder.preempted = true;
      final holderCancelSignal = holder.compressCancelSignal;
      if (holderCancelSignal != null && !holderCancelSignal.isCompleted) {
        holderCancelSignal.complete();
      }
      // The grant itself happens once the preempted holder's _uploadItem
      // catch block unwinds (async — a real native cancel round-trip) and
      // calls _releaseCompressionLock, which pops the queue FIFO —
      // inserting at the front guarantees `item` is what gets popped
      // next, jumping anyone already waiting.
      _compressionWaitQueue.insert(0, item);
    } else {
      // Lock is free — grant directly. If item.lockGrantedSignal is still
      // null here (this item's own _acquireCompressionLock call hasn't
      // run yet, e.g. it was still mid-queuePaused-wait until just above),
      // there's nothing to complete yet — _acquireCompressionLock's own
      // `_activeCompressingItem == item` check picks up this pre-grant
      // once that call actually happens.
      _activeCompressingItem = item;
      final lockGrantedSignal = item.lockGrantedSignal;
      if (lockGrantedSignal != null && !lockGrantedSignal.isCompleted) {
        lockGrantedSignal.complete();
      }
    }
  }

  // Compress+upload for exactly one segment item — shared by the
  // concurrent-launch loop in initState (first pass over every item) and
  // _retryItem() (re-running a single item), so the compress/upload/
  // error-handling logic only exists once.
  Future<void> _uploadItem(_UploadItem item) async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) return;
    final firestoreService = ref.read(firestoreServiceProvider);
    final hd = ref.read(hdImageUploadProvider);
    item.cancelledByUser = false;
    item.preempted = false;
    item.connectivityStuck = false;
    // Declared out here (not inside the try block below, where it's
    // armed/used) so the catch block can also cancel it on every exit
    // path from the upload phase — not just the success path.
    Timer? stallTimer;
    // Manual "pause while pending" (queuePaused, toggled via
    // _togglePause) blocks here, before this item even asks for the
    // compression lock — relocated from the old sequential _runUploads()
    // loop (now gone, replaced by initState's concurrent launch), since
    // nothing else in this concurrent model owns a per-item wait anymore.
    if (item.queuePaused) {
      item.resumeSignal = Completer<void>();
      setState(() {});
      await item.resumeSignal!.future;
      item.resumeSignal = null;
      if (!mounted) return;
      if (!_items.contains(item)) return; // deleted while paused
    }
    await _acquireCompressionLock(item);
    if (!mounted) {
      _releaseCompressionLock(item);
      return;
    }
    if (!_items.contains(item)) {
      _releaseCompressionLock(item); // deleted while queued for the lock
      return;
    }
    try {
      setState(() => item.phase = _UploadPhase.compressing);
      final cancelSignal = Completer<void>();
      item.compressCancelSignal = cancelSignal;
      final compressedPath = await compressVideoFile(
        item.localFilePath!,
        hd: hd,
        startTimeMs: item.startTimeMs,
        endTimeMs: item.endTimeMs,
        cancelSignal: cancelSignal,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => item.progress = p);
        },
      );
      // Compression is done — free the lock for the next item before
      // starting this item's own independent upload, so compression and
      // upload genuinely overlap across items instead of the lock being
      // held for this item's entire remaining lifetime.
      _releaseCompressionLock(item);
      if (!mounted) return;
      setState(() {
        item.phase = _UploadPhase.uploading;
        item.progress = 0.0;
      });
      final fileName =
          '${DateTime.now().microsecondsSinceEpoch}_${item.startTimeMs}.mp4';
      // Stall watchdog: a progress-inactivity timer, not a flat total-
      // duration timeout — a flat cutoff would incorrectly kill a large
      // video that's genuinely still uploading (just slowly, on a weak
      // connection). Reset on every progress tick that actually moves;
      // if 15s pass with zero movement, treat it as stuck (Firebase
      // Storage's UploadTask is documented to hang forever with no
      // error/progress when the connection drops mid-upload — a real
      // FlutterFire SDK-level gap, not something this app can fix at the
      // source) and force this attempt to end via stallSignal, raced
      // against the real upload with Future.any — task.cancel() alone
      // isn't trusted to unblock the hang, since the same SDK gap could
      // plausibly affect cancel()'s own resolution too; racing a
      // separate Dart-side Completer guarantees this call returns
      // regardless of whether the abandoned original upload Future ever
      // settles on its own.
      double? lastProgress;
      final stallSignal = Completer<void>();
      void armStallTimer() {
        stallTimer?.cancel();
        stallTimer = Timer(const Duration(seconds: 15), () {
          if (stallSignal.isCompleted) return;
          item.connectivityStuck = true;
          item.uploadTask?.cancel();
          stallSignal.complete();
        });
      }
      // Exposed on the item so _togglePause can pause/resume this exact
      // watchdog across a manual pause/resume cycle — see _UploadItem's
      // own doc comment on these two fields for why both halves matter.
      item.pauseStallWatchdog = () => stallTimer?.cancel();
      item.resumeStallWatchdog = armStallTimer;
      armStallTimer();
      final mediaUrl = await Future.any<String>([
        firestoreService.uploadStatusVideo(
          ownerUid: currentUid,
          statusId: item.statusId,
          filePath: compressedPath,
          fileName: fileName,
          onTaskStarted: (task) => item.uploadTask = task,
          onProgress: (p) {
            if (!mounted) return;
            if (lastProgress == null || p > lastProgress!) {
              lastProgress = p;
              armStallTimer();
            }
            setState(() => item.progress = p);
          },
        ),
        stallSignal.future.then<String>(
          (_) => throw StateError('Status upload stalled: no progress for 15s'),
        ),
      ]);
      stallTimer?.cancel();
      if (!mounted) return;
      setState(() {
        item.mediaUrl = mediaUrl;
        item.phase = _UploadPhase.ready;
        item.progress = 1.0;
      });
      // Best-effort warm of StatusViewerScreen's own video cache so the
      // first open after publishing plays from disk instead of streaming
      // over the network. Never allowed to affect the upload flow itself —
      // any failure here is swallowed and only logged.
      unawaited(_precacheStatusVideo(mediaUrl));
    } catch (e, st) {
      stallTimer?.cancel();
      // Bumped by another item's _playNow, not a real failure or a user
      // cancel — requeue automatically instead of dead-ending in
      // 'failed', since nothing about this item itself went wrong.
      if (item.preempted) {
        item.preempted = false;
        _releaseCompressionLock(item);
        if (!mounted) return;
        if (_items.contains(item)) {
          setState(() {
            item.phase = _UploadPhase.pending;
            item.progress = 0.0;
          });
          if (!_compressionWaitQueue.contains(item)) {
            _compressionWaitQueue.add(item);
          }
        }
        return;
      }
      // The upload-phase stall watchdog gave up on this attempt — not a
      // user action and not a real failure, so no Crashlytics log and no
      // dead-end 'failed' phase.
      if (item.connectivityStuck) {
        _releaseCompressionLock(item);
        if (!mounted) return;
        if (_items.contains(item)) {
          setState(() {
            item.phase = _UploadPhase.pending;
            item.progress = 0.0;
          });
          // Waiting on _onConnectivityChanged alone can leave this item
          // stuck forever if the stall wasn't actually caused by a real
          // connectivity drop in the first place — e.g. a manual pause
          // that outlasted the watchdog's own window, or
          // UploadTask.resume() silently not restarting the transfer.
          // Either way the device's own connectivity never actually
          // changes, so no change event would ever fire. A one-shot
          // check right now catches that: if we're already online,
          // retry immediately instead of waiting for an event that may
          // never come. Only fall back to the listener when genuinely
          // offline right now.
          final results = await Connectivity().checkConnectivity();
          if (_hasConnection(results) &&
              mounted &&
              _items.contains(item) &&
              item.phase == _UploadPhase.pending) {
            unawaited(_uploadItem(item));
          }
        }
        return;
      }
      _releaseCompressionLock(item);
      // A user-triggered cancel (compression's own
      // VideoCompressionCancelledException, or an UploadTask.cancel() that
      // _cancelItem already flagged via cancelledByUser) is an intentional
      // action, not a real failure — don't spam Crashlytics with it.
      if (item.cancelledByUser || e is VideoCompressionCancelledException) {
        if (!mounted) return;
        setState(() => item.phase = _UploadPhase.failed);
        return;
      }
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'UploadProgressScreen: segment upload failed',
      );
      if (!mounted) return;
      setState(() => item.phase = _UploadPhase.failed);
    }
  }

  Future<void> _precacheStatusVideo(String mediaUrl) async {
    try {
      await status_video.VideoCacheManager.instance.downloadFile(mediaUrl);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'UploadProgressScreen: status video pre-cache failed',
      );
    }
  }

  // Meaningful during 'pending' (blocks _uploadItem() from proceeding
  // into compression for this item), 'uploading', and 'paused' —
  // compression itself still can't pause once started (confirmed native
  // limitation, both platforms only support a full stop), so the button
  // stays hidden while compressing.
  void _togglePause(_UploadItem item) {
    if (item.phase == _UploadPhase.pending) {
      setState(() => item.queuePaused = !item.queuePaused);
      if (!item.queuePaused) {
        final resumeSignal = item.resumeSignal;
        if (resumeSignal != null && !resumeSignal.isCompleted) {
          resumeSignal.complete();
        }
      }
    } else if (item.phase == _UploadPhase.uploading) {
      item.uploadTask?.pause();
      // Stops the stall watchdog's countdown — a paused transfer
      // produces zero progress by design, so leaving it running would
      // misfire (marking this a connectivity stall, then cancelling the
      // paused-not-stuck task) on any pause longer than its own window.
      item.pauseStallWatchdog?.call();
      setState(() => item.phase = _UploadPhase.paused);
    } else if (item.phase == _UploadPhase.paused) {
      item.uploadTask?.resume();
      // Re-arms a fresh countdown — resume() can itself silently fail to
      // actually restart the transfer (the same class of SDK flakiness
      // the watchdog exists for), so this is necessary, not optional:
      // without it, a broken resume() would leave the item completely
      // unsupervised from here on.
      item.resumeStallWatchdog?.call();
      setState(() => item.phase = _UploadPhase.uploading);
    }
  }

  // Triggers a real stop for whichever phase the item is currently in.
  // Compressing: completes the Completer that compressVideoFile is
  // listening on, which forwards to the native "cancel" method-channel
  // case (now safe on both platforms — see NativeVideoCompressorPlugin.kt's
  // pendingCompressResult fix) and throws
  // VideoCompressionCancelledException back into _uploadItem. Uploading/
  // paused: UploadTask.cancel() directly, natively supported by Firebase
  // Storage. cancelledByUser is set first so _uploadItem's catch block
  // doesn't mistake this for a genuine failure.
  void _cancelItem(_UploadItem item) {
    item.cancelledByUser = true;
    switch (item.phase) {
      case _UploadPhase.compressing:
        final cancelSignal = item.compressCancelSignal;
        if (cancelSignal != null && !cancelSignal.isCompleted) {
          cancelSignal.complete();
        }
      case _UploadPhase.uploading:
      case _UploadPhase.paused:
        item.uploadTask?.cancel();
      case _UploadPhase.pending:
        // Covers every way a 'pending' item can currently be blocked:
        // manually paused (resumeSignal), genuinely waiting its turn for
        // the compression lock (_compressionWaitQueue + lockGrantedSignal),
        // or — defensively — already granted the lock but not yet flipped
        // to 'compressing' by its own _uploadItem continuation. Only one
        // of these is ever actually live for a given item; the others are
        // no-ops. _items.contains(item) inside _uploadItem will already
        // be false by the time any of these wake it up, since _deleteItem
        // removes the item before this completes.
        final resumeSignal = item.resumeSignal;
        if (resumeSignal != null && !resumeSignal.isCompleted) {
          resumeSignal.complete();
        }
        _compressionWaitQueue.remove(item);
        final lockGrantedSignal = item.lockGrantedSignal;
        if (lockGrantedSignal != null && !lockGrantedSignal.isCompleted) {
          lockGrantedSignal.complete();
        }
        if (_activeCompressingItem == item) {
          _releaseCompressionLock(item);
        }
      case _UploadPhase.ready:
      case _UploadPhase.failed:
        break;
    }
  }

  // Cancels any in-flight compress/upload for this item (real cancel on
  // both fronts now — see _cancelItem) and removes it from the list/UI.
  void _deleteItem(_UploadItem item) {
    _cancelItem(item);
    setState(() => _items.remove(item));
  }

  Future<void> _retryItem(_UploadItem item) async {
    setState(() {
      item.phase = _UploadPhase.pending;
      item.progress = 0.0;
    });
    await _uploadItem(item);
  }

  // Partial publish, matching _post()'s own "keep whatever published so
  // far" philosophy: only ready items get createStatus() calls, failed
  // items are silently left out rather than blocking the confirm button
  // entirely — the confirm button below is already disabled while any
  // item is still uploading, so by the time it's tappable every item is
  // either ready or permanently failed.
  Future<void> _confirm() async {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) return;
    setState(() => _confirming = true);
    final firestoreService = ref.read(firestoreServiceProvider);
    final readyItems = _items
        .where((i) => i.phase == _UploadPhase.ready)
        .toList();
    var publishedCount = 0;
    try {
      for (final item in readyItems) {
        await firestoreService.createStatus(
          statusId: item.statusId,
          ownerUid: currentUid,
          type: item.type,
          mediaUrl: item.mediaUrl,
          caption: widget.caption,
          privacyMode: widget.privacyMode,
          privacyList: widget.privacyList,
        );
        publishedCount++;
      }
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'UploadProgressScreen: publish failed '
            '(published $publishedCount of ${readyItems.length})',
      );
      if (!mounted) return;
      if (publishedCount > 0) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$publishedCount/${readyItems.length} hissə paylaşıldı, xəta baş verdi',
            ),
            backgroundColor: kRed,
          ),
        );
        return;
      }
      setState(() => _confirming = false);
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
    final readyCount = _items
        .where((i) => i.phase == _UploadPhase.ready)
        .length;
    final allSettled = _items.every(
      (i) => i.phase == _UploadPhase.ready || i.phase == _UploadPhase.failed,
    );
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        automaticallyImplyLeading: false,
        leading: TextButton(
          onPressed: _confirming ? null : () => Navigator.of(context).pop(),
          child: const Text('Geri', style: TextStyle(color: kMuted)),
        ),
        title: Text(
          '$readyCount/${_items.length} hazır',
          style: const TextStyle(color: kText, fontSize: 16),
        ),
        centerTitle: true,
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(color: kBorder, height: 24),
        itemBuilder: (context, index) => _buildRow(index, _items[index]),
      ),
      bottomNavigationBar: allSettled
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: (_confirming || readyCount == 0)
                        ? null
                        : _confirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      disabledBackgroundColor: kGold.withAlpha(90),
                    ),
                    child: _confirming
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : Text(
                            readyCount == _items.length
                                ? 'Göndər'
                                : 'Göndər ($readyCount/${_items.length})',
                            style: const TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildRow(int index, _UploadItem item) {
    final label = switch (item.phase) {
      _UploadPhase.pending => item.queuePaused
          ? 'Dayandırılıb'
          : (item.connectivityStuck ? 'Şəbəkə gözlənilir' : 'Gözləyir'),
      _UploadPhase.compressing => 'Sıxılır ${(item.progress * 100).round()}%',
      _UploadPhase.uploading => 'Yüklənir ${(item.progress * 100).round()}%',
      _UploadPhase.paused => 'Dayandırılıb',
      _UploadPhase.ready => 'Hazır',
      _UploadPhase.failed => 'Xəta',
    };
    final labelColor = item.phase == _UploadPhase.failed ? kRed : kMuted;
    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            '${index + 1}',
            style: const TextStyle(color: kText, fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          width: 56,
          height: 56,
          child: switch (item.phase) {
            _UploadPhase.ready => const Icon(
              Icons.check_circle,
              color: kGold,
              size: 32,
            ),
            _UploadPhase.failed => const Icon(
              Icons.error,
              color: kRed,
              size: 32,
            ),
            _ => UploadProgressOverlay(
              progress: item.phase == _UploadPhase.pending
                  ? null
                  : item.progress,
            ),
          },
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: TextStyle(color: labelColor))),
        // "Play now" — in addition to (not instead of) the pause/resume
        // button below: a pending item can still be individually paused
        // (won't auto-start on its own turn) AND separately jump the
        // compression queue via this button, regardless of that pause.
        if (item.phase == _UploadPhase.pending)
          IconButton(
            icon: const Icon(Icons.fast_forward, color: kGold),
            onPressed: () => _playNow(item),
          ),
        if (item.phase == _UploadPhase.pending ||
            item.phase == _UploadPhase.uploading ||
            item.phase == _UploadPhase.paused)
          IconButton(
            icon: Icon(
              (item.phase == _UploadPhase.paused ||
                      (item.phase == _UploadPhase.pending &&
                          item.queuePaused))
                  ? Icons.play_arrow
                  : Icons.pause,
              color: kGold,
            ),
            onPressed: () => _togglePause(item),
          ),
        if (item.phase == _UploadPhase.failed)
          IconButton(
            icon: const Icon(Icons.refresh, color: kGold),
            onPressed: () => _retryItem(item),
          ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: kMuted),
          onPressed: () => _deleteItem(item),
        ),
      ],
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
