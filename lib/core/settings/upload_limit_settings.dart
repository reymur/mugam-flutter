import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../firebase/firestore_service.dart';

// Unlike hdImageUploadProvider (image_quality_settings.dart), this can't be
// a plain local SharedPreferences toggle — storage.rules enforces the limit
// server-side by reading users/{uid}.maxUploadSizeMb directly, so the value
// has to live in Firestore, not on-device. build() stays reactive on the
// live currentUserProvider stream rather than caching a local copy: the
// moment setMb's own write round-trips back through that same stream (near-
// instant, Firestore's local cache applies a pending write before the
// server ack), this provider's state updates too, with no separate local
// state to keep in sync.
class MaxUploadSizeMbNotifier extends Notifier<int> {
  static const int defaultMb = 100;
  static const int minMb = 100;
  static const int maxMb = 2048;

  @override
  int build() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return defaultMb;
    final asyncUser = ref.watch(currentUserProvider(uid));
    return asyncUser.value?.maxUploadSizeMb ?? defaultMb;
  }

  Future<void> setMb(int mb) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final clamped = mb.clamp(minMb, maxMb);
    await FirebaseFirestore.instance.collection('users').doc(uid).update({
      'maxUploadSizeMb': clamped,
    });
  }
}

final maxUploadSizeMbProvider =
    NotifierProvider<MaxUploadSizeMbNotifier, int>(
      MaxUploadSizeMbNotifier.new,
    );
