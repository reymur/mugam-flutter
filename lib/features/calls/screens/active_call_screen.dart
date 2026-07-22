import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/calls/call_engine_service.dart';
import '../../../core/calls/callkit_service.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../widgets/call_action_button.dart';
import '../widgets/call_avatar_panel.dart';
import '../widgets/call_top_bar.dart';

class ActiveCallScreen extends ConsumerStatefulWidget {
  final String callId;
  const ActiveCallScreen({super.key, required this.callId});

  @override
  ConsumerState<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends ConsumerState<ActiveCallScreen> {
  bool _ending = false;
  bool _leftLocally = false;
  bool _started = false;

  Future<void> _ensureStarted(CallType type) async {
    if (_started) return;
    _started = true;
    // No-op if OutgoingCallScreen already started (and possibly finished
    // joining) this exact call — this is the callee's very first join
    // (reached only after they tapped accept) whenever it isn't.
    await CallEngineService.instance.start(
      firestoreService: ref.read(firestoreServiceProvider),
      callId: widget.callId,
      isVideo: type == CallType.video,
    );
    // Starts the native call UI's connected-state timer. Called here
    // (once our own engine join completes) rather than waiting for the
    // remote party's media to actually arrive — an approximation, but a
    // reasonable one: by this point the call is genuinely connected on
    // our end, which is what setCallConnected's own docs call for
    // ("when WebRTC/P2P is established").
    await CallKitService.instance.reportConnected(widget.callId);
  }

  void _leave() {
    if (!mounted || _leftLocally) return;
    _leftLocally = true;
    debugPrint('[CALL_NAV] _leave called, canPop=${context.canPop()}');
    if (context.canPop()) {
      debugPrint('[CALL_NAV] calling context.pop()');
      context.pop();
    } else {
      debugPrint('[CALL_NAV] calling context.go("/home") — canPop was false');
      context.go('/home');
    }
  }

  Future<void> _endCall() async {
    if (_ending) return;
    setState(() => _ending = true);
    try {
      await ref.read(firestoreServiceProvider).endCall(callId: widget.callId);
    } catch (_) {
      // Best-effort — leave regardless; dispose() releases the engine either way.
    }
    _leave();
  }

  static void _showStub(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Bu funksiya tezliklə əlavə olunacaq'),
        backgroundColor: kBg3,
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    unawaited(CallEngineService.instance.end());
    unawaited(CallKitService.instance.endCall(widget.callId));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    ref.listen(callProvider(widget.callId), (previous, next) {
      if (next.hasError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${next.error}'), backgroundColor: kRed),
        );
        return;
      }
      if (!next.hasValue) return;
      final call = next.value;
      if (call == null || call.status == CallStatus.ended || call.status == CallStatus.declined) {
        _leave();
      }
    });

    final callAsync = ref.watch(callProvider(widget.callId));
    final call = callAsync.asData?.value;
    if (call != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStarted(call.type));
    }

    final otherUid = call?.otherUid(currentUid);
    final otherAsync = otherUid != null ? ref.watch(userByIdProvider(otherUid)) : null;
    final other = otherAsync?.asData?.value;

