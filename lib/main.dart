import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'core/cache/message_cache_service.dart';
import 'core/queue/background_queue_processor.dart';
import 'core/queue/pending_message_queue_controller.dart';
import 'core/queue/pending_message_queue_service.dart';
import 'core/theme/colors.dart';
import 'core/theme/typography.dart';
import 'firebase/push_notification_service.dart';
import 'firebase_options.dart';
import 'navigation/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Ducks background audio (Spotify, etc.) while this app plays or records
  // voice/video message audio — video_player and camera's own iOS audio
  // session setup both merge into (rather than overwrite) whatever's
  // already configured, so this one call covers voice/video playback and
  // video recording; voice recording's own session setup (record package)
  // overwrites its options outright, so that path sets duckOthers
  // explicitly too — see _startRecording in chat_screen.dart.
  final audioSession = await AudioSession.instance;
  await audioSession.configure(
    const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.duckOthers,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
      androidWillPauseWhenDucked: false,
    ),
  );
  final prefs = await SharedPreferences.getInstance();
  // Best-effort retry for the offline media-send queue while the app is
  // backgrounded (but not fully killed — see background_queue_processor.dart
  // for what's deliberately out of scope). registerPeriodicTask's frequency
  // only takes effect on Android; iOS's actual schedule comes from the
  // native registerPeriodicTask call in AppDelegate.swift.
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    'pendingQueueRetry',
    pendingQueueRetryTaskName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
  runApp(
    ProviderScope(
      overrides: [
        messageCacheServiceProvider.overrideWithValue(MessageCacheService(prefs)),
        pendingMessageQueueServiceProvider.overrideWithValue(
          PendingMessageQueueService(prefs),
        ),
      ],
      child: const MugamApp(),
    ),
  );
}

class MugamApp extends ConsumerStatefulWidget {
  const MugamApp({super.key});

  @override
  ConsumerState<MugamApp> createState() => _MugamAppState();
}

class _MugamAppState extends ConsumerState<MugamApp> {
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
    // Eagerly instantiate the offline media-send queue at startup (not
    // lazily on first chat screen open) so a queue hydrated from a previous
    // session resumes retrying immediately, app-wide.
    ref.read(pendingMessageQueueProvider);
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
