import 'dart:math';

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
  });

  static String generateLocalId() {
    final rand = Random().nextInt(1 << 32);
    return '${DateTime.now().microsecondsSinceEpoch}_$rand';
  }

  PendingMediaMessage copyWith({
    String? filePath,
    int? attemptCount,
    String? status,
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
    );
  }
}
