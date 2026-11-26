import Flutter
import Security
import UIKit

private final class PendingExport {
  let requestID: String
  let temporaryURL: URL
  let result: FlutterResult
  weak var picker: UIDocumentPickerViewController?
  var cancelled = false
  var completed = false

  init(requestID: String, temporaryURL: URL, result: @escaping FlutterResult) {
    self.requestID = requestID
    self.temporaryURL = temporaryURL
    self.result = result
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private let exportChannelName = "com.asodya.annotations/export"
  private var pendingExport: PendingExport?

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

    let exportChannel = FlutterMethodChannel(
      name: exportChannelName,
      binaryMessenger: messenger
    )
    exportChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "SAVE_UNAVAILABLE", message: "Application is unavailable", details: nil))
        return
      }
      switch call.method {
      case "saveExport":
        self.beginExport(call, result: result)
      case "cancelExport":
        self.cancelExport(call, result: result)
      default:
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
              let data = ((args["verified_user_id"] as? String).map { $0.isEmpty ? "\(sid)\n\(csrf)" : "\(sid)\n\(csrf)\n\($0)" } ?? "\(sid)\n\(csrf)").data(using: .utf8) else {
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
        let parts = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count >= 2 {
          var session: [String: Any] = ["session_id": String(parts[0]), "csrf_token": String(parts[1])]
          if parts.count == 3 && !parts[2].isEmpty { session["verified_user_id"] = String(parts[2]) }
          result(session)
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

  private func beginExport(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let requestID = args["request_id"] as? String,
          !requestID.isEmpty,
          let requestedName = args["name"] as? String,
          let mimeType = args["mime_type"] as? String,
          let typedBytes = args["bytes"] as? FlutterStandardTypedData else {
      result(FlutterError(code: "INVALID_ARGS", message: "Missing export request fields", details: nil))
      return
    }
    guard pendingExport == nil else {
      result(FlutterError(code: "SAVE_BUSY", message: "Another export picker is active", details: nil))
      return
    }
    let extensionName: String
    switch mimeType {
    case "application/pdf": extensionName = "pdf"
    case "application/zip": extensionName = "zip"
    default:
      result(FlutterError(code: "INVALID_MIME", message: "Unsupported export MIME type", details: nil))
      return
    }
    let safeName = safeExportName(requestedName, extensionName: extensionName)
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("annotations-export", isDirectory: true)
    let temporaryURL = cache.appendingPathComponent(UUID().uuidString + "-" + safeName)
    do {
      try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
      try typedBytes.data.write(to: temporaryURL, options: .atomic)
    } catch {
      result(FlutterError(code: "SAVE_STAGE_FAILED", message: error.localizedDescription, details: nil))
      return
    }

    let pending = PendingExport(requestID: requestID, temporaryURL: temporaryURL, result: result)
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forExporting: [temporaryURL], asCopy: true)
    } else {
      picker = UIDocumentPickerViewController(url: temporaryURL, in: .exportToService)
    }
    picker.delegate = self
    pending.picker = picker
    pendingExport = pending
    guard var presenter = window?.rootViewController else {
      finishExport(pending, value: FlutterError(code: "SAVE_UNAVAILABLE", message: "No active document presenter", details: nil))
      return
    }
    while let presented = presenter.presentedViewController {
      presenter = presented
    }
    presenter.present(picker, animated: true)
  }

  private func cancelExport(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let requestID = args["request_id"] as? String,
          let pending = pendingExport,
          pending.requestID == requestID else {
      result(false)
      return
    }
    pending.cancelled = true
    if let picker = pending.picker, picker.presentingViewController != nil {
      picker.dismiss(animated: true) { [weak self] in
        self?.finishExport(pending, value: ["status": "cancelled"])
      }
    } else {
      finishExport(pending, value: ["status": "cancelled"])
    }
    result(true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let pending = pendingExport, pending.picker === controller else { return }
    pending.cancelled = true
    finishExport(pending, value: ["status": "cancelled"])
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let pending = pendingExport, pending.picker === controller else { return }
    // The OS has accepted the export at this point. A later account change
    // cannot retract a user-selected destination file.
    finishExport(
      pending,
      value: ["status": !pending.cancelled && !urls.isEmpty ? "saved" : "cancelled"]
    )
  }

  private func finishExport(_ pending: PendingExport, value: Any?) {
    guard !pending.completed else { return }
    pending.completed = true
    if pendingExport === pending { pendingExport = nil }
    try? FileManager.default.removeItem(at: pending.temporaryURL)
    pending.result(value)
  }

  private func safeExportName(_ name: String, extensionName: String) -> String {
    let component = URL(fileURLWithPath: name).lastPathComponent
      .components(separatedBy: CharacterSet.controlCharacters).joined(separator: "_")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "\\", with: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let stem = component.replacingOccurrences(of: #"\.(pdf|zip)$"#, with: "", options: .regularExpression)
    return (stem.isEmpty ? "export" : stem) + "." + extensionName
  }
}
