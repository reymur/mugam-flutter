import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

extension UserListFiltering on List<User> {
  List<User> excludingUid(String uid) => where((u) => u.id != uid).toList();
}

class User {
  final String id;
  final String name;
  final String emoji;
  final String instrument;
  final String city;
  final double rating;
  final int reviews;
  final bool available;
  final bool goldRing;
  final bool online;
  final String bio;
  final String? photoURL;
  final int gigs;
  final bool verified;
  final String role;
  // Server-enforced cap (storage.rules reads this same field via
  // firestore.get()) on any single chat-media/file upload, in megabytes —
  // user-configurable in Settings, range [100, 2048]. Defaults to 100 for
  // any user doc written before this field existed.
  final int maxUploadSizeMb;

  const User({
    required this.id,
    required this.name,
    required this.emoji,
    required this.instrument,
    required this.city,
    required this.rating,
    required this.reviews,
    required this.available,
    required this.goldRing,
    required this.online,
    required this.bio,
    this.photoURL,
    this.gigs = 0,
    this.verified = false,
    this.role = 'user',
    this.maxUploadSizeMb = 100,
  });

  factory User.fromFirestore(String id, Map<String, dynamic> data) {
    return User(
      id: id,
      name: (data['name'] ?? data['displayName'] ?? 'İstifadəçi') as String,
      emoji: (data['emoji'] ?? '🎵') as String,
      instrument: (data['instrument'] ?? data['specialty'] ?? '') as String,
      city: (data['city'] ?? '') as String,
      rating: ((data['rating'] ?? 0) as num).toDouble(),
      reviews: (data['reviews'] ?? 0) as int,
      available: (data['available'] ?? false) as bool,
      goldRing: (data['goldRing'] ?? false) as bool,
      online: (data['online'] ?? false) as bool,
      bio: (data['bio'] ?? '') as String,
      photoURL: data['photoURL'] as String?,
      gigs: (data['gigs'] ?? 0) as int,
      verified: (data['verified'] ?? false) as bool,
      role: (data['role'] ?? 'user') as String,
      maxUploadSizeMb: (data['maxUploadSizeMb'] ?? 100) as int,
    );
  }
}

class Chat {
  final String id;
  final String name;
  final String emoji;
  final String lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;
  final List<String> members;
  final bool isGroup;
  final String? photoURL;
  final bool completed;

  const Chat({
    required this.id,
    required this.name,
    required this.emoji,
    required this.lastMessage,
    this.lastMessageTime,
    required this.unreadCount,
    required this.members,
    required this.isGroup,
    this.photoURL,
    this.completed = false,
  });

  factory Chat.fromFirestore(String id, Map<String, dynamic> data) {
    return Chat(
      id: id,
      name: data['name'] ?? '',
      emoji: data['emoji'] ?? '💬',
      lastMessage: data['lastMessage'] ?? '',
      lastMessageTime: data['lastMessageTime'] != null
          ? (data['lastMessageTime'] as Timestamp).toDate()
          : null,
      unreadCount: () {
        final raw = data['unreadCount'];
        if (raw == null) return 0;
        if (raw is int) return raw;
        if (raw is Map) {
          // per-user unread count map — sum all values or return 0
          try {
            return (raw.values.fold<int>(
              0,
              (acc, v) => acc + (v is int ? v : 0),
            ));
          } catch (_) {
            return 0;
          }
        }
        return 0;
      }(),
      members: List<String>.from(data['members'] as List? ?? const []),
      isGroup: data['isGroup'] ?? false,
      photoURL: data['photoURL'],
      completed: (data['completed'] ?? false) as bool,
    );
  }
}

