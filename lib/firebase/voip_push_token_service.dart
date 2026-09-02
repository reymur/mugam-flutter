import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import '../core/calls/callkit_service.dart';
import '../core/device/install_id.dart';

// Адрес PushKit: users/{uid}/voipPushTokens/{deviceId}.
//
// ЗАЧЕМ ОТДЕЛЬНАЯ КОЛЛЕКЦИЯ, А НЕ ПОЛЕ В pushTokens. Это два разных адреса
// в двух разных сетях: FCM-токен ведёт к обычному уведомлению, VoIP-адрес —
// к окну входящего звонка, и push по нему идёт мимо FCM, прямо в APNs. Они
// выдаются порознь, протухают порознь, и у них разные права на чтение:
// `pushTokens` открыт любому вошедшему (так его читает mugam-v2), а этот —
// только владельцу, потому что чужой VoIP-адрес это возможность заставить
// чужой телефон зазвонить. Правила выложены 01.09 (набор 52628a3f-…).
//
// ПОЧЕМУ КЛАСС ПОВТОРЯЕТ ФОРМУ PushNotificationService, А НЕ СВЕДЁН С НИМ.
// Совпадает вид — «взять адрес, записать в свою ветку, стереть при выходе»,
// — а задачи разные: там обычное уведомление через FCM, здесь звонок через
// APNs напрямую. Свести их значило бы завести в общей функции
// переключатель «а этому в другую коллекцию и другим способом», то есть
// склеить два дела (I58). Общей осталась ровно та часть, где задача ОДНА:
// идентификатор установки — он вынесен в lib/core/device/install_id.dart и
// у обеих коллекций один и тот же.
class VoipPushTokenService {
  VoipPushTokenService._();
  static final VoipPushTokenService instance = VoipPushTokenService._();

  static const MethodChannel _channel = MethodChannel('mugam/voip_push');

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? _registeredUid;
  StreamSubscription<CallEvent?>? _tokenUpdateSub;

  // Тело документа собирается ОТДЕЛЬНОЙ ЧИСТОЙ ФУНКЦИЕЙ нарочно: состав
  // полей — единственное, что сторож может проверить, не выходя в сеть, и
  // единственное, о чём клиент и правила обязаны договориться поимённо.
  // Сторож — test/voip_push_token_doc_test.dart, и он сверяет этот состав с
  // тем, что пишет парный тест правил functions/test/voip-tokens-rules.test.ts.
  //
  // `updatedAt` — СЕРВЕРНОЕ время, а не время телефона. Часы на трубке
  // ставит человек, и уехавшие часы сделали бы «свежий адрес» неотличимым
  // от протухшего именно в тот момент, когда по свежести придётся выбирать,
  // на какой адрес слать (N186: APNs выбрасывает молча, отказа не даёт).
  static Map<String, Object?> tokenDoc({
    required String token,
    required String platform,
    required String environment,
  }) => {
    'token': token,
    'platform': platform,
    'environment': environment,
    'updatedAt': FieldValue.serverTimestamp(),
  };

  // "sandbox" | "production" | "unknown" — СНЯТО с права `aps-environment`
  // встроенного профиля, а не записано константой. Разбор, почему константа
  // здесь опаснее, чем выглядит, — в ios/Runner/VoipPushPlugin.swift.
  //
  // "unknown" НЕ ПОДМЕНЯЕТСЯ ПРАВДОПОДОБНЫМ (I50). Сервер, получив
  // "unknown", обязан сказать о незнании, а не гадать: промах по среде APNs
  // не даёт отказа, он даёт тишину.
  Future<String> apsEnvironment() async {
    try {
      final raw = await _channel.invokeMethod<String>('apsEnvironment');
      return switch (raw) {
        'development' => 'sandbox',
        'production' => 'production',
        _ => 'unknown',
      };
    } catch (_) {
      return 'unknown';
    }
  }

