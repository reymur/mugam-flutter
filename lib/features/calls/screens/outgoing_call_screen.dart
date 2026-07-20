import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/calls/call_engine_service.dart';
import '../../../core/calls/callkit_service.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../widgets/call_action_button.dart';
import '../widgets/call_avatar_panel.dart';
import '../widgets/call_top_bar.dart';

class OutgoingCallScreen extends ConsumerStatefulWidget {
  final String callId;
  const OutgoingCallScreen({super.key, required this.callId});

  @override
  ConsumerState<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends ConsumerState<OutgoingCallScreen> {
  bool _cancelling = false;
  bool _navigatedToActive = false;
  bool _started = false;
  bool _leftLocally = false;
  // Neither CallKit (iOS) nor ConnectionService (Android) expose any
  // system-level "ringback tone" for OUTGOING calls — confirmed against
  // both platforms' own docs (CXProviderConfiguration.ringtoneSound only
  // customizes the INCOMING ringtone; Android's telecom.Connection has no
  // audio-playback API at all). Every VoIP app (WhatsApp, Telegram, Zoom
  // included) bundles and plays its own ringback locally for exactly this
  // reason — there's nothing to hear on the wire until the callee
  // actually answers.
  final AudioPlayer _ringbackPlayer = AudioPlayer();
  bool _ringbackStarted = false;
  // Firestore's call-status listener can briefly flicker between values
  // right at the transition moment (confirmed live via [RINGBACK] logs:
  // status bounced ringing<->other 4 times within ~1.6s right as a call
  // ended) — once we've legitimately left the ringing phase, never treat
  // a flicker back to "ringing" as a real reason to restart the ringback.
  bool _ringingPhaseEnded = false;

  @override
  void dispose() {
    _ringbackPlayer.dispose();
    if (!_navigatedToActive) {
      // Only tear the engine down if we're leaving WITHOUT handing off to
      // ActiveCallScreen for this same call (cancelled, declined, or ended
      // while still ringing) — if we ARE handing off, ActiveCallScreen
      // reuses this exact running engine and must not have it pulled out
      // from under it here.
      unawaited(CallEngineService.instance.end());
      // Same "only if NOT handing off to ActiveCallScreen" rule as the
      // engine above — if we ARE handing off, ActiveCallScreen's own
      // dispose() ends the CallKit session once, not this screen twice.
      unawaited(CallKitService.instance.endCall(widget.callId));
    }
    super.dispose();
  }

  Future<void> _startRingback() async {
    if (_ringingPhaseEnded || _ringbackStarted) return;
    _ringbackStarted = true;
    try {
      await _ringbackPlayer.setAsset('assets/sounds/phone-tone.wav');
      await _ringbackPlayer.setLoopMode(LoopMode.one);
      // Explicit max volume — belt-and-suspenders alongside the boosted
      // source file itself (peak -1.1dB), in case just_audio's own
      // default volume isn't already 1.0 in this context.
      await _ringbackPlayer.setVolume(1.0);
      await _ringbackPlayer.play();
    } catch (_) {}
  }

  Future<void> _stopRingback() async {
    if (!_ringbackStarted) return;
    _ringbackStarted = false;
    try {
      // A hard stop() mid-waveform can produce an audible click — ramp
      // volume down first (just_audio has no built-in fade-out) so
      // playback always ends at/near silence, not mid-cycle.
      const steps = 6;
      const stepDuration = Duration(milliseconds: 25);
      for (var i = steps - 1; i >= 0; i--) {
        await _ringbackPlayer.setVolume(i / steps);
        await Future.delayed(stepDuration);
      }
      await _ringbackPlayer.stop();
    } catch (_) {}
  }

  void _leave() {
    if (!mounted || _leftLocally) return;
    // Without this guard, cancelling before the callee answers calls
    // _leave() TWICE: once directly from _cancel() below, and again
    // asynchronously when this screen's own ref.listen reacts to the
    // resulting Firestore status write ("ended") — the first pop()
    // correctly removes this screen and reveals the originating chat,
    // but the second, unguarded pop() then removes the chat screen too,
    // landing on the chats list instead. Confirmed live: this only
    // happened on cancel-before-answer, never on a normal accepted call
    // (where this screen is torn down via pushReplacement before any
    // second _leave() could fire) — matches ActiveCallScreen's own
    // pre-existing _leftLocally guard, which this screen was missing.
    _leftLocally = true;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  static void _showStub(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Bu funksiya tezliklə əlavə olunacaq'),
        backgroundColor: kBg3,
      ),
    );
  }