class Message {
  final String id;
  final String senderId;
  final String text;
  final String? imageURL;
  final String? audioURL;
  final String? videoURL;
  // Real duration/as-displayed pixel size read from the source file's own
  // metadata at send time (flutter_video_info) — null for messages sent
  // before these fields existed. width/height are carried as plain data
  // (not derived from a decoded thumbnail) so the video bubble sizes
  // identically before and after a pending item is replaced by the real
  // sent message.
  final int? videoDurationMs;
  final int? videoWidth;
  final int? videoHeight;
  // As-displayed pixel size read from the picked file at send time (see
  // _probeImageSize in chat_screen.dart) — null for messages sent before
  // this field existed. Same rationale as videoWidth/videoHeight: carried
  // as plain data so the photo bubble sizes identically before and after a
  // pending item is replaced by the real sent message.
  final int? imageWidth;
  final int? imageHeight;
  // Identify exactly which validated Storage upload this message's media
  // came from — mediaOriginChatId is the chat the file was actually
  // uploaded into (equals this message's own chat for a fresh send, or an
  // earlier chat's id when this message is a forward), mediaFileName is
  // the object name under chats/{mediaOriginChatId}/. Together they let
  // firestore.rules confirm a validatedUploads marker exists rather than
  // trusting the imageURL/videoURL/audioURL string outright. Null for any
  // message sent before this field existed — such messages can no longer
  // be forwarded (see toggleReaction/onChatMediaUploaded security pass).
  final String? mediaOriginChatId;
  final String? mediaFileName;
  // 'file' type only — fileName is the original human-readable name the
  // sender picked (used for display and as the extension source for the
  // local open/download cache), distinct from mediaFileName above (the
  // Storage object's own name, messageId-based like every other media
  // type). fileSizeBytes is informational (already enforced server-side by
  // storage.rules against the sender's own maxUploadSizeMb at upload time).
  final String? fileURL;
  final String? fileName;
  final int? fileSizeBytes;
  // 'location' type only — a static snapshot of the map at the picked
  // point (captured client-side via RepaintBoundary, uploaded through the
  // same flat Storage path as every other media type — no Google Static
  // Maps API call, see LocationPickerScreen), plus the actual coordinates
  // it was captured at. Kept as its own field rather than reusing imageURL
  // so a location message can never be mistaken for (or rendered by) the
  // plain 'image' bubble/gallery-filter logic elsewhere, same reasoning as
  // fileURL being separate from imageURL above.
  final String? locationImageURL;
  final double? latitude;
  final double? longitude;
  // Fixed-length (40) 0-100 normalized amplitude bars captured live during
  // recording — null for messages sent before this field existed.
  final List<int>? waveform;
  // Uids who have actually started playback of this voice message at
  // least once — distinct from chat-level read receipts (lastReadMsgId),
  // which only mean the recipient scrolled past it. Written via
  // FirestoreService.markVoiceMessageListened.
  final List<String> listenedBy;
  final Timestamp? timestamp;
  final String type; // 'text', 'image', 'audio', 'video', 'file', 'location'
  final String? replyToId;
  final String? replyToText;
  final String? replyToSenderName;
  final String? replyToImageURL;
  final String? replyToVideoURL;
  final bool deletedForAll;
  final List<String> deletedFor;
  final String? deletedAt;
  final Map<String, List<String>> reactions;
  // Client-only, never round-tripped through Firestore (fromFirestore never
  // sets these) — used solely to render a not-yet-sent pending-queue item
  // as a synthetic Message. localSendStatus is null for every real,
  // server-confirmed message; 'queued' | 'uploading' | 'failed' otherwise.
  final String? localFilePath;
  final String? localSendStatus;
  // Real Storage upload fraction (0.0-1.0) while localSendStatus is
  // 'queued'/'uploading' — image/video only, null otherwise. See
  // PendingMediaMessage.uploadProgress for where this comes from.
  final double? localUploadProgress;
  // Already-decoded preview bytes captured at send time (the full picked
  // photo for 'image', a small generated frame for 'video') — set only on
  // a synthetic pending message, see PendingMediaMessage.previewBytes for
  // why: it lets the bubble paint the real image on its very first frame
  // (via a precacheImage call made before this message ever became
  // visible) instead of a decode gap flashing the placeholder background.
  final Uint8List? localPreviewBytes;
  // Client-only, set only on a synthetic pending message (see
  // PendingMediaMessage.toSyntheticMessage) to the real Firestore doc id
  // this item will use once it sends. Needed because a pending message's
  // own `id` is deliberately 'local_$localId' (never collides with a real
  // Firestore id — see PendingMediaMessage), so `id` alone changes across
  // the pending->sent transition even though it's the same logical
  // message. Null for a real, server-confirmed message (its `id` is
  // already that final value). Use stableMediaKey below rather than this
  // field directly.
  final String? mediaMessageId;
  // True for auto-generated announcements ("X created the group", "X left
  // the group") — rendered as centered gray text, no bubble/avatar, same
  // as mugam-v2's own system messages (see createGroupChat/leaveGroup
  // there). senderId for these is the real acting user's uid (not a
  // literal 'system' string) so the existing onNewMessage push-notification
  // Cloud Function still resolves a real display name — isSystem is purely
  // a rendering distinction, not a push-routing one.
  final bool isSystem;

