import Flutter
import Security
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
    let messenger = engineBridge.applicationRegistrar.messenger()

    let profileChannel = FlutterMethodChannel(
      name: "annotations/platform_profile",
      binaryMessenger: messenger
    )
    profileChannel.setMethodCallHandler { call, result in
      if call.method == "isPad" {
        result(UIDevice.current.userInterfaceIdiom == .pad)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let secureChannel = FlutterMethodChannel(
      name: "com.asodya.annotations/secure_storage",
      binaryMessenger: messenger
    )
    let service = "com.asodya.annotations.session"
    let account = "default"
    secureChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "write":
        guard let args = call.arguments as? [String: Any],
              let sid = args["session_id"] as? String,
              let csrf = args["csrf_token"] as? String,
              let data = "\(sid)\n\(csrf)".data(using: .utf8) else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing session_id or csrf_token", details: nil))
          return
        }
        let deleteQuery: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
          kSecValueData as String: data,
          kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
          result(nil)
        } else {
          result(FlutterError(code: "KEYCHAIN_ERROR", message: "SecItemAdd failed: \(status)", details: nil))
        }

      case "read":
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
          kSecReturnData as String: true,
          kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
          result(nil)
          return
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
          result(FlutterError(code: "KEYCHAIN_ERROR", message: "SecItemCopyMatching failed: \(status)", details: nil))
          return
        }
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
          result(["session_id": String(parts[0]), "csrf_token": String(parts[1])])
        } else {
          result(nil)
        }

      case "delete":
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
          result(nil)
        } else {
          result(FlutterError(code: "KEYCHAIN_ERROR", message: "SecItemDelete failed: \(status)", details: nil))
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
