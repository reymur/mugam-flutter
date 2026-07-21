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
  final Timestamp? lastSeen;
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
  // UI-state only, not sensitive — client-written the moment
  // FriendRequestsScreen opens (see markFriendRequestsViewed), compared
  // against each incoming FriendRequest.createdAt to drive the unread dot
  // on the settings gear icon and the Dost sorğuları row. Deliberately a
  // separate field from lastSeen above, which is presence-only.
  final Timestamp? lastViewedFriendRequestsAt;
  // Denormalized onto the user doc by onStatusCreated (functions/src/
  // index.ts) — the expiresAt of whichever status that trigger most
  // recently saw, regardless of privacyMode/isPublic (the avatar ring this
  // backs is a presence-style "do they currently have one" indicator, not a
  // visibility check — every screen showing a ring already fetches this
  // same User doc, same free-ride as isActuallyOnline below, avoiding an
  // N+1 per-row status query). Deliberately NOT recomputed on expiry itself
  // (no scheduled function exists, and Firestore's own TTL-based cleanup on
  // statuses can lag up to 24h behind expiresAt — see Status.expiresAt's
  // own comment) — hasActiveStatus below is what actually keeps this
  // truthful moment-to-moment despite that, the same way isActuallyOnline
  // cross-checks a possibly-stale `online` bool against lastSeen.
  final Timestamp? mostRecentStatusExpiresAt;
  // Denormalized alongside mostRecentStatusExpiresAt by the same
  // onStatusCreated trigger (arrayUnion on create, arrayRemove by
  // onStatusDeleted on delete — explicit or TTL-driven expiry, both fire
  // the same trigger). What mostRecentStatusExpiresAt alone can't provide:
  // a get()-able document id. A non-friend viewer can never list
  // users/{ownerUid}/statuses (that query stays visibleToUids-gated,
  // unchanged by the isPublic/get() split — see firestore.rules), so this
  // is how such a viewer's client discovers which statusId(s) to get()
  // once isPublic authorizes actually reading one. Defaults to an empty
  // list for any user doc predating this field, same as every other
  // predates-the-field default in this file.
  final List<String> activeStatusIds;
  // Denormalized alongside mostRecentStatusExpiresAt/activeStatusIds by the
  // same onStatusCreated trigger, just the new status's createdAt instead
  // of expiresAt — this is the "gold ring" side of ring parity: a fixed
  // point in time this owner most recently posted, compared against a
  // viewer's own lastViewedStatusOwnerAt entry for this owner (see
  // hasUnviewedStatusFrom below) to tell a truly-unviewed status apart
  // from one the viewer already saw. Never recomputed on expiry, same
  // caveat as mostRecentStatusExpiresAt.
  final Timestamp? mostRecentStatusCreatedAt;
  // Lives on the VIEWER's own user doc (not the owner's) — keyed by
  // ownerUid, one entry per status-author this viewer has ever viewed a
  // status from. Written client-side, batched alongside the existing
  // viewers/{viewerUid} write in FirestoreService.markStatusViewed (same
  // call, same batch, no new server trigger) — see that method's own
  // comment. Purely self-scoped ring-rendering state, not security-
  // relevant the way viewers/{viewerUid}'s own viewedAt is (that field
  // gates what the STATUS OWNER can see about who viewed them), so unlike
  // that field this one carries no serverTimestamp()-enforcement rule.
  // Defaults to an empty map for any user doc predating this field.
  final Map<String, Timestamp> lastViewedStatusOwnerAt;

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
    this.lastSeen,
    required this.bio,
    this.photoURL,
    this.gigs = 0,
    this.verified = false,
    this.role = 'user',
    this.maxUploadSizeMb = 100,
    this.lastViewedFriendRequestsAt,
    this.mostRecentStatusExpiresAt,
    this.activeStatusIds = const [],
    this.mostRecentStatusCreatedAt,
    this.lastViewedStatusOwnerAt = const {},
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
      lastSeen: data['lastSeen'] as Timestamp?,
      bio: (data['bio'] ?? '') as String,
      photoURL: data['photoURL'] as String?,
      gigs: (data['gigs'] ?? 0) as int,
      verified: (data['verified'] ?? false) as bool,
      role: (data['role'] ?? 'user') as String,
      maxUploadSizeMb: (data['maxUploadSizeMb'] ?? 100) as int,
      lastViewedFriendRequestsAt: data['lastViewedFriendRequestsAt'] as Timestamp?,
      mostRecentStatusExpiresAt: data['mostRecentStatusExpiresAt'] as Timestamp?,
      activeStatusIds:
          List<String>.from(data['activeStatusIds'] as List? ?? const []),
      mostRecentStatusCreatedAt: data['mostRecentStatusCreatedAt'] as Timestamp?,
      lastViewedStatusOwnerAt:
          (data['lastViewedStatusOwnerAt'] as Map<String, dynamic>? ?? const {})
              .map((key, value) => MapEntry(key, value as Timestamp)),
    );
  }

  // `online` alone isn't trustworthy — PresenceService's heartbeat pauses
  // (not clears) on backgrounding, so a long-backgrounded user can stay
  // `online: true` indefinitely with no further write until they return or
  // sign out (see docs/presence-system.md). Cross-checking against lastSeen
  // corrects for that: 2 minutes is double the 60s heartbeat interval, so
  // one missed/delayed beat doesn't falsely flip someone offline.
  bool get isActuallyOnline {
    if (!online) return false;
    final seen = lastSeen;
    if (seen == null) return false;
    return DateTime.now().difference(seen.toDate()) < const Duration(minutes: 2);
  }

  // Same shape as isActuallyOnline above: a denormalized field alone isn't
  // trustworthy (mostRecentStatusExpiresAt is only ever written forward by
  // onStatusCreated, never cleared), so this cross-checks it against the
  // current time client-side — exactly the same query-time expiry check
  // watchStatusFeed's own expiresAt filter already relies on, just applied
  // to this one denormalized timestamp instead of a live query.
  bool get hasActiveStatus =>
      mostRecentStatusExpiresAt != null &&
      mostRecentStatusExpiresAt!.toDate().isAfter(DateTime.now());

  // Gold/muted ring parity check: called on the VIEWER's own User instance
  // (`this`), passed the status OWNER's User instance — mirrors where each
  // field actually lives (lastViewedStatusOwnerAt on the viewer's doc,
  // mostRecentStatusCreatedAt on the owner's doc). True ("gold", unviewed)
  // when the owner has ever posted a status and either this viewer has
  // never viewed anything from that owner, or their last view of that
  // owner predates the owner's most recent post.
  bool hasUnviewedStatusFrom(User owner) {
    if (owner.mostRecentStatusCreatedAt == null) return false;
    final lastViewed = lastViewedStatusOwnerAt[owner.id];
    return lastViewed == null ||
        lastViewed.toDate().isBefore(owner.mostRecentStatusCreatedAt!.toDate());
  }
}

