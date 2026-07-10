import 'dart:io';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import 'video_message_widgets.dart'
    show MessageDeliveryStatus, UploadProgressOverlay, formatDurationMmSs;

// WhatsApp-style document/file bubble: icon-by-extension + filename + size,
// tap downloads it (if not already cached locally) then opens it via the
// OS's own viewer/app association (open_filex — Quick Look on iOS, an
// intent on Android). Structurally mirrors _VoiceMessagePlayer's fixed-
// width card + trailing timeCheckmarkRow layout (chat_screen.dart) rather
// than ImageMessageBubble/VideoMessageBubble's edge-to-edge treatment — a
// document card keeps the bubble's normal padded chrome, same as WhatsApp,
// since (unlike a photo/video) there's no visual content to fill the bubble
// with.
class FileMessageBubble extends StatefulWidget {
  final String? fileURL;
  final String? localFilePath;
  final String? fileName;
  final int? fileSizeBytes;
  // Needed to build the Storage ref for the on-demand download — see
  // FirestoreService.downloadChatFile.
  final String? mediaOriginChatId;
  final String? mediaFileName;
  final bool isMe;
  // Single computed source of truth (see deliveryStatusFor) — same value
  // the corner checkmark and every other media bubble already key off.
  final MessageDeliveryStatus deliveryStatus;
  final double? localUploadProgress;
  final VoidCallback? onCancelUpload;
  final Widget timeCheckmarkRow;

  const FileMessageBubble({
    super.key,
    this.fileURL,
    this.localFilePath,
    this.fileName,
    this.fileSizeBytes,
    this.mediaOriginChatId,
    this.mediaFileName,
    required this.isMe,
    required this.deliveryStatus,
    this.localUploadProgress,
    this.onCancelUpload,
    required this.timeCheckmarkRow,
  });

  @override
  State<FileMessageBubble> createState() => _FileMessageBubbleState();
}

class _FileMessageBubbleState extends State<FileMessageBubble> {
  static const double _iconSlotSize = 56;

  // Path to a file that's actually openable right now — either the pending
  // queue's own local source file (not yet uploaded), or a copy this widget
  // already downloaded into the temp document cache on a previous tap. Null
  // means "must download from Storage first" (see _handleTap).
  String? _readyPath;
  bool _downloading = false;
  double? _downloadProgress;

  // Rolling window of (timestamp, bytesTransferred) samples for the
  // upload-remaining-time estimate ("Qalıb: mm:ss", WhatsApp-style) —
  // deliberately local to this widget, not threaded through the shared
  // upload pipeline (firestore_service.dart / PendingMediaMessage /
  // PendingMessageQueueController), which only ever hands us a plain
  // 0.0-1.0 fraction (see Message.localUploadProgress) and is shared by
  // image/video/audio too. Averaging the rate over this window (oldest vs.
  // newest sample) rather than the last two consecutive samples smooths
  // out uneven network throughput — a single fast/slow tick doesn't make
  // the ETA jump around, same principle real download managers use.
  static const int _maxProgressSamples = 5;
  final List<(DateTime, int)> _progressSamples = [];

  @override
  void initState() {
    super.initState();
    _readyPath = widget.localFilePath;
    if (_readyPath == null) _checkCache();
    _recordProgressSample();
  }

  @override
  void didUpdateWidget(FileMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A pending item's localFilePath goes away once it's replaced by the
    // real sent message (fileURL) — re-derive readiness instead of keeping
    // whatever was true before, same swap-safety as every other media
    // bubble's cache-key handling.
    if (oldWidget.localFilePath != widget.localFilePath) {
      _readyPath = widget.localFilePath;
      if (_readyPath == null) _checkCache();
    }
    if (oldWidget.localUploadProgress != widget.localUploadProgress) {
      _recordProgressSample();
    }
  }

  void _recordProgressSample() {
    final progress = widget.localUploadProgress;
    final totalBytes = widget.fileSizeBytes;
    if (progress == null || totalBytes == null) return;
    final bytesNow = (progress * totalBytes).round();
    // A retry restarts the transfer from 0 — old samples from the previous
    // attempt would otherwise skew the window with a bogus negative/huge
    // rate, so start the window over instead of averaging across attempts.
    if (_progressSamples.isNotEmpty && bytesNow < _progressSamples.last.$2) {
      _progressSamples.clear();
    }
    _progressSamples.add((DateTime.now(), bytesNow));
    if (_progressSamples.length > _maxProgressSamples) {
      _progressSamples.removeAt(0);
    }
  }

  // Null until there are at least two samples spanning a real (non-zero)
  // time gap — the very first tick after an upload starts has nothing to
  // average against yet, so the bubble just shows the percentage alone for
  // that brief moment rather than a divide-by-zero or a wild first guess.
  String? _etaText() {
    final totalBytes = widget.fileSizeBytes;
    if (totalBytes == null || _progressSamples.length < 2) return null;
    final oldest = _progressSamples.first;
    final newest = _progressSamples.last;
    final elapsedMs = newest.$1.difference(oldest.$1).inMilliseconds;
    final bytesDelta = newest.$2 - oldest.$2;
    if (elapsedMs <= 0 || bytesDelta <= 0) return null;
    final bytesPerMs = bytesDelta / elapsedMs;
    final remainingBytes = totalBytes - newest.$2;
    if (remainingBytes <= 0) return null;
    final etaMs = (remainingBytes / bytesPerMs).round();
    return 'Qalıb: ${formatDurationMmSs(etaMs)}';
  }

