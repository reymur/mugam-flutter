import AVFAudio
import CallKit
import Flutter
import GoogleMaps
import PushKit
import UIKit
import flutter_callkit_incoming
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate,
  CallkitIncomingAppDelegate
{
  // ДЕРЖИТСЯ ПОЛЕМ, А НЕ МЕСТНОЙ ПЕРЕМЕННОЙ, И ЭТО НЕ СТИЛЬ. PKPushRegistry
  // не удерживается системой: местная переменная умрёт вместе с методом,
  // делегат никто не позовёт, и адрес не придёт НИКОГДА — молча, без
  // единой ошибки в журнале. Ровно тот вид отказа, который здесь дороже
  // всего: у «адрес не пришёл» и «адрес не запрашивали» один и тот же
  // наблюдаемый вывод (I31).
  private var voipRegistry: PKPushRegistry?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // google_maps_flutter (location sharing, Part B) — Firebase-issued key,
    // already restricted in Google Cloud Console to this app's bundle id
    // and to the Maps SDK for iOS API only, so embedding it here (the
    // package's own documented integration point) isn't a secrecy concern
    // the way a backend API key would be. Must be called before the map
    // view is ever created, so it's here rather than somewhere lazier.
    GMSServices.provideAPIKey("AIzaSyAlXaHJ6StcMstt1WADVVkulyRywp2cfGE")
    // Registers the offline media-send queue's periodic background retry
    // task. Must happen here, before this method returns, per Apple's
    // BGTaskScheduler requirements. Workmanager's Dart-side
    // registerPeriodicTask() call (see main.dart) only fully covers
    // Android — on iOS the frequency has to be set natively.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "com.mugam.mugamFlutter.pendingQueueRetry",
      frequency: NSNumber(value: 15 * 60)
    )

    // ПОРЯДОК ЗДЕСЬ ЗНАЧИМ: реестр PushKit заводится ПОСЛЕ super, а не до.
    // Адрес приходит в pushRegistry(_:didUpdate:for:) и складывается в
    // SwiftFlutterCallkitIncomingPlugin.sharedInstance, а он появляется
    // только когда зарегистрированы плагины — то есть внутри super. До
    // super sharedInstance равен nil, и первый пришедший адрес утёк бы в
    // никуда: опять-таки молча.
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    registerVoipPushRegistry()
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    NativeSoundEffectPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "NativeSoundEffectPlugin")!
    )
    NativeVideoCompressorPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "NativeVideoCompressorPlugin")!
    )
    VoipPushPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "VoipPushPlugin")!
    )
  }

  // MARK: - PushKit (N172: звонок, будящий УБИТОЕ приложение)

  // Шаг 2 из четырёх, разобранных в lib/core/calls/callkit_service.dart.
  // Здесь заводится только АДРЕС: iOS выдаёт VoIP-токен, мы кладём его туда,
  // откуда его заберёт Dart и запишет в users/{uid}/voipPushTokens.
  //
  // ПРАВИЛА ЭТОЙ КОЛЛЕКЦИИ УЖЕ В ПРОДЕ (набор 52628a3f-…, 01.09 23:18 UTC) —
  // порядок соблюдён нарочно: с невыложенными правилами запись отвергалась
  // бы, коллекция осталась бы пустой, и замер шага 3 показал бы ноль. Ноль
  // прочёлся бы как «нативный код не работает», то есть привёл бы к правке
  // исправного места.
  private func registerVoipPushRegistry() {
    let registry = PKPushRegistry(queue: DispatchQueue.main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    // Плагин сам кладёт адрес в UserDefaults и тут же сообщает о нём в Dart
    // событием DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP. Оба пути нужны и не
    // дублируют друг друга: событие ловит обновление на живом приложении,
    // UserDefaults — тот случай, когда адрес пришёл раньше, чем Dart успел
    // подписаться (холодный старт). Второй путь и есть основной: адрес
    // выдаётся один раз за установку и потом молчит месяцами.
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  // ПРИЁМ ВХОДЯЩЕГО VoIP-PUSH'А. САМОЕ ЖЁСТКОЕ ПО СРОКАМ МЕСТО ВО ВСЁМ
  // ПРИЛОЖЕНИИ, И СРОК ЗДЕСЬ НЕ СОВЕТ, А УСЛОВИЕ ЖИЗНИ.
  //
  // ЧТО ТРЕБУЕТ iOS. Начиная с iOS 13 на КАЖДЫЙ принятый VoIP-push
  // приложение обязано сообщить о входящем звонке в CallKit —
  // `CXProvider.reportNewIncomingCall` — и сделать это ДО того, как вернётся
  // переданный сюда `completion`. Не «желательно», не «поскорее»: ровно на
  // каждый push ровно один отчёт, и раньше `completion`.
  //
  // ЧТО БУДЕТ, ЕСЛИ ОТЧЁТ ОПОЗДАЕТ ИЛИ НЕ СОСТОИТСЯ. Наказание идёт двумя
  // ступенями, и вторая необратима в пределах установки:
  //   1. система СНИМАЕТ приложение — не «звонок не покажется», а процесс
  //      убивается;
  //   2. при повторах iOS ПЕРЕСТАЁТ ДОСТАВЛЯТЬ VoIP-push этому приложению
  //      ВОВСЕ. Не отказом, не ошибкой — просто перестаёт. Чинится это
  //      переустановкой приложения, и никакая правка кода уже не поможет.
  // То есть отказ здесь имеет ровно тот вид, который в этом проекте дороже
  // всего: у «звонки выключены системой» и «звонков сегодня не было» один и
  // тот же наблюдаемый вывод (I31). Понять, что это случилось, будет нечем.
  //
  // ОТСЮДА ТРИ ПРАВИЛА, КОТОРЫЕ ЗДЕСЬ СОБЛЮДЕНЫ И КОТОРЫЕ НЕЛЬЗЯ ОСЛАБИТЬ:
  //
  //   а. НИКАКОЙ АСИНХРОННОЙ РАБОТЫ ДО ОТЧЁТА. Ни чтения Firestore, ни
  //      ожидания движка Flutter, ни сети. Всё, что нужно для отчёта, обязано
  //      приехать В САМОМ PUSH'Е — поэтому сервер кладёт туда и `callkitUuid`,
  //      и имя звонящего, и вид звонка. Именно поэтому мост к нашему
  //      CallKitService идёт ПОСЛЕ отчёта, а не до (см. ниже).
  //
  //   б. ОТЧЁТ ДЕЛАЕТСЯ ДАЖЕ ПРИ НЕГОДНОМ ПУСТОМ ПУСТЬ-ЧЁМ. Плагин на
  //      неразбираемом UUID молча НЕ отчитывается и лишь зовёт `completion`
  //      (проверено чтением его исходника, `showCallkitIncoming` с
  //      `completion`, ветка `guard let uuid`). Для нас это ровно тот случай,
  //      за который снимают. Поэтому негодный идентификатор ЗАМЕНЯЕТСЯ своим
  //      годным, отчёт делается, и звонок тут же закрывается — человек видит
  //      мигнувшее окно вместо умершего навсегда VoIP.
  //
  //   в. `completion` ЗОВЁТСЯ РОВНО ОДИН РАЗ И НА ВСЕХ ПУТЯХ, включая
  //      «push не наш».
  //
  // ПРО `sharedInstance`, КОТОРЫЙ ЗДЕСЬ НЕ МОЖЕТ БЫТЬ nil, И ЭТО НЕ НАДЕЖДА.
  // Плагины регистрируются внутри `super.application(...)`, а реестр PushKit
  // заводится СТРОКОЙ ПОЗЖЕ (см. `registerVoipPushRegistry` выше). iOS
  // доставляет push только в заведённый реестр, значит к моменту доставки
  // super уже вернулся и `sharedInstance` существует. Порядок в
  // `didFinishLaunchingWithOptions` — часть этого рассуждения, и менять его
  // местами нельзя.
  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }

    let body = payload.dictionaryPayload
    let pushedUuid = body["id"] as? String ?? ""
    let firestoreCallId = body["callId"] as? String ?? ""
    let callerName = body["nameCaller"] as? String ?? "Zəng"
    // Вид звонка приезжает строкой ("video"/"audio"), а не булевым: в JSON
    // push'а булево пришлось бы угадывать по типу, а строку видно глазом в
    // журнале APNs.
    let isVideo = (body["callType"] as? String) == "video"

    // Годен ли идентификатор — решается ЗДЕСЬ, до отчёта, потому что от
    // ответа зависит, чем отчитываться (правило «б» выше).
    let uuidIsUsable = UUID(uuidString: pushedUuid) != nil
    let payloadIsUsable = uuidIsUsable && !firestoreCallId.isEmpty

    let data = flutter_callkit_incoming.Data(
      id: uuidIsUsable ? pushedUuid : UUID().uuidString,
      nameCaller: callerName,
      handle: "",
      type: isVideo ? 1 : 0
    )
    data.appName = "Mugam"
    data.duration = 30000
    data.handleType = "generic"
    data.supportsVideo = true
    data.ringtonePath = "system_ringtone_default"
    // ЭТО И ЕСТЬ МОСТ К НАШЕМУ КОДУ, И ОН ОДНА СТРОКА. `extra` плагин
    // сохраняет сам и отдаёт обратно в событии ACTION_CALL_INCOMING и во всех
    // последующих (приём, отказ, конец) — в том числе в другом процессе.
    // Поэтому Dart-сторона ничего заново не выясняет: она берёт
    // `firestoreCallId` оттуда же, откуда берёт его путь через FCM.
    data.extra = ["firestoreCallId": firestoreCallId]

    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(
      data, fromPushKit: true
    ) {
      completion()
    }

    // Закрывается ПОСЛЕ отчёта, а не вместо него. Порядок именно такой:
    // сперва выполнить требование системы, потом убрать то, что показывать
    // нечем.
    if !payloadIsUsable {
      NSLog(
        "[VoIP] негодный push: uuid=%@ callId=%@ — отчёт сделан, звонок закрыт",
        pushedUuid, firestoreCallId
      )
      SwiftFlutterCallkitIncomingPlugin.sharedInstance?.endCall(data)
    }
  }

  // ЧЕГО ЗДЕСЬ НЕТ И ПОЧЕМУ. Мы НЕ поднимаем движок Flutter и НЕ зовём
  // отсюда Dart: это работа на секунды, а срок отчёта — доли секунды
  // (правило «а»). Наш CallKitService подхватывает звонок сам, событием
  // ACTION_CALL_INCOMING, которое плагин шлёт из обработчика успешного
  // отчёта. Разбор моста — в lib/core/calls/callkit_service.dart, случай
  // `CallEventActionCallIncoming`. Ссылка в обе стороны (I42).

  // MARK: - CallkitIncomingAppDelegate (N194)

  // ПОЧЕМУ МЫ ВООБЩЕ ПОДПИСАНЫ НА ЭТОТ ПРОТОКОЛ. Он единственный способ
  // узнать о нажатии, когда Dart ещё не поднялся: плагин зовёт эти методы
  // из обработчиков CXProvider, В SWIFT, СИНХРОННО, независимо от того,
  // существует ли движок Flutter. Штатного фонового обработчика на iOS у
  // плагина НЕТ — `registerBackgroundHandler` есть только в андроидной
  // части, а неизвестный метод канала на iOS отвечает
  // `FlutterMethodNotImplemented`. Проверено чтением исходника плагина.
  //
  // ОДНА ОБЯЗАННОСТЬ ПЕРЕШЛА К НАМ ВМЕСТЕ С ПОДПИСКОЙ, И ОНА МОЛЧАЛИВАЯ:
  // в `provider(_:perform:)` плагин зовёт `action.fulfill()` ТОЛЬКО в ветке
  // `else`, то есть когда делегата нет. Подписались — зовём сами. Не позвать
  // — CallKit повиснет на действии до собственного тайм-аута транзакции, и
  // человек увидит нажатие, которое «не сработало». Сторож на это —
  // `test/pending_call_actions_test.dart`, вердикт про `action.fulfill()`.

  func onAccept(_ call: Call, _ action: CXAnswerCallAction) {
    record("accept", call)
    action.fulfill()
  }

  func onDecline(_ call: Call, _ action: CXEndCallAction) {
    record("decline", call)
    action.fulfill()
  }

  func onEnd(_ call: Call, _ action: CXEndCallAction) {
    record("end", call)
    action.fulfill()
  }

  // У этого метода параметра `action` нет вовсе — завершать нечего, плагин
  // уже отчитался в CallKit сам.
  func onTimeOut(_ call: Call) {
    record("timeout", call)
  }

  private func record(_ name: String, _ call: Call) {
    let callId = call.data.extra["firestoreCallId"] as? String ?? ""
    // Пусто — значит нагрузка была негодной и звонок уже закрыт (см. правило
    // «б» у приёма push'а). Откладывать нечего: применять такое действие
    // Dart всё равно будет некуда.
    guard !callId.isEmpty else { return }
    VoipPushPlugin.recordPendingAction(name, callId: callId, callkitId: call.uuid.uuidString)
  }

  // ТРИ ПУСТЫЕ РЕАЛИЗАЦИИ НИЖЕ — НЕ ЗАБЫТЫЕ, А ПРОВЕРЕННО ЛИШНИЕ, и это
  // записано здесь нарочно: следующий читатель обязан увидеть довод, а не
  // решить, что до них не дошли руки.
  //
  // Проверено чтением плагина: в отличие от `onAccept`/`onDecline`/`onEnd`,
  // которые стоят в `if/else` и ЗАБИРАЮТ у плагина вызов `action.fulfill()`,
  // эти три вызываются ДОПОЛНИТЕЛЬНО — плагин делает всю свою работу и до, и
  // после них:
  //   - `didActivate` (строка 775): зовёт нас, а затем сам поднимает звук
  //     исходящего и принятого звонка;
  //   - `didDeactivate` (806) — то же;
  //   - `providerDidReset` (624): сам гасит все звонки, чистит список и шлёт
  //     событие, и только потом зовёт нас.
  // Значит наполнить их — значит делать ту же работу второй раз. Звук в
  // разговоре ведёт Agora, к сессии CallKit он не привязан.

  func didActivateAudioSession(_ audioSession: AVAudioSession) {}

  func didDeactivateAudioSession(_ audioSession: AVAudioSession) {}

  func providerDidReset() {}
}
