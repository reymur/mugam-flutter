import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/models/activity_type.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential> loginWithEmail(String email, String password) async {
    return await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  Future<UserCredential> registerWithEmail({
    required String email,
    required String password,
    required String displayName,
    required ActivityType? activityType,
    required String city,
    required String role,
  }) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    await cred.user?.updateDisplayName(displayName);

    // instrument/specialty stay derived display strings, same rationale as
    // FirestoreService.updateUserProfile — every screen reading them as
    // plain text keeps working regardless of which flow (register vs edit
    // profile) last wrote the user's activity type.
    final instrumentLabel = activityType?.toDisplayLabel() ?? '';
    await _firestore.collection('users').doc(cred.user!.uid).set({
      'uid': cred.user!.uid,
      'displayName': displayName,
      'email': email,
      'instrument': instrumentLabel,
      'activityType': activityType?.toMap(),
      'activityInstruments': activityType?.toSearchableInstruments() ?? [],
      'city': city,
      'emoji': '🎵',
      'rating': 0,
      'reviews': 0,
      'available': false,
      'verified': false,
      'followers': 0,
      'gigs': 0,
      'bio': '',
      'fcmToken': '',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'role': role == 'musiqici' ? 'musician' : 'user',
      'specialty': instrumentLabel,
      if (role == 'musiqici') ...{'goldRing': false, 'online': true},
    });

    return cred;
  }

  Future<void> logout() async {
    await _auth.signOut();
  }

  Future<void> resetPassword(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  User? get currentUser => _auth.currentUser;
}
