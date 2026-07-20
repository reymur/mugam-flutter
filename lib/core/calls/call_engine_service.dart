import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../firebase/firestore_service.dart';

enum CallEngineState { idle, connecting, joined, error }

// App-level singleton (same pattern as PresenceService/CallListenerService)
// — deliberately NOT tied to any single screen's lifecycle. This is what
// lets the caller join the Agora channel the moment they place a call
// (OutgoingCallScreen.initState), and lets ActiveCallScreen later reuse
// that exact same running engine instead of creating a second one when
// the callee accepts — mirrors how WhatsApp's own outgoing-call screen
// already has a live mic/camera before the other side even answers.
class CallEngineService extends ChangeNotifier {
  CallEngineService._();
  static final CallEngineService instance = CallEngineService._();

  RtcEngine? _engine;
  RtcEngine? get engine => _engine;

  String? _activeCallId;
  String? get activeCallId => _activeCallId;

  bool _isVideo = false;
  bool get isVideo => _isVideo;

  CallEngineState _state = CallEngineState.idle;
  CallEngineState get state => _state;

  String? _error;
  String? get error => _error;

  bool _permissionPermanentlyDenied = false;
  bool get permissionPermanentlyDenied => _permissionPermanentlyDenied;

  bool _joined = false;
  bool get joined => _joined;

  int? _remoteUid;
  int? get remoteUid => _remoteUid;

  DateTime? _remoteJoinedAt;
  Timer? _tickTimer;

  // Elapsed time since the OTHER party actually joined — not since our own
  // local join, which (now that the caller can pre-join while still
  // ringing) would otherwise make the displayed call duration start too
  // early / be inaccurate.
  Duration get elapsed =>
      _remoteJoinedAt == null ? Duration.zero : DateTime.now().difference(_remoteJoinedAt!);

  bool _micMuted = false;
  bool get micMuted => _micMuted;

  bool _cameraOff = false;
  bool get cameraOff => _cameraOff;

  bool _speakerOn = false;
  bool get speakerOn => _speakerOn;

  bool _lowLightOn = false;
  bool get lowLightOn => _lowLightOn;

  Future<void>? _startFuture;

  Future<void> start({
    required FirestoreService firestoreService,
    required String callId,
    required bool isVideo,
  }) {
    if (_activeCallId == callId &&
        (_state == CallEngineState.joined || _state == CallEngineState.connecting)) {
      // Already starting/started for this exact call (e.g. ActiveCallScreen
      // calling start() right after OutgoingCallScreen already did) — reuse
      // the in-flight/completed attempt instead of joining a second time.
      return _startFuture ?? Future.value();
    }
    if (_activeCallId != null &&
        _activeCallId != callId &&
        (_state == CallEngineState.joined || _state == CallEngineState.connecting)) {
      // A different call is already connecting/active on this singleton —
      // last-line defense against two calls/{callId} docs racing to join
      // on the same engine (e.g. a double-tap on the call button before
      // the UI-level guard existed). Screens are expected to guard against
      // this themselves (see chat_screen.dart's _startingCall); this just
      // makes the service itself safe regardless of caller discipline.
      return Future.value();
    }
    _startFuture = _start(firestoreService: firestoreService, callId: callId, isVideo: isVideo);
    return _startFuture!;
  }