    return ListenableBuilder(
      listenable: CallEngineService.instance,
      builder: (context, _) {
        final svc = CallEngineService.instance;

        if (svc.state == CallEngineState.connecting || svc.state == CallEngineState.idle) {
          return Scaffold(
            backgroundColor: kBg,
            body: const Center(child: CircularProgressIndicator(color: kGold)),
          );
        }

        if (svc.state == CallEngineState.error) {
          return Scaffold(
            backgroundColor: kBg,
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(svc.error ?? 'Xəta baş verdi', textAlign: TextAlign.center, style: const TextStyle(color: kText)),
                      const SizedBox(height: 16),
                      if (svc.permissionPermanentlyDenied)
                        TextButton(
                          onPressed: openAppSettings,
                          child: const Text('Ayarları aç', style: TextStyle(color: kGold)),
                        ),
                      TextButton(
                        onPressed: _leave,
                        child: const Text('Bağla', style: TextStyle(color: kMuted)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        final engine = svc.engine;
        final isVideo = svc.isVideo;
        final showingRemoteVideo = isVideo && engine != null && svc.remoteUid != null;
        final subtitle = svc.remoteUid != null ? _formatDuration(svc.elapsed) : 'Qoşulur...';

        return Scaffold(
          backgroundColor: kBg,
          body: Stack(
            children: [
              if (showingRemoteVideo)
                Positioned.fill(
                  child: AgoraVideoView(
                    controller: VideoViewController.remote(
                      rtcEngine: engine,
                      canvas: VideoCanvas(uid: svc.remoteUid),
                      connection: RtcConnection(channelId: widget.callId),
                    ),
                  ),
                )
              else
                Align(
                  alignment: Alignment.bottomCenter,
                  // Clears the action-button row (~16 top/bottom padding +
                  // ~64 icon/label height each, see the Align(bottomCenter)
                  // below) plus its own SafeArea inset, so the avatar block
                  // sits just above the buttons instead of floating in the
                  // middle of a mostly-empty screen (voice calls have no
                  // video filling the rest of the Stack).
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 140 + MediaQuery.of(context).padding.bottom),
                    child: CallAvatarPanel(name: other?.name ?? 'İstifadəçi', emoji: other?.emoji, subtitle: subtitle),
                  ),
                ),

              CallTopBar(
                onMinimize: () => _showStub(context),
                onAddParticipant: () => _showStub(context),
                onChat: () => _showStub(context),
                titleContent: Column(
                  children: [
                    Text(
                      other?.name ?? 'İstifadəçi',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.nunito(fontSize: 18, color: kText, fontWeight: FontWeight.w600),
                    ),
                    if (showingRemoteVideo) ...[
                      const SizedBox(height: 2),
                      Text(subtitle, style: const TextStyle(color: kMuted, fontSize: 13)),
                    ],
                  ],
                ),
              ),

              if (isVideo && engine != null && svc.joined && !svc.cameraOff)
                Positioned(
                  right: 16,
                  bottom: 160,
                  child: Stack(
                    children: [
                      SizedBox(
                        width: 110,
                        height: 150,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: AgoraVideoView(
                            controller: VideoViewController(
                              rtcEngine: engine,
                              canvas: const VideoCanvas(uid: 0),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Column(
                          children: [
                            _MiniIconButton(icon: Icons.cameraswitch, onPressed: svc.switchCamera),
                            const SizedBox(height: 6),
                            _MiniIconButton(
                              icon: svc.lowLightOn ? Icons.wb_sunny : Icons.nightlight_round,
                              onPressed: svc.toggleLowLight,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16, top: 16),
                    child: isVideo
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              CallActionButton(color: kBg3, icon: Icons.more_horiz, onPressed: () => _showStub(context)),
                              CallActionButton(
                                color: svc.cameraOff ? kBg3 : Colors.white,
                                icon: svc.cameraOff ? Icons.videocam_off : Icons.videocam,
                                onPressed: svc.toggleCamera,
                              ),
                              CallActionButton(
                                color: svc.speakerOn ? Colors.white : kBg3,
                                icon: Icons.volume_up,
                                onPressed: svc.toggleSpeaker,
                              ),
                              CallActionButton(
                                color: kBg3,
                                icon: svc.micMuted ? Icons.mic_off : Icons.mic,
                                onPressed: svc.toggleMic,
                              ),
                              CallActionButton(color: kRed, icon: Icons.call_end, onPressed: _ending ? null : _endCall),
                            ],
                          )
                        // mainAxisSize: min is load-bearing here — without
                        // it a Column defaults to MainAxisSize.max, filling
                        // the entire loose vertical space SafeArea/Align
                        // give it, and with no mainAxisAlignment set
                        // (defaults to start) its two button rows then sit
                        // at the TOP of that expanded space — visually
                        // indistinguishable from this whole block rendering
                        // at the top of the screen instead of the bottom,
                        // even though the outer Align(bottomCenter) was
                        // correctly positioning the (wrongly-sized) Column
                        // all along. Confirmed live (2026-07-21) with a
                        // magenta debug background filling the full screen.
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  _LabeledCallButton(
                                    icon: Icons.videocam,
                                    label: 'Video',
                                    onPressed: () => _showStub(context),
                                  ),
                                  _LabeledCallButton(
                                    icon: svc.speakerOn ? Icons.volume_up : Icons.volume_off,
                                    label: 'Dinamik',
                                    active: svc.speakerOn,
                                    onPressed: svc.toggleSpeaker,
                                  ),
                                  _LabeledCallButton(
                                    icon: svc.micMuted ? Icons.mic_off : Icons.mic,
                                    label: 'Səssiz',
                                    muted: svc.micMuted,
                                    onPressed: svc.toggleMic,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  _LabeledCallButton(icon: Icons.more_horiz, label: 'Daha', onPressed: () => _showStub(context)),
                                  _LabeledCallButton(
                                    icon: Icons.screen_share_outlined,
                                    label: 'Paylaş',
                                    onPressed: () => _showStub(context),
                                  ),
                                  _LabeledCallButton(
                                    icon: Icons.call_end,
                                    label: 'Bitir',
                                    isEnd: true,
                                    onPressed: _ending ? null : _endCall,
                                  ),
                                ],
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MiniIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  const _MiniIconButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kBg2.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(width: 30, height: 30, child: Icon(icon, color: kText, size: 18.4)),
      ),
    );
  }
}

class _LabeledCallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool muted;
  final bool isEnd;
  final VoidCallback? onPressed;

  const _LabeledCallButton({
    required this.icon,
    required this.label,
    this.active = false,
    this.muted = false,
    this.isEnd = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isEnd ? kRed : (active ? Colors.white : kBg3);
    final iconColor = isEnd ? Colors.white : (active ? kBg : (muted ? kMuted : kText));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(width: 56, height: 56, child: Icon(icon, color: iconColor, size: 35.9)),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
      ],
    );
  }
}
