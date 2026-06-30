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