  // The one identifier that stays constant across a message's entire
  // lifecycle (queued -> uploading -> sent), used to key anything that
  // must survive that transition without visibly resetting (see
  // MediaThumbnailCacheManager).
  String get stableMediaKey => mediaMessageId ?? id;

  const Message({
    required this.id,
    required this.senderId,
    required this.text,
    this.imageURL,
    this.audioURL,
    this.videoURL,
    this.videoDurationMs,
    this.videoWidth,
    this.videoHeight,
    this.imageWidth,
    this.imageHeight,
    this.mediaOriginChatId,
    this.mediaFileName,
    this.fileURL,
    this.fileName,
    this.fileSizeBytes,
    this.locationImageURL,
    this.latitude,
    this.longitude,
    this.waveform,
    this.listenedBy = const [],
    this.timestamp,
    required this.type,
    this.replyToId,
    this.replyToText,
    this.replyToSenderName,
    this.replyToImageURL,
    this.replyToVideoURL,
    this.deletedForAll = false,
    this.deletedFor = const [],
    this.deletedAt,
    this.reactions = const {},
    this.localFilePath,
    this.localSendStatus,
    this.localUploadProgress,
    this.mediaMessageId,
    this.localPreviewBytes,
    this.isSystem = false,
  });

  factory Message.fromFirestore(String id, Map<String, dynamic> data) {
    final replyTo = data['replyTo'] as Map<String, dynamic>?;
    final rawReactions = data['reactions'] as Map<String, dynamic>? ?? {};
    return Message(
      id: id,
      senderId: data['senderId'] ?? '',
      text: data['text'] ?? '',
      imageURL: data['imageURL'],
      audioURL: data['audioURL'],
      videoURL: data['videoURL'],
      videoDurationMs: data['videoDurationMs'] as int?,
      videoWidth: data['videoWidth'] as int?,
      videoHeight: data['videoHeight'] as int?,
      imageWidth: data['imageWidth'] as int?,
      imageHeight: data['imageHeight'] as int?,
      mediaOriginChatId: data['mediaOriginChatId'] as String?,
      mediaFileName: data['mediaFileName'] as String?,
      fileURL: data['fileURL'] as String?,
      fileName: data['fileName'] as String?,
      fileSizeBytes: data['fileSizeBytes'] as int?,
      locationImageURL: data['locationImageURL'] as String?,
      latitude: (data['latitude'] as num?)?.toDouble(),
      longitude: (data['longitude'] as num?)?.toDouble(),
      waveform: (data['waveform'] as List?)?.cast<int>(),
      listenedBy: List<String>.from(data['listenedBy'] as List? ?? const []),
      timestamp: data['timestamp'] as Timestamp?,
      type: data['type'] ?? 'text',
      replyToId: replyTo?['id'] as String?,
      replyToText: replyTo?['text'] as String?,
      replyToSenderName: replyTo?['senderName'] as String?,
      replyToImageURL: replyTo?['imageURL'] as String?,
      replyToVideoURL: replyTo?['videoURL'] as String?,
      deletedForAll: data['deletedForAll'] ?? false,
      deletedFor: List<String>.from(data['deletedFor'] as List? ?? const []),
      deletedAt: data['deletedAt'] as String?,
      reactions: {
        for (final entry in rawReactions.entries)
          entry.key: List<String>.from(entry.value as List? ?? const []),
      },
      isSystem: data['isSystem'] == true,
    );
  }
}

// Carries Firestore's own added/modified/removed distinction through to the
// chat screen so it can tell "history just loaded" and "a reaction/read-
// receipt changed on an existing message" apart from "a new message was
// actually appended" — the three cases that matter for deciding whether to
// auto-scroll. isInitialLoad/addedMessageIds are about this particular
// stream *subscription's* lifecycle, independent of whatever's already on
// screen from the message cache.
class MessagesSnapshot {
  final List<Message> messages;
  final bool isInitialLoad;
  final List<String> addedMessageIds;

  const MessagesSnapshot({
    required this.messages,
    required this.isInitialLoad,
    required this.addedMessageIds,
  });
}