  Future<void> _cancel() async {
    if (_cancelling || _navigatedToActive) return;
    // Symmetric with the CallStatus.declined/ended branch in the
    // ref.listen switch below — without this, setState() here triggers
    // an immediate rebuild while callProvider still momentarily reports
    // the OLD "ringing" status (Firestore's endCall write hasn't
    // propagated back yet), so build() calls _startRingback() again
    // right as the screen is closing — confirmed live via
    // [SCREEN_LIFECYCLE] logs: ringback briefly restarted (fade-in)
    // between _cancel() and DISPOSED, producing an audible click on
    // cancel that the earlier loop-seam fade fix didn't touch (different
    // bug, same symptom).
    _ringingPhaseEnded = true;
    setState(() => _cancelling = true);
    unawaited(_stopRingback());
    try {
      await ref.read(firestoreServiceProvider).endCall(callId: widget.callId);
    } catch (_) {
      // Best-effort — leave regardless; callProvider is the source of truth.
    }
    if (mounted) _leave();
  }

  Future<void> _ensureStarted(Call call) async {
    if (_started) return;
    _started = true;
    final isVideo = call.type == CallType.video;
    await CallEngineService.instance.start(
      firestoreService: ref.read(firestoreServiceProvider),
      callId: widget.callId,
      isVideo: isVideo,
    );
    // One-off fetch (not the reactive userByIdProvider stream) — this
    // fires once, at call-start, purely to label the native CallKit UI;
    // it doesn't need to stay live-updated the way on-screen UI does.
    final callee = await ref.read(firestoreServiceProvider).fetchUserById(call.calleeId);
    await CallKitService.instance.reportOutgoingStarted(
      callId: widget.callId,
      calleeName: callee?.name ?? 'İstifadəçi',
      isVideo: isVideo,
    );
  }

  @override
  Widget build(BuildContext context) {
    final callAsync = ref.watch(callProvider(widget.callId));

    ref.listen(callProvider(widget.callId), (previous, next) {
      if (next.hasError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${next.error}'), backgroundColor: kRed),
        );
        return;
      }
      if (!next.hasValue) return;
      final call = next.value;
      if (call == null) {
        if (!_navigatedToActive) _leave();
        return;
      }
      switch (call.status) {
        case CallStatus.accepted:
          _ringingPhaseEnded = true;
          unawaited(_stopRingback());
          if (!_navigatedToActive) {
            _navigatedToActive = true;
            context.pushReplacement('/call/active/${widget.callId}');
          }
        case CallStatus.declined:
        case CallStatus.ended:
          _ringingPhaseEnded = true;
          unawaited(_stopRingback());
          if (!_navigatedToActive) _leave();
        case CallStatus.ringing:
          break;
      }
    });

    return Scaffold(
      backgroundColor: kBg,
      body: callAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: kGold)),
        error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: kText))),
        data: (call) {
          if (call == null) {
            return const Center(child: CircularProgressIndicator(color: kGold));
          }
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStarted(call));
          if (call.status == CallStatus.ringing) {
            unawaited(_startRingback());
          }

          final calleeAsync = ref.watch(userByIdProvider(call.calleeId));
          final callee = calleeAsync.asData?.value;
          final typeLabel = call.type == CallType.video ? 'Video zəng' : 'Səs zəngi';
          final isVideo = call.type == CallType.video;

          return ListenableBuilder(
            listenable: CallEngineService.instance,
            builder: (context, _) {
              final svc = CallEngineService.instance;
              return Stack(
                children: [
                  CallAvatarPanel(
                    name: callee?.name ?? 'İstifadəçi',
                    emoji: callee?.emoji,
                    subtitle: svc.state == CallEngineState.error
                        ? (svc.error ?? 'Xəta baş verdi')
                        : '$typeLabel...',
                  ),
                  CallTopBar(
                    onMinimize: () => _showStub(context),
                    onAddParticipant: () => _showStub(context),
                    onChat: () => _showStub(context),
                    titleContent: Text(
                      callee?.name ?? 'İstifadəçi',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.nunito(fontSize: 18, color: kText, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24, top: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            CallActionButton(
                              color: kBg3,
                              icon: Icons.more_horiz,
                              onPressed: () => _showStub(context),
                            ),
                            if (isVideo)
                              CallActionButton(
                                color: svc.cameraOff ? kBg3 : Colors.white,
                                icon: svc.cameraOff ? Icons.videocam_off : Icons.videocam,
                                onPressed: svc.state == CallEngineState.joined ? svc.toggleCamera : null,
                              ),
                            CallActionButton(
                              color: svc.speakerOn ? Colors.white : kBg3,
                              icon: Icons.volume_up,
                              onPressed: svc.state == CallEngineState.joined ? svc.toggleSpeaker : null,
                            ),
                            CallActionButton(
                              color: kBg3,
                              icon: svc.micMuted ? Icons.mic_off : Icons.mic,
                              onPressed: svc.state == CallEngineState.joined ? svc.toggleMic : null,
                            ),
                            CallActionButton(
                              color: kRed,
                              icon: Icons.call_end,
                              onPressed: _cancelling ? null : _cancel,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
