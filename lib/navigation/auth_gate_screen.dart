import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/colors.dart';

// Cold-start routing must not read FirebaseAuth.instance.currentUser
// synchronously: Auth restores a persisted session (Keychain on iOS) off
// the main isolate, so currentUser can still read null for a brief window
// even when a valid session exists — reading it too early would silently
// bounce an already-logged-in user to LoginScreen. Waiting for the first
// authStateChanges() emission is the actual signal that restoration has
// completed, either way.
class AuthGateScreen extends StatefulWidget {
  const AuthGateScreen({super.key});

  @override
  State<AuthGateScreen> createState() => _AuthGateScreenState();
}

class _AuthGateScreenState extends State<AuthGateScreen> {
  StreamSubscription<User?>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = FirebaseAuth.instance.authStateChanges().listen((user) {
      _sub?.cancel();
      if (!mounted) return;
      context.go(user != null ? '/home' : '/login');
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
