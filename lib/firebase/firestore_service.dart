import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<Musician?> fetchUserById(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return Musician.fromFirestore(doc.id, doc.data()!);
  }

  Stream<Musician?> watchUserById(String uid) {
    return _db.collection('users').doc(uid).snapshots().map(
      (doc) => doc.exists ? Musician.fromFirestore(doc.id, doc.data()!) : null,
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

  Stream<List<Musician>> watchMusicians() {
    return _db
        .collection('users')
        .where('role', isEqualTo: 'musician')
        .limit(50)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => Musician.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
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

  Future<String> uploadChatImage({
    required String chatId,
    required String filePath,
  }) async {
    final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(chatId)
        .child(fileName);
    await ref.putFile(File(filePath));
    return await ref.getDownloadURL();
  }

  Future<void> sendImageMessage({
    required String chatId,
    required String senderId,
    required String imageURL,
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
      'text': '',
      'type': 'image',
      'clientPlatform': 'flutter',
      'imageURL': imageURL,
      'audioURL': null,
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    });
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🖼 Şəkil',
      'lastMessageTime': now,
    });
  }

  Future<String> uploadChatVideo({
    required String chatId,
    required String filePath,
  }) async {
    final ext = filePath.contains('.') ? filePath.split('.').last : 'mp4';
    final fileName = 'video_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(chatId)
        .child(fileName);
    await ref.putFile(File(filePath));
    return await ref.getDownloadURL();
  }

  Future<void> sendVideoMessage({
    required String chatId,
    required String senderId,
    required String videoURL,
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
      'text': '',
      'type': 'video',
      'clientPlatform': 'flutter',
      'videoURL': videoURL,
      'imageURL': null,
      'audioURL': null,
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    });
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🎥 Video',
      'lastMessageTime': now,
    });
  }

  Future<String> uploadChatAudio({
    required String chatId,
    required String filePath,
  }) async {
    final fileName = 'audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(chatId)
        .child(fileName);
    await ref.putFile(File(filePath));
    return await ref.getDownloadURL();
  }

  Future<void> sendAudioMessage({
    required String chatId,
    required String senderId,
    required String audioURL,
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
      'text': '',
      'type': 'audio',
      'clientPlatform': 'flutter',
      'audioURL': audioURL,
      'imageURL': null,
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    });
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🎤 Səs mesajı',
      'lastMessageTime': now,
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

  Future<void> toggleReaction({
    required String chatId,
    required String messageId,
    required String uid,
    required String emoji,
  }) async {
    final docRef = _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);
    await _db.runTransaction((transaction) async {
      final snap = await transaction.get(docRef);
      final raw = snap.data()?['reactions'] as Map<String, dynamic>? ?? {};
      final reactions = <String, List<String>>{
        for (final entry in raw.entries)
          entry.key: List<String>.from(entry.value as List? ?? const []),
      };
      final hadThisEmoji = reactions[emoji]?.contains(uid) ?? false;
      for (final key in reactions.keys.toList()) {
        reactions[key]!.remove(uid);
        if (reactions[key]!.isEmpty) reactions.remove(key);
      }
      if (!hadThisEmoji) {
        reactions.putIfAbsent(emoji, () => []).add(uid);
      }
      transaction.update(docRef, {'reactions': reactions});
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

  Stream<List<PersonalEvent>> watchEventsAsMusician(String uid) {
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
    required List<String> musicians,
  }) async {
    final ref = await _db.collection('personalEvents').add({
      'ownerUid': ownerUid,
      'date': date,
      'type': type,
      'location': location,
      'notes': notes,
      'musicians': musicians,
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

final musiciansProvider = StreamProvider<List<Musician>>(
  (ref) => ref.watch(firestoreServiceProvider).watchMusicians(),
);

final userByIdProvider = FutureProvider.family<Musician?, String>((
  ref,
  uid,
) {
  return ref.watch(firestoreServiceProvider).fetchUserById(uid);
});

final currentUserProvider = StreamProvider.family<Musician?, String>((
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

final eventsAsMusicianProvider =
    StreamProvider.family<List<PersonalEvent>, String>(
      (ref, uid) =>
          ref.watch(firestoreServiceProvider).watchEventsAsMusician(uid),
    );

final chatsProvider = StreamProvider.family<List<Chat>, String>((ref, uid) {
  return ref.watch(firestoreServiceProvider).watchChats(uid);
});

final messagesProvider = StreamProvider.family<List<Message>, String>((
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
