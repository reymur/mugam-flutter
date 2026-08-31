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

// Куда уходит отметка присутствия. Отдельным швом, а не прямым вызовом
// FirestoreService, ради СТОРОЖА НА ПРОВОДКУ: правило «в фоне отметка не
// публикуется» можно покрыть тестом на чистом условии и при этом не
// позвать его из ветви жизненного цикла — правило будет покрыто, а вызов
// не сделан (I64). Через этот шов тест держит весь путь целиком: от
// сообщения о смене состояния до значения, ушедшего в запись.
typedef PresenceWrite =
    void Function(
      String uid, {
      required bool online,
      String? activeChatId,
      String? activeEventId,
      int? presenceIntervalMs,
    });

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

  // Лениво, а не полем. `instance` — статическое поле, а конструктор
  // FirestoreService трогает `FirebaseFirestore.instance` прямо в
  // инициализаторах своих полей. Без лени одно упоминание
  // `PresenceService.instance` в тесте падало бы на отсутствии Firebase —
  // и сторожа на проводку написать было бы нечем.
  FirestoreService? _firestoreServiceOrNull;
  FirestoreService get _firestoreService =>
      _firestoreServiceOrNull ??= FirestoreService();

  // Подменный получатель записи — только для сторожа на проводку, см.
  // `PresenceWrite` выше. В проде всегда null.
  PresenceWrite? _writeOverride;

  String? _uid;
  Timer? _timer;
  bool _observing = false;

  // Приложение на переднем плане прямо сейчас (N171).
  //
  // Отметки «смотрю сюда» — `_activeChatId` и `_activeEventId` —
  // публикуются, ТОЛЬКО пока это true. Прежде их снимал один лишь уход с
  // экрана, а уход в фон не снимал ничего: сердцебиение прекращалось, и
  // отметка протухала сама — через ОКНО СВЕЖЕСТИ, то есть ещё минуту. Всю
  // эту минуту сервер считал человека смотрящим и глушил push от того
  // самого собеседника, с которым он только что говорил; от остальных
  // уведомления при этом шли. Замер прода 26.08, 02:55 UTC: у одного
  // участника последний удар 24 с назад при окне 60 с — push заглушен.
  //
  // Хранится ОТДЕЛЬНО, а не затиранием `_activeChatId`: экран чата
  // остаётся открытым, пока приложение свёрнуто, и на возврате сообщить о
  // себе ему нечем — `setActiveChat` больше никто не позовёт. Затерев, мы
  // потеряли бы отметку насовсем и стали бы звенеть человеку, который
  // вернулся и смотрит в этот самый чат.
  bool _inForeground = true;
  // Чат, открытый на экране прямо сейчас (N19). Едет вместе с
  // сердцебиением присутствия, потому что именно оно даёт отметке срок
  // годности: свернули приложение — биение прекратилось, и признак
  // «смотрит в этот чат» протухает сам, без всякой уборки.
  String? _activeChatId;

  // Карточка мероприятия, открытая прямо сейчас. ОТДЕЛЬНОЕ поле, а не
  // переиспользование `_activeChatId`: механизм тот же (та же отметка, то
  // же окно свежести), а вопрос другой — «смотрит в эту карточку», а не
  // «смотрит в этот чат». Одно поле на два вопроса это ровно устройство,
  // из которого выросли N19, N21 и N22.
  String? _activeEventId;

  // Зовётся с карточки мероприятия: при открытии — с id, при закрытии —
  // с null. Пишет немедленно по той же причине, что и чат: между
  // открытием карточки и подавлением уведомления не должно быть дыры.
  void setActiveEvent(String? eventId) {
    if (_activeEventId == eventId) return;
    _activeEventId = eventId;
    if (_uid != null) {
      _writePresence(online: true);
      _startTimer();
    }
  }

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
    // В фоне публикуется null, а не то, что осталось открытым на экране
    // (N171). Само поле не трогается — оно нужно на возврате.
    final chat = _inForeground ? _activeChatId : null;
    final event = _inForeground ? _activeEventId : null;
    // Сборка объявляет свой интервал сама — сервер берёт двойной от него
    // как срок годности отметки. Без этого поля он остаётся на прежних
    // 120 с, поэтому менять частоту можно, не обновляя сервер и все
    // установленные сборки разом.
    final intervalMs = _heartbeatInterval.inMilliseconds;
    final write = _writeOverride;
    if (write != null) {
      write(
        uid,
        online: online,
        activeChatId: chat,
        activeEventId: event,
        presenceIntervalMs: intervalMs,
      );
      return;
    }
    unawaited(
      _firestoreService.setUserPresence(
        uid,
        online: online,
        activeChatId: chat,
        activeEventId: event,
        presenceIntervalMs: intervalMs,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_uid == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        // Возврат возвращает и отметку «смотрю сюда»: экран чата всё это
        // время оставался открытым и позвать `setActiveChat` сам не может
        // (N171). Порядок важен — флаг до записи, иначе запись опубликует
        // ещё фоновый null.
        _inForeground = true;
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
        // А ВОТ ОТМЕТКУ «СМОТРЮ СЮДА» — СНЯТЬ НЕМЕДЛЕННО (N171).
        //
        // Она отвечает на другой вопрос, чем `online`, и потому судьба у
        // неё другая. `online` отвечает «жив ли человек», и там мигание
        // действительно хуже задержки. Отметка отвечает «видит ли он это
        // сообщение прямо сейчас», и в фоне ответ — «нет», без всякого
        // окна. Прежде она снималась только протуханием присутствия, то
        // есть через минуту, и всю эту минуту push от последнего
        // собеседника глушился молча.
        //
        // `online: true` здесь намеренно: запись снимает отметку и НЕ
        // трогает точку присутствия — иначе она бы замигала ровно так, как
        // оговорено выше.
        //
        // Запись делается один раз и только если публиковать было что.
        // Оба условия настоящие, а не осторожность:
        //   — `_inForeground` уже false означает, что отметку сняла
        //     предыдущая ступень. iOS шлёт сворачивание ТРЕМЯ состояниями
        //     подряд (inactive → hidden → paused), и без этой проверки
        //     каждое сворачивание стоило бы трёх записей вместо одной;
        //   — у человека без открытого чата и без открытой карточки
        //     запись не изменила бы ни одного поля.
        final needsClear =
            _inForeground && (_activeChatId != null || _activeEventId != null);
        _inForeground = false;
        if (needsClear) _writePresence(online: true);
    }
  }

  // --- швы для сторожа на проводку; в проде не зовутся ---

  @visibleForTesting
  void debugSetWriter(PresenceWrite? write) => _writeOverride = write;

  // Возврат в исходное БЕЗ записи в Firestore — этим отличается от
  // `stop()`, которому запись как раз и нужна.
  @visibleForTesting
  void debugReset() {
    _timer?.cancel();
    _timer = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _uid = null;
    _activeChatId = null;
    _activeEventId = null;
    _inForeground = true;
    _writeOverride = null;
  }
}
