import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
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