class Chat {
  final String id;
  final String name;
  final String emoji;
  final String lastMessage;
  final DateTime? lastMessageTime;
  // uids who deleted-for-themselves the message that lastMessage currently
  // denormalizes — lastMessage/lastMessageTime stay the one shared value
  // for every member (WhatsApp parity: deleting for yourself never changes
  // what anyone else sees), so a viewer whose own uid is in this list shows
  // the "Bu mesajı sildiniz" placeholder instead of lastMessage; every other
  // member keeps seeing the real preview. Reset to [] whenever lastMessage
  // itself changes to a different message (see firestore_service.dart's
  // send*/​_refreshLastMessagePreview).
  final List<String> lastMessageDeletedFor;
  final int unreadCount;
  final List<String> members;
  final bool isGroup;
  final String? photoURL;
  final bool completed;
  // Empty for every 1:1 chat (mugam-v2 never wrote either field for those —
  // only createGroupChat does) and for group docs from before these fields
  // existed, so an empty default is the correct "absent" value here, not a
  // parsing error.
  final List<String> admins;
  final String createdBy;
  // How many messages currently exist in this chat (not lifetime-ever-sent)
  // — server-owned via onNewMessage/onMessageDeleted's symmetric Firestore
  // triggers (see functions/src/index.ts), not incremented client-side.
  // Defaults to 0 for any chat doc that predates this field, same as
  // admins/createdBy above.
  final int messageCount;

  const Chat({
    required this.id,
    required this.name,
    required this.emoji,
    required this.lastMessage,
    this.lastMessageTime,
    this.lastMessageDeletedFor = const [],
    required this.unreadCount,
    required this.members,
    required this.isGroup,
    this.photoURL,
    this.completed = false,
    this.admins = const [],
    this.createdBy = '',
    this.messageCount = 0,
  });

