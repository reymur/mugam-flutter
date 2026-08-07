import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings/start_tab_settings.dart';
import '../core/theme/colors.dart';

// Cold-start routing must not read FirebaseAuth.instance.currentUser
// synchronously: Auth restores a persisted session (Keychain on iOS) off
// the main isolate, so currentUser can still read null for a brief window
// even when a valid session exists — reading it too early would silently
// bounce an already-logged-in user to LoginScreen. Waiting for the first
// authStateChanges() emission is the actual signal that restoration has
// completed, either way.
class AuthGateScreen extends ConsumerStatefulWidget {
  const AuthGateScreen({super.key});

  @override
  ConsumerState<AuthGateScreen> createState() => _AuthGateScreenState();
}

class _AuthGateScreenState extends ConsumerState<AuthGateScreen> {
  StreamSubscription<User?>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = FirebaseAuth.instance.authStateChanges().listen((user) {
      _sub?.cancel();
      if (!mounted) return;
      // Настройка «Tətbiq açılır…» применяется ЗДЕСЬ — это единственное
      // место, решающее, куда попадает человек после запуска. Разбор
      // сохранённого имени и откат при исчезнувшей вкладке — в
      // resolveStartPath (core/settings/start_tab_settings.dart).
      context.go(
        user != null ? resolveStartPath(ref.read(startTabProvider)) : '/login',
      );
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: kBg,
      body: Center(child: CircularProgressIndicator(color: kGold)),
    );
  }
}
