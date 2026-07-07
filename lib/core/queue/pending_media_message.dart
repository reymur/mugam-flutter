import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../firebase/models.dart';

// A media message (photo/voice/video) queued locally because it couldn't be
// uploaded yet (offline, or the upload attempt failed). Nothing here is
// ever written to Firestore directly — messageId is the id the eventual
// real message document will use once it succeeds (see
// FirestoreService.generateMessageId), so retries are idempotent instead
// of creating duplicates.
class PendingMediaMessage {
  final String localId;
  final String messageId;
  final String chatId;
  final String senderId;
  final String type; // 'image' | 'audio' | 'video'
  final String filePath;
  final int createdAtMillis;
  final int attemptCount;
  final String status; // 'queued' | 'uploading' | 'failed'
  final String? replyToId;
  final String? replyToText;
  final String? replyToSenderName;
  final String? replyToImageURL;
  final String? replyToVideoURL;
  // Set once a prior attempt's upload step succeeded but the Firestore write
  // that followed it didn't (timeout/error) — the next attempt reuses this
  // instead of re-uploading the whole file again, which both wastes data and
  // widens the window in which two attempts can race to write the message.
  final String? uploadedUrl;
  // Read from the local file's own metadata at enqueue time (see
  // flutter_video_info in chat_screen.dart) — null if the probe failed or
  // this is an older item queued before the field existed.
  final int? videoDurationMs;
  // As-displayed (orientation-corrected) pixel size, read at the same time
  // as videoDurationMs. Carried as plain data instead of being derived from
  // a decoded thumbnail so the bubble sizes identically before and after
  // the pending item is replaced by the real sent message (they'd otherwise
  // resolve through different thumbnail-cache keys — local file path vs.
  // uploaded URL — causing a visible resize jump at that transition).
  final int? videoWidth;
  final int? videoHeight;
  // As-displayed pixel size read from the picked file at enqueue time (see
  // _probeImageSize in chat_screen.dart) — same rationale as
  // videoWidth/videoHeight above (plain data, not derived from a decoded
  // preview, so the bubble sizes identically before/after upload).
  final int? imageWidth;
  final int? imageHeight;
  // Fixed-length (40) 0-100 normalized amplitude bars captured live during
  // recording (see _downsampleWaveform in chat_screen.dart) — null for
  // non-audio items or ones queued before this field existed.
  final List<int>? waveform;
  // Real Storage upload fraction (0.0-1.0), image/video only — drives the
  // WhatsApp-style circular progress ring in chat_screen.dart. Deliberately
  // NOT persisted via toJson/fromJson: it's meaningless across an app
  // restart (a resumed 'queued' item re-uploads from scratch anyway, so it
  // correctly defaults back to 0.0 rather than showing stale progress).
  final double uploadProgress;
  // Captured once at enqueue time (see chat_screen.dart's
  // _uploadAndSendImageFile/_uploadAndSendVideoFile) — the full picked
  // photo's bytes for 'image', a small generated preview frame for
  // 'video'. Also deliberately NOT persisted via toJson/fromJson, same
  // reasoning as uploadProgress: meaningless (and wasteful to store) across
  // an app restart. Its whole purpose is letting the very first frame of
  // the pending bubble already be precached via precacheImage (called
  // before this item is ever enqueued/visible), eliminating the decode-gap
  // flash a fresh Image.file/generated-thumbnail read would otherwise show.
  final Uint8List? previewBytes;

  const PendingMediaMessage({
    required this.localId,
    required this.messageId,
    required this.chatId,
    required this.senderId,
    required this.type,
    required this.filePath,
    required this.createdAtMillis,
    this.attemptCount = 0,
    this.status = 'queued',
    this.replyToId,
    this.replyToText,
    this.replyToSenderName,
    this.replyToImageURL,
    this.replyToVideoURL,
    this.uploadedUrl,
    this.videoDurationMs,
    this.videoWidth,
    this.videoHeight,
    this.imageWidth,
    this.imageHeight,
    this.waveform,
    this.uploadProgress = 0.0,
    this.previewBytes,
  });

