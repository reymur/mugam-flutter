import Flutter
import Foundation

// Backs lib/firebase/voip_push_token_service.dart. Answers ONE question that
// Dart cannot answer for itself: which APNs environment this build's push
// address belongs to — sandbox or production.
//
// ПОЧЕМУ ЭТО ЗАМЕР, А НЕ КОНСТАНТА, И ПОЧЕМУ ЭТО НЕ ПРИДИРКА. Адрес PushKit
// сам по себе не говорит, куда его нести: один и тот же по виду
// шестнадцатеричный адрес годен ЛИБО в sandbox, ЛИБО в production, и APNs
// на промах не жалуется — он выбрасывает молча. Это уже измерено на этом
// проекте: N186, две отправки на два адреса Рафаэля, доставлен один, отказа
// по второму не было вовсе; отсюда N191.
//
// Написать здесь `"sandbox"` строкой было бы верно РОВНО СЕГОДНЯ (сборка с
// кабеля, `aps-environment` = `development`) и стало бы неправдой в день
// первого TestFlight — причём неправдой, которая ничего не роняет и ничем
// себя не выдаёт: звонок просто перестанет доходить, а журнал сервера
// скажет «отправлено». Поэтому среда СНИМАЕТСЯ с того же места, откуда её
// берёт сама iOS, — с права `aps-environment` во встроенном профиле
// подготовки.
//
// ЧЕГО ЭТОТ ЗАМЕР НЕ ЛОВИТ (границы пишутся вместе со сторожем):
//   - профиля может не быть вовсе — сборка из симулятора, а на App Store
//     сборках `embedded.mobileprovision` не всегда лежит рядом. Тогда
//     возвращается `unknown`, и это НЕ подменяется правдоподобным
//     «production» (I50): пусть сервер увидит незнание и скажет о нём, чем
//     промахнётся молча;
//   - он говорит, куда годен адрес, и НИЧЕГО не говорит о том, жив ли адрес
//     и дойдёт ли push. Это разные вопросы, и второй проверяется только
//     делом.
class VoipPushPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "mugam/voip_push",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(VoipPushPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "apsEnvironment":
      result(VoipPushPlugin.apsEnvironment())
    case "takePendingCallActions":
      result(VoipPushPlugin.takePendingCallActions())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Несостоявшиеся действия над звонком (N194)

  // ЗАЧЕМ ЭТО ЕСТЬ. Приложение, разбуженное VoIP-push'ем из смахнутого
  // состояния, показывает окно звонка НАТИВНО, до того как поднимется Dart.
  // Человек успевает нажать «отклонить» или «принять» РАНЬШЕ, чем Dart
  // подпишется на события: замер 02.09 — подписка появляется не позже чем
  // через 1,32 с после push'а (серверные отметки: push 01:42:21.514Z, первая
  // запись клиента в Firestore 01:42:22.831Z), а нажатие укладывается в эту
  // секунду.
  //
  // События CallKit мгновенны и не повторяются: у `EventChannel` нет ни
  // буфера, ни очереди (N193). Поэтому нажатие, случившееся в эту секунду,
  // исчезало без следа — и выглядело это как «отклонил, а у звонящего экран
  // висит».
  //
  // ЧТО ЗДЕСЬ СДЕЛАНО: действие перестаёт быть мгновенным событием и
  // становится СОСТОЯНИЕМ, которое дожидается читателя. Гонки после этого
  // нет вовсе — не «она стала реже», а её больше не существует.
  //
  // ХРАНИТСЯ В UserDefaults, А НЕ В ПАМЯТИ, И ЭТО НЕ ПЕРЕСТРАХОВКА. После
  // отклонения из смахнутого приложения процесс держать нечем: iOS вправе
  // снять его раньше, чем Dart дочитает. Память такое не переживёт, и мы
  // получили бы тот же висящий экран, только реже — то есть хуже, потому что
  // перемежающийся отказ спишут на случайность.
  //
  // ЧЕГО НЕ ПОКРЫВАЕТ (границы пишутся вместе со сторожем): если человек
  // удалит приложение до следующего запуска, запись уйдёт вместе с ним; и
  // накопленное не имеет срока годности — Dart обязан забрать его при первом
  // же запуске, иначе оно применится с опозданием.
  private static let pendingKey = "MugamPendingCallActions"

  static func recordPendingAction(_ action: String, callId: String, callkitId: String) {
    var list = UserDefaults.standard.array(forKey: pendingKey) as? [[String: Any]] ?? []
    list.append([
      "action": action,
      "callId": callId,
      "callkitId": callkitId,
      "at": Date().timeIntervalSince1970,
    ])
    UserDefaults.standard.set(list, forKey: pendingKey)
    NSLog("[VoIP] отложено действие %@ по звонку %@", action, callId)
  }

  // ЗАБИРАЕТ И СРАЗУ ОЧИЩАЕТ. Иначе одно и то же действие применялось бы при
  // каждом запуске приложения — а «отклонить» задним числом по чужому,
  // давно законченному звонку хуже, чем не отклонить вовсе.
  static func takePendingCallActions() -> [[String: Any]] {
    let list = UserDefaults.standard.array(forKey: pendingKey) as? [[String: Any]] ?? []
    UserDefaults.standard.removeObject(forKey: pendingKey)
    return list
  }

  // "development" | "production" | "unknown"
  //
  // `embedded.mobileprovision` — подписанный CMS-конверт, внутри которого
  // лежит обычный XML-plist. Полноценный разбор конверта потребовал бы
  // Security.framework и проверки подписи, которая нам здесь не нужна:
  // файл лежит внутри нашего же бандла, и вопрос у нас не «подлинный ли
  // он», а «что в нём написано». Поэтому вырезается ровно plist — от
  // `<?xml` до закрывающего `</plist>`, — и читается штатным
  // PropertyListSerialization.
  static func apsEnvironment() -> String {
    guard
      let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let raw = try? Data(contentsOf: url)
    else {
      return "unknown"
    }

    guard
      let start = raw.range(of: Data("<?xml".utf8)),
      let end = raw.range(of: Data("</plist>".utf8), options: .backwards)
    else {
      return "unknown"
    }

    let plistData = raw.subdata(in: start.lowerBound..<end.upperBound)

    guard
      let plist = try? PropertyListSerialization.propertyList(
        from: plistData, options: [], format: nil
      ) as? [String: Any],
      let entitlements = plist["Entitlements"] as? [String: Any],
      let environment = entitlements["aps-environment"] as? String
    else {
      return "unknown"
    }

    // Apple пишет сюда ровно два значения; всё прочее — не наш случай, и
    // угадывать его нельзя.
    return environment == "development" || environment == "production"
      ? environment
      : "unknown"
  }
}
