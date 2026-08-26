import 'dart:async';
import 'dart:ui';

import 'package:audio_session/audio_session.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'core/calls/call_listener_service.dart';
import 'core/calls/callkit_service.dart';
import 'core/media/media_cache_cleanup.dart';
import 'core/presence/presence_service.dart';
import 'core/queue/background_queue_processor.dart';
import 'core/queue/message_send_controller.dart';
import 'core/queue/pending_file_storage.dart';
import 'core/settings/image_quality_settings.dart';
import 'core/store/local_message_store.dart';
import 'core/theme/colors.dart';
import 'core/theme/typography.dart';
import 'firebase/firestore_service.dart';
// `show CallType` only — models.dart also declares its own `User` class,
// which would otherwise collide with firebase_auth's `User` (already
// imported below and used unqualified for _authSub's type).
import 'firebase/models.dart' show CallType;
import 'core/push/push_route.dart';
import 'firebase/push_notification_service.dart';
import 'firebase_options.dart';
import 'navigation/app_router.dart';

// Runs in a separate background isolate when a data-only FCM message
// arrives while the app is backgrounded or fully killed (Android only —
// iOS still needs PushKit for this, see CallKitService's own TODO).
// @pragma('vm:entry-point') is required so the background isolate can
// find this top-level function at all (Flutter tree-shakes it out
// otherwise) — see flutter_callkit_incoming's own docs on this exact
// requirement.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (message.data['type'] != 'incoming_call') return;
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final callId = message.data['callId'];
  final callkitId = message.data['callkitUuid'];
  final callType = message.data['callType'];
  final callerName = message.data['callerName'];
  // callkitId, not just callId, must be present — it's the value startCall
  // generated server-side (see Call.callkitUuid's comment) specifically so
  // this background isolate doesn't have to do its own Firestore round-trip
  // (which would delay the native call UI) just to get a valid CallKit id.
  if (callId == null || callkitId == null) return;
  await CallKitService.instance.showIncoming(
    callId: callId,
    callkitId: callkitId,
    callerName: callerName ?? 'Zəng',
    isVideo: callType == 'video',
  );
}

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
  // Required before any DateFormat(..., 'az') call (chat_screen.dart's
  // job-offer banner, agreements_screen.dart's event dates) — intl throws
  // LocaleDataException otherwise, since 'az' locale data isn't bundled by
  // default the way 'en' is.
  await initializeDateFormatting('az');
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
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
  // Hydrates every pending send across every chat (see LocalMessageStore's
  // own doc comment) — must complete before MessageSendController is ever
  // read, so the retry loop it eagerly kicks off in _MugamAppState.initState
  // below actually has something to iterate.
  final localMessageStore = LocalMessageStore(prefs);
  await localMessageStore.init();
  // Разовая уборка накопленного до `6175ac1`: файлы, на которые не
  // ссылается ни одна запись очереди (N2). Строго ПОСЛЕ init() — он и
  // делает список ссылок полным, а неполный список здесь означал бы
  // удаление файла у живой отправки. Не ожидается: запуск приложения
  // не должен зависеть от обхода каталога.
  unawaited(
    deleteUnreferencedPendingFiles(
      localMessageStore
          .allPending()
          .map((m) => m.localFilePath)
          .whereType<String>(),
    ),
  );
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
        localMessageStoreProvider.overrideWithValue(localMessageStore),
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

// Last uid this device was signed in as, used to detect an account change
// across app launches — see _reconcileLocalStoreWithSignedInUid.
const String _lastActiveUidKey = 'mugam_last_active_uid_v1';
// Set the instant an account change is detected and only cleared once the
// media wipe has actually finished, so killing the app mid-wipe leaves the
// intent recorded and the next launch finishes the job. Without it, a wipe
// interrupted halfway would silently leave the rest of the previous
// account's photos/videos on disk forever, with nothing left to signal it.
const String _pendingMediaWipeKey = 'mugam_pending_media_wipe_v1';

