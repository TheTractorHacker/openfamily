import Flutter
import Foundation
import Security
import UIKit

// iOS counterpart of Android's KeystoreChannel.kt. Same MethodChannel name and
// contract, so the Dart code (lib/services/e2ee/e2ee_vault.dart) is shared:
//
//   encrypt(Uint8List)  -> Uint8List   wrap a secret for storage
//   decrypt(Uint8List)  -> Uint8List   unwrap it; error code "invalidated" if
//                                      the wrapping key is gone or unusable
//   status()            -> {level, unlockedDeviceRequired, userAuthRequired}
//                          level: "secure_enclave" | "keychain" | "unavailable"
//   recreateKey({requireUserAuth: Bool})
//   setSecure(Bool)                    hide sensitive screens (ScreenProtector)
//
// Design (docs/design/E2EE.md, "iOS differences"):
// * The Secure Enclave can only hold NIST P-256 keys. It cannot hold Ed25519 or
//   X25519, so the Enclave never sees the identity seed. Instead ONE P-256
//   wrapping key lives in the Enclave and the seed material is wrapped with
//   ECIES (X9.63 / SHA-256 / AES-GCM) under its public half. The private half
//   never leaves the Enclave.
// * encrypt() needs only the public key, so it works while the phone is locked
//   (background location sealing). decrypt() needs the private key, which is
//   usable after the first unlock since boot (AfterFirstUnlockThisDeviceOnly),
//   or only while unlocked and after Face ID / Touch ID / passcode when
//   recreateKey(requireUserAuth: true) was used.
// * Simulator and devices without a Secure Enclave get a software P-256 key in
//   the Keychain, reported honestly as "keychain".
// * Items are ThisDeviceOnly and non-synchronizable: not in iCloud Keychain, not
//   migrated to a new phone, not restorable from a backup.
final class SecureKeyChannel {
  static let channelName = "app.openfamily/keystore"

  private static let keyTag = Data("app.openfamily.e2ee.wrap.v1".utf8)
  private static let authDefaultsKey = "app.openfamily.e2ee.wrap.userAuth"
  private static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

  // Keychain services written by flutter_secure_storage (accountName option).
  // Wiped together with the wrapping key on the first launch after a reinstall.
  private static let storageServices = [
    "openfamily_e2ee", "openfamily_bg_credentials", "flutter_secure_storage_service",
  ]
  private static let installedDefaultsKey = "app.openfamily.installed.v1"

  private let queue = DispatchQueue(label: "app.openfamily.securekey", qos: .userInitiated)