  Future<void> _start({
    required FirestoreService firestoreService,
    required String callId,
    required bool isVideo,
  }) async {
    _activeCallId = callId;
    _isVideo = isVideo;
    // Default to speaker regardless of call type, not just for video —
    // this runs before the callee has answered, while the ringback tone
    // is playing (see OutgoingCallScreen). At that point the user isn't
    // holding the phone to their ear yet, they're looking at the screen
    // waiting, so a quiet earpiece-routed ringback is wrong regardless of
    // whether this ends up being a voice or video call. The speaker
    // toggle button remains fully manual/available the whole time either
    // way — this only changes the STARTING default, confirmed live: a
    // voice call defaulted to earpiece and the ringback was inaudible
    // unless the user manually tapped speaker first.
    _speakerOn = true;
    _state = CallEngineState.connecting;
    _error = null;
    _permissionPermanentlyDenied = false;
    notifyListeners();

    try {
      final statuses = await [
        Permission.microphone,
        if (isVideo) Permission.camera,
      ].request();
      final micGranted = statuses[Permission.microphone]?.isGranted ?? false;
      if (!micGranted) {
        _error = 'Mikrofona giriş icazəsi lazımdır.';
        _permissionPermanentlyDenied = statuses[Permission.microphone]?.isPermanentlyDenied ?? false;
        _state = CallEngineState.error;
        notifyListeners();
        return;
      }

      final tokenData = await firestoreService.generateAgoraToken(channelName: callId);
      final appId = tokenData['appId'] as String;
      final token = tokenData['token'] as String;
      final uid = tokenData['uid'] as String;

      final engine = createAgoraRtcEngine();
      _engine = engine;
      await engine.initialize(RtcEngineContext(
        appId: appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));

      engine.registerEventHandler(RtcEngineEventHandler(
        onJoinChannelSuccess: (connection, elapsed) {
          _joined = true;
          notifyListeners();
        },
        onUserJoined: (connection, remoteUid, elapsed) {
          _remoteUid = remoteUid;
          _remoteJoinedAt ??= DateTime.now();
          _tickTimer ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
          notifyListeners();
        },
        onUserOffline: (connection, remoteUid, reason) {
          _remoteUid = null;
          notifyListeners();
        },
        onError: (err, msg) {
          // Surfaced via _error/CallEngineState.error only for failures
          // that happen during the initial join (caught below via the
          // outer try/catch — joinChannelWithUserAccount itself throws on
          // fatal errors like an invalid token). Errors after a successful
          // join (e.g. transient reconnect-related ones) are expected —
          // onConnectionStateChanged already reflects those via _joined/
          // _remoteUid, so no separate handling is needed here.
        },
        onConnectionStateChanged: (connection, state, reason) {},
      ));

      await engine.enableAudio();
      if (isVideo) {
        await engine.enableVideo();
        await engine.startPreview();
      }
      // setEnableSpeakerphone requires an active channel — calling it here
      // (before joinChannelWithUserAccount below) throws errNotReady (-3).
      // setDefaultAudioRouteToSpeakerphone is the SDK's own documented
      // pre-join counterpart: it sets the default route to use once the
      // channel is actually joined. Runtime toggling after join still uses
      // setEnableSpeakerphone (see toggleSpeaker() below), matching the
      // SDK docs exactly.
      debugPrint('[CALL_AUDIO] calling setDefaultAudioRouteToSpeakerphone($_speakerOn), BEFORE join');
      await engine.setDefaultAudioRouteToSpeakerphone(_speakerOn);
      debugPrint('[CALL_AUDIO] setDefaultAudioRouteToSpeakerphone($_speakerOn) returned OK');

      await engine.joinChannelWithUserAccount(
        token: token,
        channelId: callId,
        userAccount: uid,
        options: ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          publishMicrophoneTrack: !_micMuted,
          publishCameraTrack: isVideo && !_cameraOff,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
        ),
      );

      _state = CallEngineState.joined;
      notifyListeners();
    } catch (e) {
      _error = '$e';
      _state = CallEngineState.error;
      notifyListeners();
    }
  }

  // Each toggle only flips the exposed state AFTER the engine call actually
  // succeeds — not before. Calling these while the channel is mid-reconnect
  // (state=connectionStateReconnecting) can throw errNotReady; if the local
  // flag flipped unconditionally first, the button would visually show the
  // new state while the engine silently kept the old one — a real UI/engine
  // desync observed live during testing (a reconnect blip mid-tap).
  Future<void> toggleMic() async {
    final next = !_micMuted;
    try {
      await _engine?.muteLocalAudioStream(next);
      _micMuted = next;
    } catch (_) {
      // Engine call failed — leave _micMuted as it was; nothing actually
      // changed on the wire, so the UI shouldn't claim otherwise.
    }
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final next = !_cameraOff;
    try {
      await _engine?.muteLocalVideoStream(next);
      _cameraOff = next;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    final next = !_speakerOn;
    debugPrint('[CALL_AUDIO] toggleSpeaker: calling setEnableSpeakerphone($next), engine null=${_engine == null}');
    try {
      await _engine?.setEnableSpeakerphone(next);
      debugPrint('[CALL_AUDIO] setEnableSpeakerphone($next) returned OK');
      _speakerOn = next;
    } catch (e) {
      debugPrint('[CALL_AUDIO] setEnableSpeakerphone EXCEPTION: $e');
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    await _engine?.switchCamera();
  }

  Future<void> toggleLowLight() async {
    final next = !_lowLightOn;
    try {
      await _engine?.setLowlightEnhanceOptions(
        enabled: next,
        options: const LowlightEnhanceOptions(
          mode: LowLightEnhanceMode.lowLightEnhanceManual,
          level: LowLightEnhanceLevel.lowLightEnhanceLevelHighQuality,
        ),
      );
      _lowLightOn = next;
    } catch (_) {
      // Fail silently — non-critical toggle.
    }
    notifyListeners();
  }

  Future<void> end() async {
    final engine = _engine;
    _tickTimer?.cancel();
    _tickTimer = null;
    _engine = null;
    _activeCallId = null;
    _state = CallEngineState.idle;
    _error = null;
    _permissionPermanentlyDenied = false;
    _joined = false;
    _remoteUid = null;
    _remoteJoinedAt = null;
    _micMuted = false;
    _cameraOff = false;
    _speakerOn = false;
    _lowLightOn = false;
    _startFuture = null;
    notifyListeners();
    if (engine == null) return;
    try {
      await engine.leaveChannel();
    } catch (_) {}
    try {
      await engine.release();
    } catch (_) {}
  }
}