class _MugamAppState extends ConsumerState<MugamApp> {
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        unawaited(_reconcileLocalStoreWithSignedInUid(user.uid));
        PushNotificationService.instance.registerToken(user.uid);
        PresenceService.instance.start(user.uid);
        CallListenerService.instance.start(user.uid, (call) {
          // Only CallKitService here now — appRouter.push('/call/incoming/...')
          // was pushing our OWN Flutter incoming-call screen SIMULTANEOUSLY
          // with the real native CallKit/ConnectionService UI, confirmed
          // live (screenshot showed both stacked on top of each other).
          // Now that CallKit is the real, working incoming-call UI, our own
          // screen is redundant for this path — accepting/declining happens
          // through CallKitService's own onEvent listener instead.
          CallKitService.instance.showIncoming(
            callId: call.id,
            callkitId: call.callkitUuid,
            // Resolved server-side by startCall (see Call.callerName's own
            // comment) — no extra round-trip needed here anymore.
            callerName: call.callerName,
            isVideo: call.type == CallType.video,
          );
        });
      } else {
        PresenceService.instance.stop();
        CallListenerService.instance.stop();
      }
    });
    PushNotificationService.instance.setupForegroundPresentation();
    CallKitService.instance.ensureListening(FirestoreService());
    // Куда ведёт тап по уведомлению.
    //
    // Раньше открывался только чат и только для нового сообщения, а все
    // прочие типы молча не делали ничего. Уведомление, которое никуда не
    // ведёт, хуже его отсутствия: человек тапает, ничего не происходит, и
    // он перестаёт им доверять.
    //
    // Мероприятия ведут в «Müqavilələr», а не в саму карточку, и это
    // намеренно у ДВУХ типов из списка: у того, кого убрали из
    // мероприятия, и у того, чьё мероприятие удалили, карточка больше не
    // читается по правилам — переход вернул бы отказ. Признак приходит с
    // сервера полем `openList`, чтобы клиент не повторял у себя правило
    // доступа и не разошёлся с ним.
    PushNotificationService.instance.setupMessageOpenedHandler((data) {
      // КУДА ВЕСТИ — решает `pushRouteFor`, а не это место (26.08, N59).
      //
      // Здесь стоял жёсткий список типов и `startsWith('event_')`, то есть
      // решение жило внутри обработчика, который в тесте не поднять. Обход
      // 26.08 нашёл там три расхождения с сервером разом, и ни одно не
      // падало: нажатие просто не делало ничего. Разбор — в самом правиле.
      //
      // `null` — вести некуда: тип незнаком либо в данных нет нужного ключа.
      // Молчим, а не уводим на общий экран: увести значило бы открыть
      // человеку то, к чему его уведомление отношения не имеет.
      final route = pushRouteFor(data);
      if (route != null) appRouter.push(route);
    });
    // Eagerly instantiate the offline send retry loop at startup (not
    // lazily on first chat screen open) so pending sends hydrated from a
    // previous session (LocalMessageStore.init(), already awaited above)
    // resume retrying immediately, app-wide.
    ref.read(messageSendControllerProvider);
  }

  // Second half of the cross-account leak fix (see
  // LocalMessageStore.clearAllForSignOut for the first half and the full
  // story). clearAllForSignOut only runs on the app's own "Çıxış" flow;
  // this runs on EVERY sign-in, so it also covers the paths that flow
  // doesn't own — a server-invalidated session, a token that expired while
  // the app was killed, a restored device backup, or a future sign-out
  // call site that forgets to clean up.
  //
  // Keyed on the last uid seen rather than on "did we just sign out",
  // because authStateChanges' null emissions are not a reliable sign-out
  // signal: Auth restores a persisted session off the main isolate (see
  // auth_gate_screen.dart's own comment), so treating a transient null as
  // a sign-out would wipe a legitimately in-flight send on ordinary cold
  // starts. Signing back into the SAME account deliberately keeps its
  // pending queue — that's the offline-send guarantee working as intended.
  Future<void> _reconcileLocalStoreWithSignedInUid(String uid) async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final store = ref.read(localMessageStoreProvider);
      final previousUid = prefs.getString(_lastActiveUidKey);
      if (previousUid != null && previousUid != uid) {
        debugPrint(
          '🧹 account changed on this device ($previousUid -> $uid) — '
          'clearing local chat cache, pending queue and media caches',
        );
        // Recorded BEFORE any deleting starts (and before _lastActiveUidKey
        // moves on), so an app kill part-way through can't lose the fact
        // that a wipe is owed.
        await prefs.setBool(_pendingMediaWipeKey, true);
        await store.clearAllForSignOut();
      }
      await prefs.setString(_lastActiveUidKey, uid);
      // Runs both for a change just detected above and for one whose wipe
      // was interrupted on an earlier launch. Deliberately awaited inside
      // this method (which the auth listener fires unawaited, so the UI is
      // never blocked) and deliberately BEFORE the drop/log below, so the
      // previous account's bytes go first and the new account's own
      // freshly-cached media — which only starts arriving once its chats
      // render — isn't what gets thrown away.
      if (prefs.getBool(_pendingMediaWipeKey) ?? false) {
        await clearMediaCachesForAccountChange();
        await prefs.remove(_pendingMediaWipeKey);
        debugPrint('🧹 media caches cleared for account change');
      }
      // Belt and braces for state that predates this guard (or arrives via
      // a path neither branch above covers): anything queued under a
      // different uid is unsendable under firestore.rules and is dropped.
      final dropped = await store.dropForeignPendingMessages(uid);
      if (dropped > 0) {
        debugPrint(
          '🧹 dropped $dropped pending message(s) belonging to another '
          'account from this device\'s send queue',
        );
      }
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'main: local store / signed-in uid reconciliation failed',
      );
    }
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
