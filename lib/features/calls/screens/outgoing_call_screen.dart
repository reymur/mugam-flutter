import 'dart:async';
import 'package:flutter/material.dart';
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

  @override
  void dispose() {
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
    setState(() => _cancelling = true);
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
          if (!_navigatedToActive) {
            _navigatedToActive = true;
            context.pushReplacement('/call/active/${widget.callId}');
          }
        case CallStatus.declined:
        case CallStatus.ended:
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
                      style: GoogleFonts.playfairDisplay(fontSize: 18, color: kText, fontWeight: FontWeight.w600),
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