  // uid is the viewing (signed-in) user — unreadCount is stored server-side
  // as a per-user map ({uid: count}, see onNewMessage/markChatAsReadBy in
  // functions/src/index.ts and firestore_service.dart), so this must read
  // only that uid's own entry. Summing every entry in the map would show
  // the combined unread count of every participant, not this user's own.
  factory Chat.fromFirestore(String id, Map<String, dynamic> data, String uid) {
    return Chat(
      id: id,
      name: data['name'] ?? '',
      emoji: data['emoji'] ?? '💬',
      lastMessage: data['lastMessage'] ?? '',
      lastMessageTime: data['lastMessageTime'] != null
          ? (data['lastMessageTime'] as Timestamp).toDate()
          : null,
      lastMessageDeletedFor: List<String>.from(
        data['lastMessageDeletedFor'] as List? ?? const [],
      ),
      unreadCount: () {
        final raw = data['unreadCount'];
        if (raw is int) return raw;
        if (raw is Map) return (raw[uid] as num?)?.toInt() ?? 0;
        return 0;
      }(),
      members: List<String>.from(data['members'] as List? ?? const []),
      isGroup: data['isGroup'] ?? false,
      photoURL: data['photoURL'],
      completed: (data['completed'] ?? false) as bool,
      admins: List<String>.from(data['admins'] as List? ?? const []),
      createdBy: data['createdBy'] ?? '',
      messageCount: (data['messageCount'] as num?)?.toInt() ?? 0,
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
  // A reply to someone's status/story (WhatsApp-style swipe-up), as opposed
  // to a reply to another chat message (replyToId above). Deliberately a
  // SEPARATE set of fields rather than repurposing replyToId: replyToId's
  // own tap handler (_scrollToMessage in chat_screen.dart) searches this
  // chat's own message history for a doc with that id, which a statusId
  // would never match — it would silently hang searching, then report "not
  // found", rather than opening the status. replyToStatusOwnerUid is
  // required alongside replyToStatusId because UserStatusViewerScreen (the
  // screen this reply's own tap handler opens) needs the author's uid up
  // front to fetch their status group — a status doc's id alone doesn't
  // encode who posted it without a separate lookup.
  final String? replyToStatusId;
  final String? replyToStatusOwnerUid;
  final String? replyToStatusType; // 'text' | 'image' | 'video'
  final String? replyToStatusText;
  final String? replyToStatusThumbnailURL;
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
  // How many times this message has been forwarded — 0 for a normal send.
  // Set from the source message's own forwardCount + 1 when
  // _forwardMessage builds a forwarded copy (chat_screen.dart), so
  // forwarding an already-forwarded message grows the chain depth rather
  // than resetting it. Drives the "Yönləndirilib"/"Dəfələrlə
  // yönləndirilib" bubble label. num? rather than int? in fromFirestore
  // below, matching Chat.messageCount's own pattern (Phase B) — Firestore
  // can hand back either representation depending on how the value was
  // written/read.
  final int forwardCount;

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
    this.replyToStatusId,
    this.replyToStatusOwnerUid,
    this.replyToStatusType,
    this.replyToStatusText,
    this.replyToStatusThumbnailURL,
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
    this.forwardCount = 0,
  });

