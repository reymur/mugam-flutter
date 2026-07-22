import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
// The main library file doesn't re-export its own entities (CallEvent,
// CallKitParams, AndroidParams, IOSParams, ...) — this barrel is required
// separately, or those names don't resolve at all.
import 'package:flutter_callkit_incoming/entities/entities.dart';
import '../../firebase/firestore_service.dart';
import '../../firebase/models.dart' show CallStatus;
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

  // Firestore call id -> CallKit/ConnectionService id (a real UUID,
  // generated once server-side by startCall — see Call.callkitUuid's own
  // comment on why it can't just be the Firestore id). Needed because
  // reportConnected/endCall below only get handed the Firestore id (that's
  // what every screen already threads through its widgets) but the plugin's
  // setCallConnected/endCall calls need the CallKit-side id instead.
  //
  // This map is per-process, so it does NOT survive the short-lived
  // background isolate _firebaseMessagingBackgroundHandler (main.dart) runs
  // in — showIncoming() called from there populates a copy that's gone by
  // the time the user later taps Accept/Decline in the real (relaunched)
  // main isolate. That's why the onEvent handler below resolves accept/
  // decline through callKitParams.extra instead (which the native plugin
  // itself persists and hands back, regardless of process/isolate) rather
  // than through this map. CallEventActionCallTimeout has no callKitParams/
  // extra to read (see call_event.dart) so it has no cross-isolate-safe
  // path — it falls back to this map, same-isolate-only, best-effort,
  // matching the existing catch(_){} swallow below.
  final Map<String, String> _callkitIdByCallId = {};

  // Guards CallEventActionCallAccept below against firing its body more
  // than once for the same call — confirmed live (2026-07-21) that the
  // native plugin can redeliver this event repeatedly in a tight loop
  // (roughly every 1-3s) for a single actual accept tap, each redelivery
  // otherwise re-running respondToCall() and, critically, appRouter.push(),
  // which stacked a brand new ActiveCallScreen (fresh _started=false) on
  // every firing — visible on-device as the call screen rapidly flickering
  // and the app switcher showing duplicate call screens. Firestore's own
  // respondToCall write is idempotent so re-running it isn't itself
  // harmful; the repeated push() was the actual damage.
  final Set<String> _acceptedCallIds = {};

  // Populated by reportOutgoingStarted, checked by the
  // CallEventActionCallAccept handler below. Confirmed live (2026-07-21):
  // on the CALLER's own device, once the callee answers, CallKit delivers
  // a CallEventActionCallAccept to the caller's side too (not just the
  // callee's) — presumably how the plugin reflects the outgoing call
  // transitioning to connected. OutgoingCallScreen already has its own
  // Firestore-status listener that handles this transition (pushReplacement
  // to /call/active once status flips to accepted); without this guard,
  // the accept handler ALSO ran its incoming-call logic (respondToCall as
  // if WE were accepting, appRouter.push a second, redundant
  // ActiveCallScreen) purely in reaction to our own outgoing call being
  // answered — a second, independent duplicate-screen source from the one
  // _acceptedCallIds guards against.
  final Set<String> _outgoingCallIds = {};

  // Started alongside every showIncoming/reportOutgoingStarted call (see
  // those methods) — owned by this singleton, not by whichever screen
  // widget happens to be showing the call, specifically so ending the
  // native CallKit session doesn't depend on that widget's build/dispose
  // lifecycle actually running promptly. Cancelled once the call is
  // confirmed ended (from here or from endCall() being called some other
  // way) so it doesn't keep firing after the fact.
  final Map<String, StreamSubscription<void>> _endWatchers = {};

  String? _callIdForCallkitId(String callkitId) {
    for (final entry in _callkitIdByCallId.entries) {
      if (entry.value == callkitId) return entry.key;
    }
    return null;
  }

  void _watchForRemoteEnd(String callId, FirestoreService firestoreService) {
    _endWatchers[callId]?.cancel();
    _endWatchers[callId] = firestoreService.watchCall(callId).listen((call) {
      if (call == null || call.status == CallStatus.ended || call.status == CallStatus.declined) {
        endCall(callId);
      }
    });
  }

  void ensureListening(FirestoreService firestoreService) {
    debugPrint('[CALLKIT] ensureListening called, _listening=$_listening');
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
          final callId = callKitParams.extra?['firestoreCallId'] as String?;
          debugPrint('[CALLKIT] CallEventActionCallAccept fired for callId=$callId, already in _acceptedCallIds=${callId != null && _acceptedCallIds.contains(callId)}, isOutgoing=${callId != null && _outgoingCallIds.contains(callId)}');
          if (callId == null) break;
          // See _outgoingCallIds' own comment — this is the caller-side
          // fix. OutgoingCallScreen's own status listener already handles
          // navigating to ActiveCallScreen once the callee answers; this
          // event firing here too (on the CALLER's device) is just
          // CallKit's own echo of that, not a genuine incoming-call accept
          // for us to act on.
          if (_outgoingCallIds.contains(callId)) break;
          // See _acceptedCallIds' own comment — this is the fix for the
          // redelivery loop. Cleared in endCall() once the call is
          // actually over, so a later, genuinely new call with the same
          // Firestore id (can't happen — ids are unique — but matters if
          // this set is ever repurposed) wouldn't be blocked forever.
          if (_acceptedCallIds.contains(callId)) break;
          _acceptedCallIds.add(callId);
          // Deliberately NOT removed from _callkitIdByCallId here — this
          // map is what translates callId -> callkitId for every call INTO
          // the plugin (reportConnected, endCall), and both of those still
          // need to happen after accept, not before it. An earlier version
          // of this method removed it here, which meant endCall() below
          // silently no-op'd (its own `if (callkitId == null) return`
          // guard) for every single call that had gone through accept —
          // this was confirmed live (2026-07-21): setCallConnected never
          // fired even once across the whole test session, and is almost
          // certainly the real cause of the "orphaned CallKit session"
          // pattern also documented on endCall() below, not Firestore
          // listener throttling as originally guessed there.
          try {
            await firestoreService.respondToCall(callId: callId, accept: true);
          } catch (_) {}
          // push, not go/pushReplacement — there is no /call/incoming
          // screen in the stack to replace anymore (see main.dart), so
          // this just adds the active-call screen on top of wherever the
          // user currently is, matching how a real incoming call
          // interrupts whatever you were doing without discarding it.
          debugPrint('[CALLKIT] calling appRouter.push(/call/active/$callId) now');
          appRouter.push('/call/active/$callId');
          debugPrint('[CALLKIT] appRouter.push(/call/active/$callId) returned');
        case CallEventActionCallDecline(:final callKitParams):
          final callId = callKitParams.extra?['firestoreCallId'] as String?;
          if (callId == null) break;
          try {
            await firestoreService.respondToCall(callId: callId, accept: false);
          } catch (_) {}
          // Declining ends the call from CallKit's own perspective already
          // (no separate endCall() needed) — just drop our bookkeeping for
          // it so the map doesn't grow unboundedly.
          _callkitIdByCallId.remove(callId);
          _endWatchers.remove(callId)?.cancel();
        case CallEventActionCallTimeout(:final id):
          final callId = _callIdForCallkitId(id);
          if (callId == null) break;
          try {
            await firestoreService.endCall(callId: callId);
          } catch (_) {}
          _callkitIdByCallId.remove(callId);
          _endWatchers.remove(callId)?.cancel();
        case CallEventActionCallEnded(:final callKitParams):
          // Fires for ANY call end CallKit knows about — including ones WE
          // triggered via endCall() below (telling the plugin to end a call
          // reports this same event back to us; harmless to re-run
          // firestoreService.endCall() in that case, it's a no-op write on
          // an already-"ended" doc). The case that actually matters here is
          // the one nothing else covers: the user ending the call from
          // CallKit's OWN native in-call screen (the system "Отбой" button,
          // reachable via the status-bar call pill) — that's a
          // CXEndCallAction the OS performs directly against the provider,
          // entirely outside our Dart code, so without this case Firestore
          // (and the other party) would never learn the call ended.
          final callId = callKitParams.extra?['firestoreCallId'] as String?;
          if (callId == null) break;
          try {
            await firestoreService.endCall(callId: callId);
          } catch (_) {}
          _callkitIdByCallId.remove(callId);
          _endWatchers.remove(callId)?.cancel();
        default:
          break;
      }
    });
  }

  Future<void> showIncoming({
    required String callId,
    required String callkitId,
    required String callerName,
    required bool isVideo,
  }) async {
    _callkitIdByCallId[callId] = callkitId;
    // Covers the whole lifecycle from here on — a caller cancelling before
    // we accept (so the native ringing UI doesn't sit there for the full
    // 30s duration/timeout) as well as the call ending after we accept it.
    _watchForRemoteEnd(callId, FirestoreService());
    // try/catch kept from the original diagnostic pass: the root cause
    // (callId wasn't a valid UUID, see Call.callkitUuid's comment) turned
    // out to be a silent native no-op that this can't actually catch — the
    // method channel's handle() dispatcher returns success regardless of
    // whether CXProvider's guard inside passed. Left in place since it's
    // free and still useful for genuine plugin-channel failures.
    try {
      debugPrint('[CALLKIT] showIncoming: calling showCallkitIncoming for callId=$callId callkitId=$callkitId isVideo=$isVideo');
      await FlutterCallkitIncoming.showCallkitIncoming(
        CallKitParams(
          id: callkitId,
          nameCaller: callerName,
          appName: 'Mugam',
          type: isVideo ? 1 : 0,
          duration: 30000,
          extra: {'firestoreCallId': callId},
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
      debugPrint('[CALLKIT] showIncoming: showCallkitIncoming returned OK for callId=$callId callkitId=$callkitId');
    } catch (e, st) {
      debugPrint('[CALLKIT] showIncoming EXCEPTION for callId=$callId callkitId=$callkitId: $e\n$st');
    }
  }

  Future<void> reportOutgoingStarted({
    required String callId,
    required String callkitId,
    required String calleeName,
    required bool isVideo,
  }) async {
    _callkitIdByCallId[callId] = callkitId;
    _outgoingCallIds.add(callId);
    _watchForRemoteEnd(callId, FirestoreService());
    await FlutterCallkitIncoming.startCall(
      CallKitParams(
        id: callkitId,
        nameCaller: calleeName,
        appName: 'Mugam',
        type: isVideo ? 1 : 0,
        extra: {'firestoreCallId': callId},
        ios: const IOSParams(handleType: 'generic'),
        android: const AndroidParams(isCustomNotification: true),
      ),
    );
  }

  Future<void> reportConnected(String callId) async {
    final callkitId = _callkitIdByCallId[callId];
    if (callkitId == null) {
      return;
    }
    await FlutterCallkitIncoming.setCallConnected(callkitId);
  }

  // FIXED (2026-07-21, see git history for the original TODO this
  // replaced): the "orphaned CallKit session" pattern from live testing —
  // the native call UI (lock screen / status-bar call pill) kept showing a
  // long-since-ended call, anywhere from ~14s to ~6 minutes after Firestore
  // said the call was over — was originally guessed to be Firestore
  // listener throttling while backgrounded. It wasn't: the real cause was
  // that CallEventActionCallAccept's handler above used to remove this
  // call's entry from _callkitIdByCallId immediately on accept, so by the
  // time anything called endCall() afterward, the `if (callkitId == null)
  // return` guard below had already turned it into a silent no-op — this
  // NEVER told the native side the call was over; every "eventual" native
  // end seen during testing was actually the user manually dismissing it.
  // Confirmed by setCallConnected (reportConnected() above) also never
  // firing even once across the whole test session, same root cause.
  // Two changes fixed this: the map entry is only removed here (or on
  // decline/timeout/ended, which don't need it afterward) instead of on
  // accept, and _watchForRemoteEnd (started from showIncoming/
  // reportOutgoingStarted) now calls this proactively from Firestore state
  // changes instead of relying solely on a screen widget's own
  // ref.listen/dispose lifecycle running.
  Future<void> endCall(String callId) async {
    _endWatchers.remove(callId)?.cancel();
    _acceptedCallIds.remove(callId);
    _outgoingCallIds.remove(callId);
    final callkitId = _callkitIdByCallId.remove(callId);
    if (callkitId == null) return;
    await FlutterCallkitIncoming.endCall(callkitId);
  }
}