  Future<Directory> _cacheDir() async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/document_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  // Keyed by the Storage object name (stable, unique per message) with the
  // original display name appended so the OS-level open call sees a real
  // extension — a plain messageId-based name with no extension would leave
  // Quick Look/Android's intent resolver guessing the file's type.
  String _cacheFileName() {
    final key = widget.mediaFileName ?? widget.fileURL ?? 'file';
    final displayName = widget.fileName ?? 'file';
    return '${key}_$displayName';
  }

  Future<void> _checkCache() async {
    try {
      final dir = await _cacheDir();
      final path = '${dir.path}/${_cacheFileName()}';
      if (await File(path).exists()) {
        if (mounted) setState(() => _readyPath = path);
      }
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FileMessageBubble: _checkCache failed',
      );
    }
  }

  Future<void> _open(String path) async {
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fayl açıla bilmədi'),
          backgroundColor: kRed,
        ),
      );
    }
  }

  Future<void> _handleTap() async {
    final ready = _readyPath;
    if (ready != null) {
      await _open(ready);
      return;
    }
    if (_downloading) return;
    final fileURL = widget.fileURL;
    final originChatId = widget.mediaOriginChatId;
    final mediaFileName = widget.mediaFileName;
    if (fileURL == null || originChatId == null || mediaFileName == null) {
      return;
    }
    setState(() {
      _downloading = true;
      _downloadProgress = null;
    });
    try {
      final dir = await _cacheDir();
      final destPath = '${dir.path}/${_cacheFileName()}';
      await FirestoreService().downloadChatFile(
        mediaOriginChatId: originChatId,
        mediaFileName: mediaFileName,
        destPath: destPath,
        onProgress: (p) {
          if (mounted) setState(() => _downloadProgress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _readyPath = destPath;
      });
      await _open(destPath);
    } catch (_) {
      if (mounted) {
        setState(() => _downloading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fayl yüklənmədi'),
            backgroundColor: kRed,
          ),
        );
      }
    }
  }

  (IconData, Color) _iconFor(String? fileName) {
    final ext = (fileName != null && fileName.contains('.'))
        ? fileName.split('.').last.toLowerCase()
        : '';
    switch (ext) {
      case 'pdf':
        return (Icons.picture_as_pdf, const Color(0xFFE53935));
      case 'doc':
      case 'docx':
        return (Icons.description, const Color(0xFF2196F3));
      case 'xls':
      case 'xlsx':
      case 'csv':
        return (Icons.table_chart, const Color(0xFF43A047));
      case 'ppt':
      case 'pptx':
        return (Icons.slideshow, const Color(0xFFFB8C00));
      case 'zip':
      case 'rar':
      case '7z':
        return (Icons.folder_zip, kMuted);
      case 'txt':
        return (Icons.article, kMuted);
      default:
        return (Icons.insert_drive_file, kMuted);
    }
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final labelColor = widget.isMe ? const Color(0xFF1A0E00) : kText;
    final subColor = widget.isMe
        ? const Color(0xFF1A0E00).withAlpha(160)
        : kMuted;
    final (icon, iconColor) = _iconFor(widget.fileName);
    final isUploading =
        widget.deliveryStatus == MessageDeliveryStatus.queued ||
        widget.deliveryStatus == MessageDeliveryStatus.uploading;

    // WhatsApp-style "20 % (Qalıb: 0:20)" line while uploading — replaces
    // the plain file-size subtitle only for that phase; the eta half is
    // omitted (percent alone) until _etaText() has enough samples to give a
    // real estimate rather than a divide-by-zero or a wild first guess.
    String? uploadStatusText;
    if (widget.deliveryStatus == MessageDeliveryStatus.uploading) {
      final percent = ((widget.localUploadProgress ?? 0) * 100).round();
      final eta = _etaText();
      uploadStatusText = eta != null ? '$percent % ($eta)' : '$percent %';
    }

    Widget leading;
    if (isUploading) {
      leading = SizedBox(
        width: _iconSlotSize,
        height: _iconSlotSize,
        child: UploadProgressOverlay(
          progress: widget.deliveryStatus == MessageDeliveryStatus.uploading
              ? widget.localUploadProgress
              : null,
          onCancel: widget.onCancelUpload,
        ),
      );
    } else if (_downloading) {
      leading = SizedBox(
        width: _iconSlotSize,
        height: _iconSlotSize,
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              value: _downloadProgress,
              strokeWidth: 3,
              color: kGold,
            ),
          ),
        ),
      );
    } else {
      leading = Container(
        width: _iconSlotSize,
        height: _iconSlotSize,
        decoration: BoxDecoration(
          color: iconColor.withAlpha(40),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: iconColor, size: 26),
      );
    }

    return GestureDetector(
      onTap: isUploading ? null : _handleTap,
      child: SizedBox(
        width: 230,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                leading,
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.fileName ?? 'Fayl',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: labelColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        uploadStatusText ?? _formatSize(widget.fileSizeBytes),
                        style: TextStyle(color: subColor, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(children: [const Spacer(), widget.timeCheckmarkRow]),
          ],
        ),
      ),
    );
  }
}
