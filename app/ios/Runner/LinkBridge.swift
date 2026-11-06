import Flutter
import Foundation
import UIKit

/// Forwards invite links to Dart over "app.openfamily/links" (same contract as
/// MainActivity.kt: `getInitialLink` for a cold start, `link` while running).
/// Accepts universal links (https://<server>/join/<code>) and the landing-page
/// button (openfamily://join?server=...&code=...). Dart re-validates everything.
final class LinkBridge {
  static let shared = LinkBridge()

  private var channel: FlutterMethodChannel?
  private var launcher: FlutterMethodChannel?
  private var initial: String?
  private var dartAsked = false

  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "app.openfamily/links", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      if call.method == "getInitialLink" {
        self.dartAsked = true
        result(self.initial)
        self.initial = nil
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch

    // "app.openfamily/launcher": open(String) -> Bool. Hands tel:, sms: and
    // otpauth: links (and Apple Maps links) to the system; the iOS stand-in for
    // the android_intent_plus calls. Anything else is refused.
    let launcher = FlutterMethodChannel(name: "app.openfamily/launcher", binaryMessenger: messenger)
    launcher.setMethodCallHandler { call, result in
      guard call.method == "open", let raw = call.arguments as? String,
        let url = URL(string: raw), let scheme = url.scheme?.lowercased()
      else { return result(false) }
      let allowed = ["tel", "sms", "otpauth"]
      let isMaps = scheme == "https" && url.host == "maps.apple.com"
      guard allowed.contains(scheme) || isMaps else { return result(false) }
      DispatchQueue.main.async {
        UIApplication.shared.open(url, options: [:]) { ok in result(ok) }
      }
    }
    self.launcher = launcher
  }

  /// Returns true when [url] looks like an invite link and was taken.
  @discardableResult
  func handle(url: URL) -> Bool {
    let isCustom = url.scheme == "openfamily" && url.host == "join"
    let isHttps = url.scheme == "https" && url.path.contains("/join/")
    guard isCustom || isHttps else { return false }
    if dartAsked, let ch = channel {
      ch.invokeMethod("link", arguments: url.absoluteString)
    } else {
      initial = url.absoluteString
    }
    return true
  }
}