  factory Message.fromFirestore(String id, Map<String, dynamic> data) {
    final replyTo = data['replyTo'] as Map<String, dynamic>?;
    final replyToStatus = data['replyToStatus'] as Map<String, dynamic>?;
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
      replyToStatusId: replyToStatus?['id'] as String?,
      replyToStatusOwnerUid: replyToStatus?['ownerUid'] as String?,
      replyToStatusType: replyToStatus?['type'] as String?,
      replyToStatusText: replyToStatus?['text'] as String?,
      replyToStatusThumbnailURL: replyToStatus?['thumbnailURL'] as String?,
      deletedForAll: data['deletedForAll'] ?? false,
      deletedFor: List<String>.from(data['deletedFor'] as List? ?? const []),
      deletedAt: data['deletedAt'] as String?,
      reactions: {
        for (final entry in rawReactions.entries)
          entry.key: List<String>.from(entry.value as List? ?? const []),
      },
      isSystem: data['isSystem'] == true,
      forwardCount: (data['forwardCount'] as num?)?.toInt() ?? 0,
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

// users/{ownerUid}/statuses/{statusId} — a WhatsApp-style 24h status post.
// expiresAt is set client-side at creation (createdAt + 24h) and is what
// every read-path query must filter on; the Firestore TTL policy on this
// same field is storage cleanup only (deletion can lag up to 24h behind
// expiresAt per Firestore's own TTL semantics) and is never the authority
// for whether a status is still visible.
class Status {
  final String id;
  final String ownerUid;
  final String type; // 'text' | 'image' | 'video'
  final String? mediaUrl;
  final String? text;
  final String? caption;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String privacyMode; // 'contacts' | 'contactsExcept' | 'onlyShareWith'
  // Exception list for 'contactsExcept', allowlist for 'onlyShareWith',
  // empty for 'contacts'.
  final List<String> privacyList;
  // Denormalized, server-computed audience for this status — the exact set
  // of uids (always including ownerUid) allowed to read it, derived from
  // privacyMode/privacyList + the owner's friends at the time this field
  // was last written. NEVER set by the client: it's computed and
  // maintained exclusively by Cloud Functions (onStatusCreated at
  // creation, then kept in sync by the friend-change propagation in
  // onFriendRequestUpdated/onFriendRequestDeleted — see
  // functions/src/index.ts). The client only ever reads it, as the
  // array-contains filter for its own collectionGroup('statuses') feed
  // query — firestore.rules requires every list/query read to be provably
  // scoped this way, which an exists()-based check can't satisfy.
  final List<String> visibleToUids;
  // Server-computed alongside visibleToUids by the same onStatusCreated
  // trigger — true for 'contacts'/'contactsExcept', false for
  // 'onlyShareWith' (see functions/src/index.ts). Backs firestore.rules'
  // isPublic-based `allow get` rule (a single-doc read, e.g. viewing one
  // person's status from their profile), which is now separate from the
  // unchanged visibleToUids-based `allow list` rule the feed's
  // collectionGroup query still depends on. Defaults to false for any
  // status doc written before this field existed, same as messageCount/
  // admins/createdBy's own predates-the-field defaults elsewhere in this
  // file — those legacy docs simply aren't get()-able via the new public
  // path, only via visibleToUids like before.
  final bool isPublic;

  const Status({
    required this.id,
    required this.ownerUid,
    required this.type,
    this.mediaUrl,
    this.text,
    this.caption,
    required this.createdAt,
    required this.expiresAt,
    required this.privacyMode,
    this.privacyList = const [],
    this.visibleToUids = const [],
    required this.isPublic,
  });

  factory Status.fromFirestore(String id, Map<String, dynamic> data) {
    return Status(
      id: id,
      ownerUid: (data['ownerUid'] ?? '') as String,
      type: (data['type'] ?? 'text') as String,
      mediaUrl: data['mediaUrl'] as String?,
      text: data['text'] as String?,
      caption: data['caption'] as String?,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      expiresAt: (data['expiresAt'] as Timestamp).toDate(),
      privacyMode: (data['privacyMode'] ?? 'contacts') as String,
      privacyList: List<String>.from(data['privacyList'] as List? ?? const []),
      visibleToUids:
          List<String>.from(data['visibleToUids'] as List? ?? const []),
      isPublic: (data['isPublic'] as bool?) ?? false,
    );
  }
}

// One owner's currently-visible-to-me statuses, grouped for the feed bar
// (one ring per owner, not one per status). Built client-side by
// FirestoreService.watchStatusFeed from the flat collectionGroup query
// result — not a Firestore document shape of its own.
class StatusGroup {
  final String ownerUid;
  final List<Status> statuses; // sorted by createdAt ascending

  const StatusGroup({required this.ownerUid, required this.statuses});
}

// One entry in a status owner's viewers/{viewerUid} subcollection — see
// firestore.rules' match /viewers/{viewerUid} for the write shape this
// mirrors (exactly one field, viewedAt, enforced server-side as
// request.time). Owner-only readable as a list; a viewer may only read
// their own single record (see FirestoreService.markStatusViewed and
// hasViewedStatus, which already use this subcollection without needing
// this model, since they only ever check/write a single known uid).
class StatusViewer {
  final String uid;
  final DateTime viewedAt;

  const StatusViewer({required this.uid, required this.viewedAt});

  factory StatusViewer.fromFirestore(String uid, Map<String, dynamic> data) {
    return StatusViewer(
      uid: uid,
      viewedAt: (data['viewedAt'] as Timestamp).toDate(),
    );
  }
}

// friendRequests/{requestId} — a Facebook-style friend request between two
// users. requestId is deliberately NOT an auto-id: FirestoreService derives
// it from the two uids (sorted, joined by '_'), so there can only ever be
// one document for a given pair — this is what prevents both the "two
// people send each other a request at the same instant" race and silent
// duplicate requests, without needing a transaction or an extra query.
//
// Lifecycle: created with status 'pending' by whoever sends the request →
// either transitions to 'accepted' (recipient only) or the document is
// deleted outright. Deletion deliberately covers three distinct user
// actions with one operation — sender cancels a still-pending request,
// recipient declines a still-pending request, and either side unfriends an
// already-accepted one — because at the data level all three are the same
// thing: this pair no longer has a request/friendship. See firestore.rules
// for the corresponding `allow delete` and functions/src/index.ts's
// onFriendRequestDeleted for what it triggers.
//
// On acceptance, a Cloud Function (onFriendRequestUpdated) writes a
// mirrored users/{uid}/friends/{otherUid} doc on both sides — nothing in
// this app writes that subcollection directly, same rationale as the
// existing users/{uid}/contacts/{otherUid} denormalization.
enum FriendRequestStatus { pending, accepted }

FriendRequestStatus _friendRequestStatusFromString(String value) {
  return value == 'accepted'
      ? FriendRequestStatus.accepted
      : FriendRequestStatus.pending;
}

class FriendRequest {
  final String id;
  final String fromUid;
  final String toUid;
  final FriendRequestStatus status;
  final Timestamp? createdAt;
  final Timestamp? respondedAt;

  const FriendRequest({
    required this.id,
    required this.fromUid,
    required this.toUid,
    required this.status,
    this.createdAt,
    this.respondedAt,
  });

  bool isBetween(String uidA, String uidB) =>
      (fromUid == uidA && toUid == uidB) || (fromUid == uidB && toUid == uidA);

  // Who the *other* party is, from the given viewer's perspective — used
  // by the UI to decide whether the viewer sent or received this request.
  String otherUid(String viewerUid) => fromUid == viewerUid ? toUid : fromUid;

  factory FriendRequest.fromFirestore(String id, Map<String, dynamic> data) {
    return FriendRequest(
      id: id,
      fromUid: (data['fromUid'] ?? '') as String,
      toUid: (data['toUid'] ?? '') as String,
      status: _friendRequestStatusFromString(
        (data['status'] ?? 'pending') as String,
      ),
      createdAt: data['createdAt'] as Timestamp?,
      respondedAt: data['respondedAt'] as Timestamp?,
    );
  }
}

enum CallStatus { ringing, accepted, declined, ended }

enum CallType { audio, video }

CallStatus _callStatusFromString(String value) => CallStatus.values.firstWhere(
  (e) => e.name == value,
  orElse: () => CallStatus.ringing,
);

CallType _callTypeFromString(String value) => CallType.values.firstWhere(
  (e) => e.name == value,
  orElse: () => CallType.audio,
);

class Call {
  final String id; // == channelName, same as Cloud Functions' callId
  final String callerId;
  final String calleeId;
  final CallStatus status;
  final CallType type;
  final Timestamp? createdAt;
  // CallKit (iOS)/ConnectionService (Android) call id — a real UUID,
  // deliberately distinct from `id` above. Generated once, server-side, by
  // startCall (see its own comment on why) — never generate a second one
  // client-side, caller and callee must show the exact same value.
  final String callkitUuid;
  // Caller's display name, resolved server-side by startCall so the
  // callee's native call UI can show it immediately (no extra Firestore
  // round-trip client-side, which would delay that UI appearing at all).
  final String callerName;

  const Call({
    required this.id,
    required this.callerId,
    required this.calleeId,
    required this.status,
    required this.type,
    required this.callkitUuid,
    required this.callerName,
    this.createdAt,
  });

  String otherUid(String viewerUid) => callerId == viewerUid ? calleeId : callerId;

  factory Call.fromFirestore(String id, Map<String, dynamic> data) {
    return Call(
      id: id,
      callerId: (data['callerId'] ?? '') as String,
      calleeId: (data['calleeId'] ?? '') as String,
      status: _callStatusFromString((data['status'] ?? 'ringing') as String),
      type: _callTypeFromString((data['type'] ?? 'audio') as String),
      callkitUuid: (data['callkitUuid'] ?? '') as String,
      callerName: (data['callerName'] ?? 'Zəng') as String,
      createdAt: data['createdAt'] as Timestamp?,
    );
  }
}
