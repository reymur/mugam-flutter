import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../firebase/firestore_service.dart';

// TEMPORARY / INTERIM presence solution — see docs/presence-system.md for
// the full writeup. Cloud Firestore has no native disconnect-detection
// primitive, so this approximates presence with a periodic heartbeat write
// instead of a real persistent connection, and has an inherent staleness
// window as a result. Once the planned WebSocket Gateway server (shared
// infra for calls, live location, live gameplay, and typing indicators)
// exists, presence should be derived from that connection instead and this
// service retired.
class PresenceService with WidgetsBindingObserver {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  // Long enough to keep Firestore write volume low (one write per
  // foregrounded user per minute, app-wide); short enough that `online`
  // rarely lags reality by more than a few tens of seconds while the app is
  // actually in the foreground.
  static const _heartbeatInterval = Duration(seconds: 60);

  final FirestoreService _firestoreService = FirestoreService();
  String? _uid;
  Timer? _timer;
  bool _observing = false;

  void start(String uid) {
    if (_uid == uid && _timer != null) return;
    _uid = uid;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _writePresence(online: true);
    _startTimer();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    final uid = _uid;
    _uid = null;
    if (uid != null) {
      await _firestoreService.setUserPresence(uid, online: false);
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      _heartbeatInterval,
      (_) => _writePresence(online: true),
    );
  }

  void _writePresence({required bool online}) {
    final uid = _uid;
    if (uid == null) return;
    unawaited(_firestoreService.setUserPresence(uid, online: online));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_uid == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _writePresence(online: true);
        _startTimer();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // Pause rather than immediately writing online:false — a brief
        // backgrounding (switching apps, camera, share sheet) shouldn't
        // flicker the presence dot offline. `online` goes stale for
        // genuinely-backgrounded users until they return (resumed rewrites
        // it immediately above) or sign out (stop() writes the final
        // online:false). This is the accepted tradeoff of this interim
        // heartbeat system — see docs/presence-system.md.
        _timer?.cancel();
        _timer = null;
    }
  }
}