  /// Registers the channel on [messenger]. Safe to call for several engines (the
  /// main one and the headless background-location engine).
  static func register(messenger: FlutterBinaryMessenger) {
    let instance = SecureKeyChannel()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in instance.handle(call, result) }
  }

  // MARK: Channel

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "setSecure":
      let on = (call.arguments as? Bool) ?? false
      DispatchQueue.main.async {
        ScreenProtector.shared.setSecure(on)
        result(nil)
      }
    case "encrypt", "decrypt", "status", "recreateKey":
      // Key operations may show the system Face ID / passcode sheet and block,
      // so never run them on the platform (main) thread.
      queue.async {
        let outcome: Result<Any?, KeyError>
        do {
          switch call.method {
          case "encrypt":
            outcome = .success(FlutterStandardTypedData(bytes: try self.encrypt(try Self.bytes(call))))
          case "decrypt":
            outcome = .success(FlutterStandardTypedData(bytes: try self.decrypt(try Self.bytes(call))))
          case "status":
            outcome = .success(try self.status())
          default:
            let args = call.arguments as? [String: Any]
            try self.recreate(requireUserAuth: (args?["requireUserAuth"] as? Bool) ?? false)
            outcome = .success(nil)
          }
        } catch let e as KeyError {
          outcome = .failure(e)
        } catch {
          outcome = .failure(KeyError(code: "keystore", detail: "unexpected"))
        }
        DispatchQueue.main.async {
          switch outcome {
          case .success(let value): result(value)
          // Never put key material or plaintext in the message.
          case .failure(let e): result(FlutterError(code: e.code, message: e.detail, details: nil))
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func bytes(_ call: FlutterMethodCall) throws -> Data {
    guard let typed = call.arguments as? FlutterStandardTypedData else {
      throw KeyError(code: "keystore", detail: "bad arguments")
    }
    return typed.data
  }

  /// Internal (not private) so RunnerTests can exercise the key logic.
  struct KeyError: Error {
    let code: String
    let detail: String
  }

  // MARK: Crypto

  func encrypt(_ plain: Data) throws -> Data {
    let (priv, _) = try loadOrCreateKey()
    guard let pub = SecKeyCopyPublicKey(priv),
      SecKeyIsAlgorithmSupported(pub, .encrypt, Self.algorithm)
    else { throw KeyError(code: "keystore", detail: "encrypt unsupported") }
    var err: Unmanaged<CFError>?
    guard let blob = SecKeyCreateEncryptedData(pub, Self.algorithm, plain as CFData, &err) else {
      throw KeyError(code: "keystore", detail: "encrypt failed")
    }
    return blob as Data
  }

  func decrypt(_ blob: Data) throws -> Data {
    // Unlike encrypt(), never mint a key here: a missing key means the stored
    // secrets are unreadable, and Dart must fail closed (restore from phrase).
    guard let priv = try loadKey() else {
      throw KeyError(code: "invalidated", detail: "wrapping key missing")
    }
    guard SecKeyIsAlgorithmSupported(priv, .decrypt, Self.algorithm) else {
      throw KeyError(code: "invalidated", detail: "decrypt unsupported")
    }
    var err: Unmanaged<CFError>?
    guard let plain = SecKeyCreateDecryptedData(priv, Self.algorithm, blob as CFData, &err) else {
      let cf = err?.takeRetainedValue()
      let code = cf.map { CFErrorGetCode($0) } ?? 0
      let domain = cf.map { CFErrorGetDomain($0) as String } ?? ""
      if domain == "com.apple.LocalAuthentication" {
        // LAError: user cancelled or failed Face ID / Touch ID / passcode.
        throw KeyError(code: "auth", detail: "authentication failed")
      }
      switch code {
      case -128, -25293:  // errSecUserCanceled, errSecAuthFailed
        throw KeyError(code: "auth", detail: "authentication failed")
      case -25308:  // errSecInteractionNotAllowed: phone locked / before first unlock
        throw KeyError(code: "locked", detail: "device locked")
      default:  // wrong key (e.g. restored data), corrupt blob
        throw KeyError(code: "invalidated", detail: "decrypt failed")
      }
    }
    return plain as Data
  }

  func status() throws -> [String: Any] {
    let (priv, _) = try loadOrCreateKey()
    let attrs = SecKeyCopyAttributes(priv) as? [String: Any]
    let token = attrs?[kSecAttrTokenID as String] as? String
    let inEnclave = token == (kSecAttrTokenIDSecureEnclave as String)
    let auth = UserDefaults.standard.bool(forKey: Self.authDefaultsKey)
    return [
      "level": inEnclave ? "secure_enclave" : "keychain",
      // With user auth the key is WhenUnlocked; otherwise AfterFirstUnlock.
      "unlockedDeviceRequired": auth,
      "userAuthRequired": auth,
    ]
  }

  func recreate(requireUserAuth: Bool) throws {
    try deleteKey()
    _ = try createKey(requireUserAuth: requireUserAuth)
    UserDefaults.standard.set(requireUserAuth, forKey: Self.authDefaultsKey)
  }

  // MARK: Keychain

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: Self.keyTag,
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    ]
  }

  private func loadKey() throws -> SecKey? {
    var q = baseQuery()
    q[kSecReturnRef as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &item)
    if st == errSecItemNotFound { return nil }
    guard st == errSecSuccess, let item = item else {
      if st == errSecInteractionNotAllowed { throw KeyError(code: "locked", detail: "device locked") }
      throw KeyError(code: "keystore", detail: "lookup \(st)")
    }
    return (item as! SecKey)
  }

  func deleteKey() throws {
    let st = SecItemDelete(baseQuery() as CFDictionary)
    if st != errSecSuccess && st != errSecItemNotFound {
      throw KeyError(code: "keystore", detail: "delete \(st)")
    }
  }

  private func loadOrCreateKey() throws -> (SecKey, Bool) {
    if let k = try loadKey() { return (k, false) }
    return (try createKey(requireUserAuth: false), true)
  }

  private func createKey(requireUserAuth: Bool) throws -> SecKey {
    #if targetEnvironment(simulator)
      let enclaveFirst = false  // the Simulator has no Secure Enclave
    #else
      let enclaveFirst = true
    #endif
    if enclaveFirst, let k = try? generate(requireUserAuth: requireUserAuth, enclave: true) {
      return k
    }
    return try generate(requireUserAuth: requireUserAuth, enclave: false)
  }

  private func generate(requireUserAuth: Bool, enclave: Bool) throws -> SecKey {
    var flags: SecAccessControlCreateFlags = []
    let protection: CFString
    if requireUserAuth {
      // Biometrics or device passcode, and only while the phone is unlocked.
      flags.insert(.userPresence)
      protection = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    } else {
      // Background location sealing runs while the phone is locked.
      protection = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
    if enclave { flags.insert(.privateKeyUsage) }
    var cfErr: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(nil, protection, flags, &cfErr) else {
      throw KeyError(code: "keystore", detail: "access control")
    }
    var privateAttrs: [String: Any] = [
      kSecAttrIsPermanent as String: true,
      kSecAttrApplicationTag as String: Self.keyTag,
      kSecAttrAccessControl as String: access,
    ]
    // Make sure this item can never be synced to iCloud Keychain.
    privateAttrs[kSecAttrSynchronizable as String] = false
    var attrs: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecPrivateKeyAttrs as String: privateAttrs,
    ]
    if enclave { attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave }
    var genErr: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &genErr) else {
      throw KeyError(code: "keystore", detail: enclave ? "enclave keygen" : "keygen")
    }
    return key
  }

  // MARK: First launch after (re)install

  /// iOS keeps Keychain items when an app is deleted. A reinstalled app would
  /// then find a wrapping key and wrapped secrets of the previous install.
  /// UserDefaults ARE deleted with the app, so a missing marker means "fresh
  /// install": wipe the wrapping key and our secure-storage services. Skipped
  /// while protected data is unavailable (a background relaunch before the
  /// first unlock could otherwise misread a missing marker).
  /// A restore from a backup keeps the marker but not the ThisDeviceOnly items,
  /// which makes decrypt() answer "invalidated" (fail closed, restore phrase).
  static func resetKeychainOnFreshInstall() {
    let defaults = UserDefaults.standard
    guard UIApplication.shared.isProtectedDataAvailable else { return }
    if defaults.bool(forKey: installedDefaultsKey) { return }
    let wrap = SecureKeyChannel()
    try? wrap.deleteKey()
    for service in storageServices {
      let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      ]
      SecItemDelete(q as CFDictionary)
    }
    defaults.removeObject(forKey: authDefaultsKey)
    defaults.set(true, forKey: installedDefaultsKey)
  }
}
