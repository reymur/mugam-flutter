import 'dart:async';

import '../../firebase/firestore_service.dart';
import '../../firebase/models.dart';

class CallListenerService {
  CallListenerService._();
  static final CallListenerService instance = CallListenerService._();
  final FirestoreService _firestoreService = FirestoreService();
  StreamSubscription<Call?>? _sub;
  void Function(Call call)? _onIncomingCall;
  // Guards against Firestore emitting more than one snapshot event for the
  // same ringing call (e.g. a cache-then-server pair, or a metadata-only
  // reconnect event) — without this, onIncomingCall could fire — and the
  // router could push the incoming-call screen — more than once for the
  // exact same call.
  String? _lastNotifiedCallId;

  void start(String uid, void Function(Call call) onIncomingCall) {
    _onIncomingCall = onIncomingCall;
    _sub?.cancel();
    _sub = _firestoreService.watchIncomingCalls(uid).listen((call) {
      if (call == null) {
        _lastNotifiedCallId = null;
        return;
      }
      if (call.id == _lastNotifiedCallId) return;
      _lastNotifiedCallId = call.id;
      _onIncomingCall?.call(call);
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _onIncomingCall = null;
    _lastNotifiedCallId = null;
  }
}
