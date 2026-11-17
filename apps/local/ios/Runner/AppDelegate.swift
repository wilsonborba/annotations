import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let profileChannel = FlutterMethodChannel(
      name: "annotations/platform_profile",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    profileChannel.setMethodCallHandler { call, result in
      if call.method == "isPad" {
        result(UIDevice.current.userInterfaceIdiom == .pad)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