  static String generateLocalId() {
    final rand = Random().nextInt(1 << 32);
    return '${DateTime.now().microsecondsSinceEpoch}_$rand';
  }

  PendingMediaMessage copyWith({
    String? filePath,
    int? attemptCount,
    String? status,
    String? uploadedUrl,
    double? uploadProgress,
  }) {
    return PendingMediaMessage(
      localId: localId,
      messageId: messageId,
      chatId: chatId,
      senderId: senderId,
      type: type,
      filePath: filePath ?? this.filePath,
      createdAtMillis: createdAtMillis,
      attemptCount: attemptCount ?? this.attemptCount,
      status: status ?? this.status,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
      uploadedUrl: uploadedUrl ?? this.uploadedUrl,
      videoDurationMs: videoDurationMs,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      waveform: waveform,
      // Explicit status transitions reset progress — 'queued' (fresh retry
      // attempt) and 'failed' both mean whatever prior progress existed no
      // longer reflects an in-flight upload.
      uploadProgress: uploadProgress ?? (status != null ? 0.0 : this.uploadProgress),
      previewBytes: previewBytes,
    );
  }

  Map<String, dynamic> toJson() => {
    'localId': localId,
    'messageId': messageId,
    'chatId': chatId,
    'senderId': senderId,
    'type': type,
    'filePath': filePath,
    'createdAtMillis': createdAtMillis,
    'attemptCount': attemptCount,
    'status': status,
    'replyToId': replyToId,
    'replyToText': replyToText,
    'replyToSenderName': replyToSenderName,
    'replyToImageURL': replyToImageURL,
    'replyToVideoURL': replyToVideoURL,
    'uploadedUrl': uploadedUrl,
    'videoDurationMs': videoDurationMs,
    'videoWidth': videoWidth,
    'videoHeight': videoHeight,
    'imageWidth': imageWidth,
    'imageHeight': imageHeight,
    'waveform': waveform,
  };

  factory PendingMediaMessage.fromJson(Map<String, dynamic> json) {
    return PendingMediaMessage(
      localId: json['localId'] as String,
      messageId: json['messageId'] as String,
      chatId: json['chatId'] as String,
      senderId: json['senderId'] as String,
      type: json['type'] as String,
      filePath: json['filePath'] as String,
      createdAtMillis: json['createdAtMillis'] as int,
      attemptCount: json['attemptCount'] as int? ?? 0,
      status: json['status'] as String? ?? 'queued',
      replyToId: json['replyToId'] as String?,
      replyToText: json['replyToText'] as String?,
      replyToSenderName: json['replyToSenderName'] as String?,
      replyToImageURL: json['replyToImageURL'] as String?,
      replyToVideoURL: json['replyToVideoURL'] as String?,
      uploadedUrl: json['uploadedUrl'] as String?,
      videoDurationMs: json['videoDurationMs'] as int?,
      videoWidth: json['videoWidth'] as int?,
      videoHeight: json['videoHeight'] as int?,
      imageWidth: json['imageWidth'] as int?,
      imageHeight: json['imageHeight'] as int?,
      waveform: (json['waveform'] as List?)?.cast<int>(),
    );
  }

  // Rendered through the same bubble/checkmark code as a real message —
  // the 'local_' prefix keeps it from ever colliding with a real Firestore
  // message id.
  Message toSyntheticMessage() {
    return Message(
      id: 'local_$localId',
      senderId: senderId,
      text: '',
      type: type,
      imageURL: null,
      audioURL: null,
      videoURL: null,
      timestamp: Timestamp.fromMillisecondsSinceEpoch(createdAtMillis),
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
      localFilePath: filePath,
      localSendStatus: status,
      localUploadProgress: uploadProgress,
      mediaMessageId: messageId,
      localPreviewBytes: previewBytes,
      videoDurationMs: videoDurationMs,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      waveform: waveform,
    );
  }
}
