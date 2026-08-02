import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../firebase/firestore_service.dart';

// TEMPORARY / INTERIM presence solution — see docs/presence-system.md for
// the full writeup. Cloud Firestore has no native disconnect-detection
// primitive, so this approximates presence with a periodic heartbeat write
// instead of a real persistent connection, and has an inherent staleness
// window as a result. Once the planned WebSocket Gateway server (shared
// infra for calls, live location, live gameplay, and typing indicators)
// exists, presence should be derived from that connection instead and this
// service retired.
class PresenceService with WidgetsBindingObserver {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  // Раз в 30 секунд, пока приложение на переднем плане — всегда, а не
  // только при открытом чате.
  //
  // Почему именно 30. Всё, что строится на присутствии, протухает через
  // ДВОЙНОЙ интервал: и подавление push на сервере, и строки на экране.
  // При ударе раз в 60 с окно равно двум минутам, и это оказалось слишком
  // грубо в двух местах сразу.
  //
  //   1. Push. Человек ушёл из приложения — уведомления не приходили ещё
  //      60–120 секунд. Замер 02.08: удары прекратились в 20:46:09,
  //      решение перевернулось в 20:48:10.
  //   2. Строка «📱 tətbiqdədir» в плашке переговоров. Она обещает «он
  //      сейчас в приложении, скоро увидит», и по ней инициатор решает,
  //      ждать ответа или написать позже. Держаться две минуты после
  //      того, как человек закрыл приложение, такое обещание не вправе.
  //
  // Сначала учащение сделали только для открытого чата — там свежесть
  // решает вопрос «смотрит ли он в ЭТОТ чат». Но обещание «в приложении»
  // живёт вне чата, и его окно осталось прежним, вдвое шире. Разрыв
  // увидели на устройстве: ступень «indicə» оказалась недостижимой, а
  // первое показанное значение сразу равнялось двум минутам.
  //
  // Цена: 2 записи в минуту на человека с открытым приложением, в
  // users/{uid}. Документ чата, вокруг которого крутится весь A3, не
  // затрагивается ни одной дополнительной записью.
  static const _heartbeatInterval = Duration(seconds: 30);

  final FirestoreService _firestoreService = FirestoreService();
  String? _uid;
  Timer? _timer;
  bool _observing = false;
  // Чат, открытый на экране прямо сейчас (N19). Едет вместе с
  // сердцебиением присутствия, потому что именно оно даёт отметке срок
  // годности: свернули приложение — биение прекратилось, и признак
  // «смотрит в этот чат» протухает сам, без всякой уборки.
  String? _activeChatId;

  // Зовётся с экрана чата: при открытии — с chatId, при закрытии — с null.
  // Пишет немедленно, а не ждёт следующего удара сердца: между входом в
  // чат и подавлением пуша не должно быть минутной дыры.
  void setActiveChat(String? chatId) {
    if (_activeChatId == chatId) return;
    _activeChatId = chatId;
    if (_uid != null) {
      _writePresence(online: true);
      // Отсчёт начинается заново от только что сделанной записи — иначе
      // очередной удар пришёлся бы на секунду после неё и стоил лишней
      // записи ни за чем. На частоту вход в чат больше не влияет: она
      // одна и та же, пока приложение открыто.
      _startTimer();
    }
  }

  void start(String uid) {
    // No longer short-circuits when _uid/_timer already look "started" —
    // confirmed on-device as a real bug: `lastSeen` stuck over 5 hours
    // stale (online:true the whole time) while the app was genuinely in
    // active use. _timer being non-null only proves a Timer object exists,
    // not that it's still actually firing — if something (an iOS
    // background-suspend edge case, a missed/undelivered `resumed`
    // lifecycle callback while attached to Xcode's debugger, etc.) left it
    // silently dead, this guard permanently blocked ever restarting it,
    // since every later start(uid) call with the same uid hit this same
    // early return. _writePresence/_startTimer below are both idempotent
    // (Timer.periodic itself cancels any prior timer first), so always
    // running them here is safe.
    debugPrint('🟢 PresenceService.start($uid) called');
    _uid = uid;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _writePresence(online: true);
    _startTimer();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    final uid = _uid;
    _uid = null;
    if (uid != null) {
      await _firestoreService.setUserPresence(uid, online: false);
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      _heartbeatInterval,
      (_) => _writePresence(online: true),
    );
  }

  void _writePresence({required bool online}) {
    final uid = _uid;
    if (uid == null) return;
    unawaited(
      _firestoreService.setUserPresence(
        uid,
        online: online,
        activeChatId: _activeChatId,
        // Сборка объявляет свой интервал сама — сервер берёт двойной от
        // него как срок годности отметки. Без этого поля он остаётся на
        // прежних 120 с, поэтому менять частоту можно, не обновляя
        // сервер и все установленные сборки разом.
        presenceIntervalMs: _heartbeatInterval.inMilliseconds,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_uid == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _writePresence(online: true);
        _startTimer();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // Pause rather than immediately writing online:false — a brief
        // backgrounding (switching apps, camera, share sheet) shouldn't
        // flicker the presence dot offline. `online` goes stale for
        // genuinely-backgrounded users until they return (resumed rewrites
        // it immediately above) or sign out (stop() writes the final
        // online:false). This is the accepted tradeoff of this interim
        // heartbeat system — see docs/presence-system.md.
        _timer?.cancel();
        _timer = null;
    }
  }
}
