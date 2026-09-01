import Flutter
import GoogleMaps
import PushKit
import UIKit
import flutter_callkit_incoming
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
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

  // ПРИЁМ ВХОДЯЩЕГО PUSH'А ЗДЕСЬ НАРОЧНО НЕ РЕАЛИЗОВАН — ЭТО ШАГ 4, И ЭТО
  // НЕ ЗАБЫТО, А ОТЛОЖЕНО. Оставлять пустым безопасно ровно до тех пор, пока
  // VoIP-push никто не шлёт, а не шлёт его никто: функция отправки ещё не
  // написана (шаг 4, `startCall` в functions/src/index.ts).
  //
  // ЧЕМ ЭТО ОПАСНО СТАНЕТ В ТОТ ЖЕ ДЕНЬ, КОГДА ШАГ 4 ВЫЛОЖАТ: начиная с
  // iOS 13 система требует, чтобы на КАЖДЫЙ принятый VoIP-push приложение
  // сообщило о звонке в CallKit. Не сообщило — приложение снимается, а при
  // повторе iOS перестаёт доставлять VoIP-push этому приложению вовсе.
  // То есть отсутствие этого метода — не «ничего не произойдёт», а
  // «трубка замолчит навсегда, и починится это только переустановкой».
  //
  // Поэтому шаг 4 обязан начинаться отсюда, а не с функции:
  //   pushRegistry(_:didReceiveIncomingPushWith:for:completion:) →
  //   SwiftFlutterCallkitIncomingPlugin.sharedInstance?
  //     .showCallkitIncoming(data, fromPushKit: true) { completion() }
  // Ссылка в обе стороны (I42): второй конец этой записи — TODO(pushkit)
  // в lib/core/calls/callkit_service.dart.
}
