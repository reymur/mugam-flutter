import Flutter
import GoogleMaps
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    NativeSoundEffectPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "NativeSoundEffectPlugin")!
    )
    NativeVideoCompressorPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "NativeVideoCompressorPlugin")!
    )
  }
}
