import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../widgets/call_action_button.dart';
import '../widgets/call_avatar_panel.dart';
import '../widgets/call_top_bar.dart';

class IncomingCallScreen extends ConsumerStatefulWidget {
  final String callId;
  const IncomingCallScreen({super.key, required this.callId});

  @override
  ConsumerState<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends ConsumerState<IncomingCallScreen> {
  bool _responding = false;

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$e'), backgroundColor: kRed),
    );
  }

  static void _showStub(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Bu funksiya tezliklə əlavə olunacaq'),
        backgroundColor: kBg3,
      ),
    );
  }

  void _leave() {
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  Future<void> _respond(bool accept) async {
    if (_responding) return;
    setState(() => _responding = true);
    try {
      await ref.read(firestoreServiceProvider).respondToCall(
        callId: widget.callId,
        accept: accept,
      );
      if (!mounted) return;
      if (accept) {
        context.go('/call/active/${widget.callId}');
      } else {
        _leave();
      }
    } catch (e) {
      if (mounted) setState(() => _responding = false);
      if (e is FirebaseFunctionsException) {
        _showError(e.message ?? e.code);
      } else {
        _showError(e);
      }
    }
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
      if (!_responding && (call == null || call.status != CallStatus.ringing)) {
        _leave();
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
          final callerAsync = ref.watch(userByIdProvider(call.callerId));
          final caller = callerAsync.asData?.value;
          final typeLabel = call.type == CallType.video ? 'Video zəng' : 'Səs zəngi';

          return Stack(
            children: [
              CallAvatarPanel(
                name: caller?.name ?? 'İstifadəçi',
                emoji: caller?.emoji,
                subtitle: '$typeLabel gəlir...',
              ),
              CallTopBar(
                onMinimize: () => _showStub(context),
                onAddParticipant: () => _showStub(context),
                onChat: () => _showStub(context),
                titleContent: Text(
                  caller?.name ?? 'İstifadəçi',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.playfairDisplay(fontSize: 18, color: kText, fontWeight: FontWeight.w600),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        CallActionButton(
                          color: kRed,
                          icon: Icons.call_end,
                          onPressed: _responding ? null : () => _respond(false),
                        ),
                        CallActionButton(
                          color: kGreen,
                          icon: Icons.call,
                          onPressed: _responding ? null : () => _respond(true),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
