import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'europe-west3',
  );

  Future<User?> fetchUserById(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return User.fromFirestore(doc.id, doc.data()!);
  }

  Stream<User?> watchUserById(String uid) {
    return _db.collection('users').doc(uid).snapshots().map(
      (doc) => doc.exists ? User.fromFirestore(doc.id, doc.data()!) : null,
    );
  }

  Future<String> uploadAvatar({
    required String uid,
    required String filePath,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('avatars')
        .child('$uid.jpg');
    await ref.putFile(File(filePath));
    return await ref.getDownloadURL();
  }

  Future<void> updateUserProfile({
    required String uid,
    required String displayName,
    required String bio,
    required String instrument,
    required String city,
    required bool available,
    String? photoURL,
  }) async {
    await _db.collection('users').doc(uid).update({
      'displayName': displayName,
      'bio': bio,
      'instrument': instrument,
      'specialty': instrument,
      'city': city,
      'available': available,
      'updatedAt': FieldValue.serverTimestamp(),
      if (photoURL != null) 'photoURL': photoURL,
    });
  }

  Stream<List<User>> _watchUsers(Query<Map<String, dynamic>> query) {
    return query.snapshots().map(
      (snap) =>
          snap.docs.map((doc) => User.fromFirestore(doc.id, doc.data())).toList(),
    );
  }

  Stream<List<User>> watchMusicians() {
    return _watchUsers(_db.collection('users').where('role', isEqualTo: 'musician'));
  }

  // Unfiltered by role — screens that need to pick from any registered
  // user (e.g. tagging event participants), unlike watchMusicians() above
  // which powers the home screen's musician-only feed.
  Stream<List<User>> watchAllUsers() {
    return _watchUsers(_db.collection('users'));
  }

  Stream<List<Chat>> watchChats(String uid) {
    return _db
        .collection('chats')
        .where('members', arrayContains: uid)
        .snapshots()
        .map(
          (snap) =>
              snap.docs
                  .map((doc) => Chat.fromFirestore(doc.id, doc.data()))
                  // mugam-v2 marks a direct chat completed once the pair
                  // finalizes a Razılaşma (agreement) and starts a fresh
                  // chat doc the next time they talk — its own chat list
                  // hides completed chats the same way, so without this
                  // filter every past agreement's chat resurfaces as a
                  // separate duplicate entry for the same person.
                  .where((chat) => !chat.completed)
                  .toList()
                ..sort((a, b) {
                  if (a.lastMessageTime == null && b.lastMessageTime == null) {
                    return 0;
                  }
                  if (a.lastMessageTime == null) return 1;
                  if (b.lastMessageTime == null) return -1;
                  return b.lastMessageTime!.compareTo(a.lastMessageTime!);
                }),
        );
  }

  Stream<List<Message>> watchMessages(String chatId) {
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => Message.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  Map<String, dynamic>? _buildReplyTo({
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
  }) {
    if (replyToId == null) return null;
    final map = <String, dynamic>{
      'id': replyToId,
      'text': replyToText ?? '',
      'senderName': replyToSenderName ?? '',
    };
    if (replyToImageURL != null) {
      map['imageURL'] = replyToImageURL;
    }
    if (replyToVideoURL != null) {
      map['videoURL'] = replyToVideoURL;
    }
    return map;
  }

  // Generates a message doc id client-side, up front, before any upload or
  // send attempt — used by the pending-media queue so every retry of the
  // same queued item writes to the same doc via sendXMessage's messageId
  // param instead of creating a new document each time.
  String generateMessageId(String chatId) {
    return _db.collection('chats').doc(chatId).collection('messages').doc().id;
  }

  // Used by sendImageMessage/sendAudioMessage/sendVideoMessage when a
  // messageId is provided (i.e. a queued offline media send). The offline
  // queue's retry() and its automatic per-chat loop — or the foreground
  // queue and the WorkManager background task — can end up both attempting
  // the same queued item at once, each with its own freshly uploaded file
  // URL. A plain .set() would let whichever write lands last silently
  // overwrite the other's videoURL/imageURL/audioURL. Wrapping it in a
  // transaction that only writes if the document doesn't exist yet makes
  // the second, racing write a no-op instead of a corruption.
  Future<bool> _writeMessageIfAbsent({
    required String chatId,
    required String messageId,
    required Map<String, dynamic> data,
  }) {
    final ref = _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);
    return _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists) return false;
      tx.set(ref, data);
      return true;
    });
  }

  Future<void> sendMessage({
    required String chatId,
    required String senderId,
    required String text,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
  }) async {
    final now = FieldValue.serverTimestamp();
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    await _db.collection('chats').doc(chatId).collection('messages').add({
      'senderId': senderId,
      'text': text,
      'type': 'text',
      'clientPlatform': 'flutter',
      'timestamp': now,
      'imageURL': null,
      'audioURL': null,
      if (replyTo != null) 'replyTo': replyTo,
    });
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': text,
      'lastMessageTime': now,
    });
  }

  // customMetadata is enforced by storage.rules (uploaderUid/chatId must
  // match the real request.auth.uid and the path's chatId, or the write is
  // rejected outright) — by the time onChatMediaUploaded's onFinalize
  // trigger reads it back, it's guaranteed authentic, not just
  // self-reported. fileName is caller-provided (derived from the
  // already-idempotent messageId, not DateTime.now()) so retries of the
  // same queued item always target the same Storage object instead of
  // orphaning a fresh one on every attempt.
  Future<String> uploadChatImage({
    required String chatId,
    required String filePath,
    required String senderId,
    required String fileName,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(chatId)
        .child(fileName);
    await ref.putFile(
      File(filePath),
      SettableMetadata(
        customMetadata: {'uploaderUid': senderId, 'chatId': chatId},
      ),
    );
    return await ref.getDownloadURL();
  }

  Future<void> sendImageMessage({
    required String chatId,
    required String senderId,
    required String imageURL,
    int? imageWidth,
    int? imageHeight,
    // Which validated upload this image actually is: mediaOriginChatId ==
    // chatId for a fresh send, or an earlier chat's id when forwarding an
    // existing message's photo. Required (by firestore.rules) for every
    // flutter-sent image message — see Message.mediaOriginChatId.
    String? mediaOriginChatId,
    String? mediaFileName,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
    // If provided, writes with .doc(messageId).set(...) instead of .add(...)
    // — makes retries of this exact same send idempotent (same id = same
    // document, no duplicate) instead of creating a new document each retry.
    String? messageId,
  }) async {
    final now = FieldValue.serverTimestamp();
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    final data = {
      'senderId': senderId,
      'text': '',
      'type': 'image',
      'clientPlatform': 'flutter',
      'imageURL': imageURL,
      if (imageWidth != null) 'imageWidth': imageWidth,
      if (imageHeight != null) 'imageHeight': imageHeight,
      if (mediaOriginChatId != null) 'mediaOriginChatId': mediaOriginChatId,
      if (mediaFileName != null) 'mediaFileName': mediaFileName,
      'audioURL': null,
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    };
    bool wrote = true;
    if (messageId != null) {
      wrote = await _writeMessageIfAbsent(
        chatId: chatId,
        messageId: messageId,
        data: data,
      );
    } else {
      await _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(data);
    }
    if (!wrote) return;
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🖼 Şəkil',
      'lastMessageTime': now,
    });
  }

  Future<String> uploadChatVideo({
    required String chatId,
    required String filePath,
    required String senderId,
    required String fileName,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(chatId)
        .child(fileName);
    await ref.putFile(
      File(filePath),
      SettableMetadata(
        customMetadata: {'uploaderUid': senderId, 'chatId': chatId},
      ),
    );
    return await ref.getDownloadURL();
  }

  Future<void> sendVideoMessage({
    required String chatId,
    required String senderId,
    required String videoURL,
    int? videoDurationMs,
    int? videoWidth,
    int? videoHeight,
    String? mediaOriginChatId,
    String? mediaFileName,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
    String? messageId,
  }) async {
    final now = FieldValue.serverTimestamp();
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    final data = {
      'senderId': senderId,
      'text': '',
      'type': 'video',
      'clientPlatform': 'flutter',
      'videoURL': videoURL,
      if (videoDurationMs != null) 'videoDurationMs': videoDurationMs,
      if (videoWidth != null) 'videoWidth': videoWidth,
      if (videoHeight != null) 'videoHeight': videoHeight,
      if (mediaOriginChatId != null) 'mediaOriginChatId': mediaOriginChatId,
      if (mediaFileName != null) 'mediaFileName': mediaFileName,
      'imageURL': null,
      'audioURL': null,
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    };
    bool wrote = true;
    if (messageId != null) {
      wrote = await _writeMessageIfAbsent(
        chatId: chatId,
        messageId: messageId,
        data: data,
      );
    } else {
      await _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(data);
    }
    if (!wrote) return;
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🎥 Video',
      'lastMessageTime': now,
    });
  }

  Future<String> uploadChatAudio({
    required String chatId,
    required String filePath,
    required String senderId,
    required String fileName,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(chatId)
        .child(fileName);
    await ref.putFile(
      File(filePath),
      SettableMetadata(
        customMetadata: {'uploaderUid': senderId, 'chatId': chatId},
      ),
    );
    return await ref.getDownloadURL();
  }

  Future<void> sendAudioMessage({
    required String chatId,
    required String senderId,
    required String audioURL,
    List<int>? waveform,
    String? mediaOriginChatId,
    String? mediaFileName,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
    String? messageId,
  }) async {
    final now = FieldValue.serverTimestamp();
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    final data = {
      'senderId': senderId,
      'text': '',
      'type': 'audio',
      'clientPlatform': 'flutter',
      'audioURL': audioURL,
      if (waveform != null) 'waveform': waveform,
      if (mediaOriginChatId != null) 'mediaOriginChatId': mediaOriginChatId,
      if (mediaFileName != null) 'mediaFileName': mediaFileName,
      'imageURL': null,
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    };
    bool wrote = true;
    if (messageId != null) {
      wrote = await _writeMessageIfAbsent(
        chatId: chatId,
        messageId: messageId,
        data: data,
      );
    } else {
      await _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(data);
    }
    if (!wrote) return;
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🎤 Səs mesajı',
      'lastMessageTime': now,
    });
  }

  // Waits for the onChatMediaUploaded Storage trigger to write its
  // validatedUploads marker for a just-uploaded file — without this, the
  // caller's next step (creating the message doc) would race the trigger
  // and fail firestore.rules' validation check most of the time, since the
  // trigger typically takes a second or more to fire. Uses a snapshot
  // listener rather than blindly retrying the message-doc write itself, so
  // a normal-latency wait never produces a doomed write attempt. Returns
  // false (not an exception) on timeout so the caller can fold it into its
  // own existing retry/backoff cycle rather than treating it as a distinct
  // error class.
  Future<bool> waitForValidatedUpload({
    required String chatId,
    required String fileName,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final ref = _db
        .collection('validatedUploads')
        .doc(chatId)
        .collection('files')
        .doc(fileName);
    final existing = await ref.get();
    if (existing.exists) return true;

    final completer = Completer<bool>();
    final sub = ref.snapshots().listen((snap) {
      if (snap.exists && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  }

  // Distinct from the chat-level lastReadMsgId (which only means the
  // recipient scrolled past this message) — this records that `uid`
  // actually started playback at least once. arrayUnion is idempotent and
  // creates the field if it doesn't exist yet, so this is safe to call on
  // messages sent before this field existed too.
  Future<void> markVoiceMessageListened({
    required String chatId,
    required String messageId,
    required String uid,
  }) {
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .update({
          'listenedBy': FieldValue.arrayUnion([uid]),
        });
  }

  Future<void> deleteMessageForAll({
    required String chatId,
    required String messageId,
  }) async {
    await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .update({
          'deletedForAll': true,
          'deletedAt': DateTime.now().toIso8601String(),
          'text': '',
        });
  }

  Future<void> deleteMessageForMe({
    required String chatId,
    required String messageId,
    required String uid,
  }) async {
    await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .update({
          'deletedFor': FieldValue.arrayUnion([uid]),
        });
  }

  // Reactions are written exclusively by the toggleMessageReaction Cloud
  // Function — a client-side transaction can't be validated by Firestore
  // rules at the field-content level (rules see "reactions changed", not
  // "only the caller's own uid moved within it"), so a modified client
  // could otherwise forge another user's reaction. `uid` is no longer
  // taken as a parameter here: the function derives it from the caller's
  // own auth token, which is the whole point.
  Future<void> toggleReaction({
    required String chatId,
    required String messageId,
    required String emoji,
  }) async {
    await _functions.httpsCallable('toggleMessageReaction').call({
      'chatId': chatId,
      'messageId': messageId,
      'emoji': emoji,
    });
  }

  Future<void> deleteMessagePermanently({
    required String chatId,
    required String messageId,
  }) async {
    await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .delete();
  }

  Future<void> starMessage({
    required String uid,
    required String chatId,
    required String chatName,
    required String senderName,
    required Message message,
  }) async {
    await _db
        .collection('users')
        .doc(uid)
        .collection('starred')
        .doc(message.id)
        .set({
          'chatId': chatId,
          'chatName': chatName,
          'senderId': message.senderId,
          'senderName': senderName,
          'text': message.text,
          'type': message.type,
          'imageURL': message.imageURL,
          'audioURL': message.audioURL,
          'videoURL': message.videoURL,
          'timestamp': message.timestamp,
          'starredAt': FieldValue.serverTimestamp(),
        });
  }

  Future<void> unstarMessage({required String uid, required String messageId}) {
    return _db
        .collection('users')
        .doc(uid)
        .collection('starred')
        .doc(messageId)
        .delete();
  }

  Stream<List<StarredMessage>> watchStarredMessages(String uid) {
    return _db
        .collection('users')
        .doc(uid)
        .collection('starred')
        .orderBy('starredAt', descending: true)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => StarredMessage.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  Future<Map<String, dynamic>?> fetchChatData(String chatId) async {
    final doc = await _db.collection('chats').doc(chatId).get();
    return doc.data();
  }

  Stream<Map<String, dynamic>> watchChatMeta(String chatId) {
    return _db.collection('chats').doc(chatId).snapshots().map((snap) {
      final data = snap.data() ?? {};
      return {
        'members': List<String>.from(data['members'] ?? const []),
        'deliveredTo': Map<String, dynamic>.from(data['deliveredTo'] ?? {}),
        'lastReadMsgId': Map<String, dynamic>.from(data['lastReadMsgId'] ?? {}),
        'lastReadAt': Map<String, dynamic>.from(data['lastReadAt'] ?? {}),
      };
    });
  }

  Future<void> markChatAsDelivered({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'deliveredTo.$uid': DateTime.now().toIso8601String(),
      });
    } catch (_) {}
  }

  // Tracks who's currently viewing a chat so the push-notification Cloud
  // Function can skip notifying them — mirrors mugam-v2's
  // addActiveUser/removeActiveUser exactly (same field, same arrayUnion/
  // arrayRemove semantics).
  Future<void> addActiveUser({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'activeUsers': FieldValue.arrayUnion([uid]),
      });
    } catch (_) {}
  }

  Future<void> removeActiveUser({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'activeUsers': FieldValue.arrayRemove([uid]),
      });
    } catch (_) {}
  }

  // Logout cleanup, mirroring mugam-v2's pre-signOut steps: mark the user
  // offline and defensively strip their uid from every chat's activeUsers
  // (in case they logged out without normally leaving a chat first, which
  // would otherwise leave them permanently exempt from push notifications).
  Future<void> setUserOnline(String uid, bool online) async {
    try {
      await _db.collection('users').doc(uid).update({'online': online});
    } catch (_) {}
  }

  Future<void> clearActiveUserFromAllChats(String uid) async {
    try {
      final snap = await _db
          .collection('chats')
          .where('activeUsers', arrayContains: uid)
          .get();
      for (final doc in snap.docs) {
        await doc.reference.update({
          'activeUsers': FieldValue.arrayRemove([uid]),
        });
      }
    } catch (_) {}
  }

  Future<void> markChatAsReadBy({
    required String chatId,
    required String uid,
    required String lastMsgId,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'readBy': FieldValue.arrayUnion([uid]),
        'lastReadAt.$uid': DateTime.now().toIso8601String(),
        'lastReadMsgId.$uid': lastMsgId,
      });
    } catch (_) {}
  }

  Future<List<Event>> fetchEvents() async {
    final snap = await _db.collection('events').limit(10).get();
    return snap.docs
        .map((doc) => Event.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  Future<List<Room>> fetchRooms() async {
    final snap = await _db.collection('rooms').limit(10).get();
    return snap.docs
        .map((doc) => Room.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  Stream<List<PersonalEvent>> watchPersonalEvents(String uid) {
    return _db
        .collection('personalEvents')
        .where('ownerUid', isEqualTo: uid)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => PersonalEvent.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  Stream<List<PersonalEvent>> watchEventsAsParticipant(String uid) {
    return _db
        .collection('personalEvents')
        .where('musicians', arrayContains: uid)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => PersonalEvent.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  Future<String> addPersonalEvent({
    required String ownerUid,
    required String date,
    required String type,
    required String location,
    required String notes,
    required List<String> participantUids,
  }) async {
    final ref = await _db.collection('personalEvents').add({
      'ownerUid': ownerUid,
      'date': date,
      'type': type,
      'location': location,
      'notes': notes,
      'musicians': participantUids,
      'isAgree': false,
      'agreementChatId': null,
      'partnerUid': null,
      'partnerName': null,
      'status': 'agreed',
      'cancelledBy': null,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  Future<void> updatePersonalEvent(String eventId, Map<String, dynamic> data) {
    return _db.collection('personalEvents').doc(eventId).update(data);
  }

  Future<List<String>> loadReadAgreementIds(String uid) async {
    try {
      final doc = await _db.collection('users').doc(uid).get();
      if (!doc.exists) return [];
      return (doc.data()?['readAgreementIds'] as List?)?.cast<String>() ?? [];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveReadAgreementId(String uid, String agreementId) {
    return _db.collection('users').doc(uid).update({
      'readAgreementIds': FieldValue.arrayUnion([agreementId]),
    });
  }
}

final firestoreServiceProvider = Provider<FirestoreService>(
  (_) => FirestoreService(),
);

final musiciansProvider = StreamProvider<List<User>>(
  (ref) => ref.watch(firestoreServiceProvider).watchMusicians(),
);

final allUsersProvider = StreamProvider<List<User>>(
  (ref) => ref.watch(firestoreServiceProvider).watchAllUsers(),
);

final userByIdProvider = FutureProvider.family<User?, String>((
  ref,
  uid,
) {
  return ref.watch(firestoreServiceProvider).fetchUserById(uid);
});

final currentUserProvider = StreamProvider.family<User?, String>((
  ref,
  uid,
) {
  return ref.watch(firestoreServiceProvider).watchUserById(uid);
});

final eventsProvider = FutureProvider<List<Event>>(
  (ref) => ref.watch(firestoreServiceProvider).fetchEvents(),
);

final roomsProvider = FutureProvider<List<Room>>(
  (ref) => ref.watch(firestoreServiceProvider).fetchRooms(),
);

final personalEventsProvider =
    StreamProvider.family<List<PersonalEvent>, String>(
      (ref, uid) =>
          ref.watch(firestoreServiceProvider).watchPersonalEvents(uid),
    );

final eventsAsParticipantProvider =
    StreamProvider.family<List<PersonalEvent>, String>(
      (ref, uid) =>
          ref.watch(firestoreServiceProvider).watchEventsAsParticipant(uid),
    );

final chatsProvider = StreamProvider.family<List<Chat>, String>((ref, uid) {
  return ref.watch(firestoreServiceProvider).watchChats(uid);
});

final messagesProvider = StreamProvider.autoDispose.family<List<Message>, String>((
  ref,
  chatId,
) {
  return ref.watch(firestoreServiceProvider).watchMessages(chatId);
});

final chatDataProvider = FutureProvider.family<Map<String, dynamic>?, String>((
  ref,
  chatId,
) {
  return ref.watch(firestoreServiceProvider).fetchChatData(chatId);
});

final chatMetaProvider = StreamProvider.family<Map<String, dynamic>, String>((
  ref,
  chatId,
) {
  return ref.watch(firestoreServiceProvider).watchChatMeta(chatId);
});

final starredMessagesProvider =
    StreamProvider.family<List<StarredMessage>, String>((ref, uid) {
      return ref.watch(firestoreServiceProvider).watchStarredMessages(uid);
    });
