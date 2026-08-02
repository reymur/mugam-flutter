import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/time/instant_iso.dart';

// Mirrors mugam-v2's users/{uid}/pushTokens/{deviceId} = {token, updatedAt}
// shape exactly (same collection, same field names, updatedAt as an ISO
// string rather than a Firestore Timestamp) so the shared Cloud Function
// dispatcher can read either app's tokens the same way.
class PushNotificationService {
  PushNotificationService._();
  static final PushNotificationService instance = PushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  String? _registeredUid;
  StreamSubscription<String>? _tokenRefreshSub;

  static const _deviceIdKey = 'mugam_push_device_id_v1';
  static const _legacyPurgeKey = 'mugam_push_legacy_ids_purged_v1';

  // Идентификатор УСТАНОВКИ приложения, а не модели и не сборки ОС.
  //
  // Прежний вариант брал на Android `androidInfo.id` — это идентификатор
  // сборки операционной системы («SKQ1.220303.001»), общий для всех
  // телефонов с этой прошивкой. Данные прода 02.08 показали обе стороны
  // ошибки сразу:
  //
  //   1. РАЗНЫЕ устройства сливались в один документ: токен под
  //      `SKQ1.220303.001` лежал у трёх пользователей сразу (Teymur,
  //      Rafael, Ramil), и push, адресованный одному, уходил туда, где
  //      сидит другой. В теле push'а — имя отправителя и начало
  //      сообщения, то есть это утечка личных данных между аккаунтами,
  //      того же класса, что L1.
  //   2. ОДНО устройство расползалось по разным документам: один и тот же
  //      токен `e3DoPD60…` нашёлся под `BP2A.250605.031.A3` и под
  //      `AP3A.240905.015.A2` — телефон обновил прошивку между входами, и
  //      прежняя запись осталась сиротой навсегда.
  //
  // Случайный идентификатор, сохранённый на устройстве, даёт ровно ту
  // семантику, которая нужна: FCM-токен и так принадлежит установке
  // приложения, а не железу. Одна семантика на обе платформы —
  // `identifierForVendor` на iOS был не сломан, но он второй по счёту, а
  // два разных правила для одного поля это будущая ловушка.
  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null) return existing;
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await prefs.setString(_deviceIdKey, id);
    return id;
  }

  // Принцип I4: перестал писать в код — снеси и из данных. Прежние
  // документы этого же устройства (по идентификатору сборки на Android, по
  // identifierForVendor на iOS) иначе остались бы лежать вечно и
  // продолжали бы получать push уже после того, как человек вышел из
  // аккаунта. Своё удалить можно — правила разрешают писать только в свою
  // ветку; чужие следы того же устройства снимаются разовым скриптом.
  Future<void> _purgeLegacyDeviceIdDocs(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_legacyPurgeKey) == true) return;
      final info = DeviceInfoPlugin();
      final legacyIds = <String>[];
      if (Platform.isIOS) {
        final iosInfo = await info.iosInfo;
        legacyIds.add(iosInfo.identifierForVendor ?? 'unknown-ios');
      } else {
        final androidInfo = await info.androidInfo;
        legacyIds.add(androidInfo.id);
      }
      for (final legacyId in legacyIds) {
        await _db
            .collection('users')
            .doc(uid)
            .collection('pushTokens')
            .doc(legacyId)
            .delete();
      }
      await prefs.setBool(_legacyPurgeKey, true);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'PushNotificationService: legacy token doc purge failed',
      );
    }
  }

  Future<void> registerToken(String uid) async {
    try {
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      // On iOS the FCM token isn't available until the APNS handshake
      // completes; right after a cold start that can still be in flight, so
      // a single retry after a short delay avoids a spurious failure here.
      String? token;
      try {
        token = await _messaging.getToken();
      } catch (_) {
        await Future.delayed(const Duration(seconds: 2));
        token = await _messaging.getToken();
      }
      if (token == null) return;

      await _saveToken(uid, token);
      unawaited(_purgeLegacyDeviceIdDocs(uid));
      _registeredUid = uid;
      _tokenRefreshSub ??= _messaging.onTokenRefresh.listen((newToken) {
        if (_registeredUid != null) _saveToken(_registeredUid!, newToken);
      });
    } catch (_) {
      // Best-effort, matching mugam-v2's registerFCMToken swallow-and-log.
    }
  }

  Future<void> _saveToken(String uid, String token) async {
    final deviceId = await _deviceId();
    await _db
        .collection('users')
        .doc(uid)
        .collection('pushTokens')
        .doc(deviceId)
        .set({'token': token, 'updatedAt': nowInstantIso()});
  }

  Future<void> unregisterToken(String uid) async {
    try {
      final deviceId = await _deviceId();
      await _db
          .collection('users')
          .doc(uid)
          .collection('pushTokens')
          .doc(deviceId)
          .delete();
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'PushNotificationService: unregisterToken failed',
      );
    }
    _registeredUid = null;
  }

  // Shows the system banner/sound/badge even while the app is foregrounded —
  // otherwise iOS suppresses notification-payload pushes whenever the app is
  // already open. Every push our Cloud Function sends is a notification
  // payload, so this is the only foreground handling needed; no data-only
  // messages, so no onBackgroundMessage handler is required either — APNs
  // displays those natively while backgrounded/terminated.
  Future<void> setupForegroundPresentation() async {
    if (!Platform.isIOS) return;
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  // Covers both the "app was backgrounded, user tapped the notification"
  // path (onMessageOpenedApp) and the "app was fully terminated, the
  // notification launched it" cold-start path (getInitialMessage) — mirrors
  // mugam-v2's onNotificationTap handling both cases.
  void setupMessageOpenedHandler(void Function(Map<String, dynamic> data) onTap) {
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      onTap(message.data);
    });
    _messaging.getInitialMessage().then((message) {
      if (message != null) onTap(message.data);
    });
  }
}
