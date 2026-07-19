import 'dart:async';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
// The main library file doesn't re-export its own entities (CallEvent,
// CallKitParams, AndroidParams, IOSParams, ...) — this barrel is required
// separately, or those names don't resolve at all.
import 'package:flutter_callkit_incoming/entities/entities.dart';
import '../../firebase/firestore_service.dart';
import '../../navigation/app_router.dart';

// Native call UI (CallKit on iOS, full-screen notification on Android) —
// layered ON TOP of the existing Firestore-based signaling
// (CallListenerService/CallEngineService), not a replacement. Firestore
// remains the single source of truth for call state; this only mirrors
// that state into the OS's own call UI so an incoming call interrupts the
// user the way a real phone call does.
//
// TODO(pushkit): iOS only shows this while the app process is still alive
// (foreground or recently backgrounded) — there is no paid Apple Developer
// Program membership yet to issue a VoIP Services Certificate / APNs auth
// key, which PushKit (wake from fully-killed state) requires. Once
// available:
//   1. Generate a VoIP Services Certificate (or APNs auth key with the
//      VoIP push type) in the Apple Developer Portal.
//   2. In ios/Runner/AppDelegate.swift, register a PKPushRegistry (see
//      https://github.com/hiennguyen92/flutter_callkit_incoming/blob/master/PUSHKIT.md)
//      and forward the device token — via
//      FlutterCallkitIncoming.getDevicePushTokenVoIP() from Dart, or
//      directly via SwiftFlutterCallkitIncomingPlugin.sharedInstance?
//      .setDevicePushTokenVoIP in pushRegistry(_:didUpdate:for:) — into a
//      new users/{uid}/voipPushTokens/{deviceId} Firestore collection
//      (parallel to the existing pushTokens/ used for FCM).
//   3. Add a Cloud Function sending a VoIP push (APNs HTTP/2,
//      apns-push-type: voip, topic "<bundle-id>.voip" — NOT FCM, VoIP
//      pushes bypass FCM entirely) to the callee's voipPushTokens when
//      startCall creates a new calls/ doc.
//   4. In AppDelegate.swift's
//      pushRegistry(_:didReceiveIncomingPushWith:for:completion:), call
//      SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(
//      ..., fromPushKit: true) directly from native code — THIS is what
//      actually wakes a killed app; the Dart-side showIncoming() below
//      only runs if the Flutter engine is already alive.
class CallKitService {
  CallKitService._();
  static final CallKitService instance = CallKitService._();

  bool _listening = false;

  void ensureListening(FirestoreService firestoreService) {
    if (_listening) return;
    _listening = true;
    // No stop()/dispose() exists for this app-level singleton (deliberately
    // — see the class doc comment), so there's nothing that would ever
    // cancel this subscription; not worth holding a StreamSubscription
    // field just to never use it.
    FlutterCallkitIncoming.onEvent.listen((event) async {
      if (event == null) return;
      // CallEvent is a sealed class (flutter_callkit_incoming 3.x) — each
      // variant carries either its own CallKitParams (accept/decline/
      // start/incoming/ended) or a bare String id (timeout/connected/
      // callback). There is no shared event.body['id'] like the old v2
      // Map-based API this was originally drafted against.
      switch (event) {
        case CallEventActionCallAccept(:final callKitParams):
          final callId = callKitParams.id;
          try {
            await firestoreService.respondToCall(callId: callId, accept: true);
          } catch (_) {}
          // push, not go/pushReplacement — there is no /call/incoming
          // screen in the stack to replace anymore (see main.dart), so
          // this just adds the active-call screen on top of wherever the
          // user currently is, matching how a real incoming call
          // interrupts whatever you were doing without discarding it.
          appRouter.push('/call/active/$callId');
        case CallEventActionCallDecline(:final callKitParams):
          try {
            await firestoreService.respondToCall(callId: callKitParams.id, accept: false);
          } catch (_) {}
        case CallEventActionCallTimeout(:final id):
          try {
            await firestoreService.endCall(callId: id);
          } catch (_) {}
        default:
          break;
      }
    });
  }

  Future<void> showIncoming({
    required String callId,
    required String callerName,
    required bool isVideo,
  }) async {
    await FlutterCallkitIncoming.showCallkitIncoming(
      CallKitParams(
        id: callId,
        nameCaller: callerName,
        appName: 'Mugam',
        type: isVideo ? 1 : 0,
        duration: 30000,
        android: const AndroidParams(
          isCustomNotification: true,
          isShowLogo: false,
          ringtonePath: 'system_ringtone_default',
          backgroundColor: '#0C0A06',
          actionColor: '#D4A03C',
          textAccept: 'Qəbul et',
          textDecline: 'Rədd et',
        ),
        ios: const IOSParams(
          handleType: 'generic',
          supportsVideo: true,
          ringtonePath: 'system_ringtone_default',
        ),
      ),
    );
  }

  Future<void> reportOutgoingStarted({
    required String callId,
    required String calleeName,
    required bool isVideo,
  }) async {
    await FlutterCallkitIncoming.startCall(
      CallKitParams(
        id: callId,
        nameCaller: calleeName,
        appName: 'Mugam',
        type: isVideo ? 1 : 0,
        ios: const IOSParams(handleType: 'generic'),
        android: const AndroidParams(isCustomNotification: true),
      ),
    );
  }

  Future<void> reportConnected(String callId) async {
    await FlutterCallkitIncoming.setCallConnected(callId);
  }

  Future<void> endCall(String callId) async {
    await FlutterCallkitIncoming.endCall(callId);
  }
}
