import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// Mirrors mugam-v2's users/{uid}/pushTokens/{deviceId} = {token, updatedAt}
// shape exactly (same collection, same field names, updatedAt as an ISO
// string rather than a Firestore Timestamp) so the shared Cloud Function
// dispatcher can read either app's tokens the same way.
class PushNotificationService {
  PushNotificationService._();
  static final PushNotificationService instance = PushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  String? _registeredUid;
  StreamSubscription<String>? _tokenRefreshSub;

  Future<String> _deviceId() async {
    final info = DeviceInfoPlugin();
    if (Platform.isIOS) {
      final iosInfo = await info.iosInfo;
      return iosInfo.identifierForVendor ?? 'unknown-ios';
    }
    final androidInfo = await info.androidInfo;
    return androidInfo.id;
  }

  Future<void> registerToken(String uid) async {
    try {
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      // On iOS the FCM token isn't available until the APNS handshake
      // completes; right after a cold start that can still be in flight, so
      // a single retry after a short delay avoids a spurious failure here.
      String? token;
      try {
        token = await _messaging.getToken();
      } catch (_) {
        await Future.delayed(const Duration(seconds: 2));
        token = await _messaging.getToken();
      }
      if (token == null) return;

      await _saveToken(uid, token);
      _registeredUid = uid;
      _tokenRefreshSub ??= _messaging.onTokenRefresh.listen((newToken) {
        if (_registeredUid != null) _saveToken(_registeredUid!, newToken);
      });
    } catch (_) {
      // Best-effort, matching mugam-v2's registerFCMToken swallow-and-log.
    }
  }

  Future<void> _saveToken(String uid, String token) async {
    final deviceId = await _deviceId();
    await _db
        .collection('users')
        .doc(uid)
        .collection('pushTokens')
        .doc(deviceId)
        .set({'token': token, 'updatedAt': DateTime.now().toIso8601String()});
  }

  Future<void> unregisterToken(String uid) async {
    try {
      final deviceId = await _deviceId();
      await _db
          .collection('users')
          .doc(uid)
          .collection('pushTokens')
          .doc(deviceId)
          .delete();
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'PushNotificationService: unregisterToken failed',
      );
    }
    _registeredUid = null;
  }

  // Shows the system banner/sound/badge even while the app is foregrounded —
  // otherwise iOS suppresses notification-payload pushes whenever the app is
  // already open. Every push our Cloud Function sends is a notification
  // payload, so this is the only foreground handling needed; no data-only
  // messages, so no onBackgroundMessage handler is required either — APNs
  // displays those natively while backgrounded/terminated.
  Future<void> setupForegroundPresentation() async {
    if (!Platform.isIOS) return;
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  // Covers both the "app was backgrounded, user tapped the notification"
  // path (onMessageOpenedApp) and the "app was fully terminated, the
  // notification launched it" cold-start path (getInitialMessage) — mirrors
  // mugam-v2's onNotificationTap handling both cases.
  void setupMessageOpenedHandler(void Function(Map<String, dynamic> data) onTap) {
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      onTap(message.data);
    });
    _messaging.getInitialMessage().then((message) {
      if (message != null) onTap(message.data);
    });
  }
}
