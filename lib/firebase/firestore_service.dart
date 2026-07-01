import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

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

  Future<void> sendMessage({
    required String chatId,
    required String senderId,
    required String text,
  }) async {
    final now = FieldValue.serverTimestamp();
    await _db.collection('chats').doc(chatId).collection('messages').add({
      'senderId': senderId,
      'text': text,
      'type': 'text',
      'timestamp': now,
      'imageURL': null,
      'audioURL': null,
      'replyToId': null,
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
  }) async {
    final now = FieldValue.serverTimestamp();
    await _db.collection('chats').doc(chatId).collection('messages').add({
      'senderId': senderId,
      'text': '',
      'type': 'image',
      'imageURL': imageURL,
      'audioURL': null,
      'timestamp': now,
      'replyToId': null,
    });
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🖼 Şəkil',
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
  }) async {
    final now = FieldValue.serverTimestamp();
    await _db.collection('chats').doc(chatId).collection('messages').add({
      'senderId': senderId,
      'text': '',
      'type': 'audio',
      'audioURL': audioURL,
      'imageURL': null,
      'timestamp': now,
      'replyToId': null,
    });
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🎤 Səs mesajı',
      'lastMessageTime': now,
    });
  }

  Future<Map<String, dynamic>?> fetchChatData(String chatId) async {
    final doc = await _db.collection('chats').doc(chatId).get();
    return doc.data();
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
