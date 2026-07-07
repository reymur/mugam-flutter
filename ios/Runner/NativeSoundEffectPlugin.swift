import Flutter
import AVFoundation

// Backs lib/core/native_sound_effect.dart. Deliberately does not touch
// AVAudioSession at all (no setCategory/setActive calls anywhere in this
// file) — category/activation stays entirely owned by the rest of the app
// (record's own session config during recording, chat_screen.dart's manual
// activate/deactivate around voice-message playback). A pool of pre-warmed
// AVAudioPlayer instances per soundId (prepareToPlay() at load time) is
// what makes play() instant — this mirrors the lichess-org/flutter-sound-
// effect package's own technique, minus its audio-session management,
// which is exactly what would have conflicted with this app's existing
// setup.
class NativeSoundEffectPlugin: NSObject, FlutterPlugin {
  // 2 players per sound is enough headroom for a fast press-release-press
  // cycle without needing to wait for the previous instance to finish.
  private static let poolSizePerSound = 2

  private var registrar: FlutterPluginRegistrar?
  private var players: [String: [AVAudioPlayer]] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    // Handling calls on a background task queue instead of the main thread
    // (same technique used by lichess-org/flutter-sound-effect, the
    // reference implementation this was modeled on) — AVAudioPlayer's
    // play()/currentTime calls don't require the main thread, and routing
    // them through it risked exactly the kind of press/release jank this
    // plugin exists to avoid, by momentarily competing with Flutter's own
    // main-thread rendering at the busiest possible moment (the tap itself).
    let taskQueue = registrar.messenger().makeBackgroundTaskQueue?()
    let channel = FlutterMethodChannel(
      name: "mugam/native_sound_effect",
      binaryMessenger: registrar.messenger(),
      codec: FlutterStandardMethodCodec.sharedInstance(),
      taskQueue: taskQueue
    )
    let instance = NativeSoundEffectPlugin()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a map", details: nil))
      return
    }
    switch call.method {
    case "load":
      guard let soundId = args["soundId"] as? String, let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected soundId and path", details: nil))
        return
      }
      guard let resourceKey = registrar?.lookupKey(forAsset: path),
            let fullPath = Bundle.main.path(forResource: resourceKey, ofType: nil) else {
        result(FlutterError(code: "LOAD_ERROR", message: "Asset not found: \(path)", details: nil))
        return
      }
      let url = URL(fileURLWithPath: fullPath)
      do {
        var pool: [AVAudioPlayer] = []
        for _ in 0..<NativeSoundEffectPlugin.poolSizePerSound {
          let player = try AVAudioPlayer(contentsOf: url)
          player.prepareToPlay()
          pool.append(player)
        }
        players[soundId] = pool
        result(nil)
      } catch {
        result(FlutterError(code: "LOAD_ERROR", message: "Failed to load \(path): \(error.localizedDescription)", details: nil))
      }
    case "play":
      guard let soundId = args["soundId"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected soundId", details: nil))
        return
      }
      guard let pool = players[soundId] else {
        result(FlutterError(code: "PLAY_ERROR", message: "No sound loaded for \(soundId)", details: nil))
        return
      }
      // Reuse the first idle instance; if every instance in the pool is
      // still playing (very fast repeat taps), just restart the first one
      // rather than dropping the sound entirely.
      let player = pool.first(where: { !$0.isPlaying }) ?? pool[0]
      player.currentTime = 0
      player.play()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
