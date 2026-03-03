import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register native BG removal plugin
    if let controller = window?.rootViewController as? FlutterViewController {
      BgRemovalPlugin.register(with: controller.registrar(forPlugin: "BgRemovalPlugin")!)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Register BG removal after engine is ready
    BgRemovalPlugin.register(with: engineBridge.pluginRegistry.registrar(forPlugin: "BgRemovalPlugin")!)
  }
}