class StarredMessage {
  final String id; // == original message id
  final String chatId;
  final String chatName;
  final String senderId;
  final String senderName;
  final String text;
  final String type; // 'text', 'image', 'audio', 'video', 'file', 'location'
  final String? imageURL;
  final String? audioURL;
  final String? videoURL;
  final String? fileURL;
  final String? fileName;
  final Timestamp? timestamp;
  final Timestamp? starredAt;

  const StarredMessage({
    required this.id,
    required this.chatId,
    required this.chatName,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.type,
    this.imageURL,
    this.audioURL,
    this.videoURL,
    this.fileURL,
    this.fileName,
    this.timestamp,
    this.starredAt,
  });

  factory StarredMessage.fromFirestore(String id, Map<String, dynamic> data) {
    return StarredMessage(
      id: id,
      chatId: data['chatId'] ?? '',
      chatName: data['chatName'] ?? '',
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? '',
      text: data['text'] ?? '',
      type: data['type'] ?? 'text',
      imageURL: data['imageURL'] as String?,
      audioURL: data['audioURL'] as String?,
      videoURL: data['videoURL'] as String?,
      fileURL: data['fileURL'] as String?,
      fileName: data['fileName'] as String?,
      timestamp: data['timestamp'] as Timestamp?,
      starredAt: data['starredAt'] as Timestamp?,
    );
  }
}

class Event {
  final String id;
  final String day;
  final String month;
  final String title;
  final String location;
  final List<String> tags;
  final List<String> tagColors;
  final String? spots;

  const Event({
    required this.id,
    required this.day,
    required this.month,
    required this.title,
    required this.location,
    required this.tags,
    required this.tagColors,
    this.spots,
  });

  factory Event.fromFirestore(String id, Map<String, dynamic> data) {
    return Event(
      id: id,
      day: (data['day'] ?? '') as String,
      month: (data['month'] ?? '') as String,
      title: (data['title'] ?? '') as String,
      location: (data['location'] ?? '') as String,
      tags: List<String>.from(data['tags'] as List? ?? const []),
      tagColors: List<String>.from(data['tagColors'] as List? ?? const []),
      spots: data['spots'] as String?,
    );
  }
}

class Room {
  final String id;
  final String emoji;
  final String name;
  final String members;
  final String preview;
  final bool live;
  final int avatarCount;

  const Room({
    required this.id,
    required this.emoji,
    required this.name,
    required this.members,
    required this.preview,
    required this.live,
    required this.avatarCount,
  });

  factory Room.fromFirestore(String id, Map<String, dynamic> data) {
    return Room(
      id: id,
      emoji: (data['emoji'] ?? '🏛️') as String,
      name: (data['name'] ?? '') as String,
      members: (data['members'] ?? '') as String,
      preview: (data['preview'] ?? '') as String,
      live: (data['live'] ?? false) as bool,
      avatarCount: (data['avatarCount'] ?? 0) as int,
    );
  }
}

class PersonalEvent {
  final String id;
  final String ownerUid;
  final String date;
  final String type;
  final String location;
  final String notes;
  final List<String> participantUids;
  final bool isAgree;
  final String? agreementChatId;
  final String? partnerUid;
  final String? partnerName;
  final String status;
  final String? cancelledBy;
  final dynamic createdAt;

  const PersonalEvent({
    required this.id,
    required this.ownerUid,
    required this.date,
    required this.type,
    required this.location,
    required this.notes,
    required this.participantUids,
    required this.isAgree,
    this.agreementChatId,
    this.partnerUid,
    this.partnerName,
    this.status = 'agreed',
    this.cancelledBy,
    this.createdAt,
  });

  factory PersonalEvent.fromFirestore(String id, Map<String, dynamic> data) {
    return PersonalEvent(
      id: id,
      ownerUid: (data['ownerUid'] ?? '') as String,
      date: (data['date'] ?? '') as String,
      type: (data['type'] ?? '') as String,
      location: (data['location'] ?? '') as String,
      notes: (data['notes'] ?? '') as String,
      participantUids: List<String>.from(data['musicians'] as List? ?? const []),
      isAgree: (data['isAgree'] ?? false) as bool,
      agreementChatId: data['agreementChatId'] as String?,
      partnerUid: data['partnerUid'] as String?,
      partnerName: data['partnerName'] as String?,
      status: (data['status'] ?? 'agreed') as String,
      cancelledBy: data['cancelledBy'] as String?,
      createdAt: data['createdAt'],
    );
  }
}
