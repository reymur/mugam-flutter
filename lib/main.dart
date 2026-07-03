import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/colors.dart';
import 'core/theme/typography.dart';
import 'firebase/push_notification_service.dart';
import 'firebase_options.dart';
import 'navigation/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const ProviderScope(child: MugamApp()));
}

class MugamApp extends StatefulWidget {
  const MugamApp({super.key});

  @override
  State<MugamApp> createState() => _MugamAppState();
}

class _MugamAppState extends State<MugamApp> {
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        PushNotificationService.instance.registerToken(user.uid);
      }
    });
    PushNotificationService.instance.setupForegroundPresentation();
    PushNotificationService.instance.setupMessageOpenedHandler((data) {
      final chatId = data['chatId'];
      if (data['type'] == 'new_message' && chatId != null) {
        appRouter.push('/chat/$chatId');
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Mugam',
      debugShowCheckedModeBanner: false,
      routerConfig: appRouter,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: kGold,
          secondary: kGold,
          surface: kBg2,
          onPrimary: kBg,
          onSurface: kText,
        ),
        scaffoldBackgroundColor: kBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg2,
          foregroundColor: kText,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        textTheme: buildTextTheme(),
        dividerColor: kBorder,
        cardColor: kCard,
      ),
    );
  }
}
