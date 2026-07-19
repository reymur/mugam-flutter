import 'dart:async';
import 'dart:ui';

import 'package:audio_session/audio_session.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'core/cache/message_cache_service.dart';
import 'core/calls/call_listener_service.dart';
import 'core/presence/presence_service.dart';
import 'core/queue/background_queue_processor.dart';
import 'core/queue/pending_message_queue_controller.dart';
import 'core/queue/pending_message_queue_service.dart';
import 'core/settings/image_quality_settings.dart';
import 'core/theme/colors.dart';
import 'core/theme/typography.dart';
import 'firebase/push_notification_service.dart';
import 'firebase_options.dart';
import 'navigation/app_router.dart';

Future<void> main() async {
  // Everything (including runApp) runs inside this zone so errors that
  // escape Flutter's own error funnels — e.g. thrown from an un-awaited
  // Future, rather than during a frame/build FlutterError already catches,
  // or from a callback PlatformDispatcher.onError already catches — still
  // reach Crashlytics instead of vanishing into an unhandled zone error.
  runZonedGuarded<Future<void>>(() async {
    await _mainImpl();
  }, (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
  });
}

Future<void> _mainImpl() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Flutter-framework errors (failed builds, layout, etc.) go through
  // FlutterError.onError; everything else Dart-level (thrown in a callback,
  // a bad platform-channel response) goes through PlatformDispatcher.onError
  // — between the two of these and the runZonedGuarded wrapper above, no
  // unhandled error is invisible in production anymore (previously: only
  // debugPrint/print, meaningless without an attached debugger).
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };
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
        sharedPreferencesProvider.overrideWithValue(prefs),
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
        PresenceService.instance.start(user.uid);
        CallListenerService.instance.start(user.uid, (call) {
          appRouter.push('/call/incoming/${call.id}');
        });
      } else {
        PresenceService.instance.stop();
        CallListenerService.instance.stop();
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
    PresenceService.instance.stop();
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