  // Зовётся при входе в аккаунт, рядом с PushNotificationService.registerToken.
  //
  // ДВА ПУТИ ДО АДРЕСА, И ОНИ НЕ ДУБЛИРУЮТ ДРУГ ДРУГА. iOS выдаёт VoIP-адрес
  // один раз за установку и потом молчит месяцами, поэтому:
  //   - ЧТЕНИЕМ (getDevicePushTokenVoIP) берётся адрес, который уже пришёл
  //     когда-то раньше и лежит в UserDefaults, — это обычный случай на
  //     каждом втором и следующем запуске;
  //   - ПОДПИСКОЙ ловится тот единственный раз, когда адрес приходит прямо
  //     сейчас, уже после входа, — первый запуск после установки.
  // Оставить только чтение значило бы на первом же запуске записать пусто и
  // не переписать никогда; оставить только подписку — не записать ничего на
  // всех последующих, потому что события больше не будет.
  Future<void> registerToken(String uid) async {
    if (!Platform.isIOS) return;
    _registeredUid = uid;

    // ПОДПИСКА ИДЁТ ЧЕРЕЗ CallKitService, А НЕ НА КАНАЛ НАПРЯМУЮ (N193).
    //
    // Здесь стояло `FlutterCallkitIncoming.onEvent.listen(...)` — своя,
    // вторая на весь приложение подписка на один и тот же `EventChannel`. У
    // канала слушатель ровно один, и второй забирает поток себе МОЛЧА:
    // ни ошибки, ни предупреждения. Эта строка обесточила приём и отклонение
    // звонка целиком — окно показывалось, а нажатие не делало ничего, и
    // выглядело это как поломка PushKit, а не как лишний слушатель.
    //
    // Цена ошибки была несимметричной: здесь ловится обновление адреса, что
    // случается раз за установку, а отняло — каждый приём и каждый отказ.
    //
    // Подписка ставится ДО чтения: между чтением и подпиской есть окно, и
    // адрес, пришедший в него, иначе потерялся бы до следующего запуска.
    _tokenUpdateSub ??= CallKitService.instance.events.listen((event) async {
      if (event is! CallEventActionDidUpdateDevicePushTokenVoip) return;
      final current = _registeredUid;
      if (current == null) return;
      await _readAndSave(current);
    });

    await _readAndSave(uid);
  }

  Future<void> _readAndSave(String uid) async {
    try {
      final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
      // Пусто — это НЕ поломка и не повод писать пустую строку в базу:
      // адрес ещё не выдан системой (первый запуск) либо только что отозван
      // (didInvalidatePushTokenFor кладёт сюда ""). Пустой адрес в базе был
      // бы хуже отсутствующего: сервер увидел бы строку, счёл её адресом и
      // отправил в никуда — а APNs на это не отвечает ничем (N186).
      if (token == null || token.isEmpty) return;

      final deviceId = await installId();
      await _db
          .collection('users')
          .doc(uid)
          .collection('voipPushTokens')
          .doc(deviceId)
          .set(
            tokenDoc(
              token: token,
              platform: 'ios',
              environment: await apsEnvironment(),
            ),
          );
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'VoipPushTokenService: saving the PushKit address failed',
      );
    }
  }

  // Снимается ДО logout(), по той же причине, что и FCM-токен: правила
  // разрешают писать в свою ветку только самому владельцу, после выхода
  // удалять уже нечем. Здесь цена ошибки выше, чем у обычного токена: у
  // покинутого аккаунта остался бы живой адрес звонка, и телефон, где
  // теперь сидит другой человек, показывал бы окно входящего вызова,
  // адресованного прежнему.
  Future<void> unregisterToken(String uid) async {
    _registeredUid = null;
    if (!Platform.isIOS) return;
    try {
      final deviceId = await installId();
      await _db
          .collection('users')
          .doc(uid)
          .collection('voipPushTokens')
          .doc(deviceId)
          .delete();
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'VoipPushTokenService: unregisterToken failed',
      );
    }
  }
}
