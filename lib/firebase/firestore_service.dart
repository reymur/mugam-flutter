import 'package:cloud_firestore/cloud_firestore.dart';
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
        .map((snap) =>
            snap.docs.map((doc) => Musician.fromFirestore(doc.id, doc.data())).toList());
  }

  Future<List<Event>> fetchEvents() async {
    final snap = await _db.collection('events').limit(10).get();
    return snap.docs.map((doc) => Event.fromFirestore(doc.id, doc.data())).toList();
  }

  Future<List<Room>> fetchRooms() async {
    final snap = await _db.collection('rooms').limit(10).get();
    return snap.docs.map((doc) => Room.fromFirestore(doc.id, doc.data())).toList();
  }

  Stream<List<PersonalEvent>> watchPersonalEvents(String uid) {
    return _db
        .collection('personalEvents')
        .where('ownerUid', isEqualTo: uid)
        .snapshots()
        .map((snap) =>
            snap.docs.map((doc) => PersonalEvent.fromFirestore(doc.id, doc.data())).toList());
  }

  Stream<List<PersonalEvent>> watchEventsAsMusician(String uid) {
    return _db
        .collection('personalEvents')
        .where('musicians', arrayContains: uid)
        .snapshots()
        .map((snap) =>
            snap.docs.map((doc) => PersonalEvent.fromFirestore(doc.id, doc.data())).toList());
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
    StreamProvider.family<List<PersonalEvent>, String>((ref, uid) =>
        ref.watch(firestoreServiceProvider).watchPersonalEvents(uid));

final eventsAsMusicianProvider =
    StreamProvider.family<List<PersonalEvent>, String>((ref, uid) =>
        ref.watch(firestoreServiceProvider).watchEventsAsMusician(uid));
