import Flutter
import UIKit
import XCTest

@testable import Runner

// Runs in CI on the iOS Simulator (.github/workflows/test.yml, job "ios").
// The Simulator has no Secure Enclave, so these exercise the software-key
// (level "keychain") path of SecureKeyChannel. The Secure Enclave path and the
// Face ID / passcode gate can only be tested on a physical iPhone.
class RunnerTests: XCTestCase {

  private let channel = SecureKeyChannel()

  override func setUpWithError() throws {
    try channel.recreate(requireUserAuth: false)
  }

  func testEncryptDecryptRoundTrip() throws {
    let secret = Data((0..<32).map { UInt8($0) })
    let blob = try channel.encrypt(secret)
    XCTAssertNotEqual(blob, secret)
    XCTAssertGreaterThan(blob.count, secret.count)
    XCTAssertEqual(try channel.decrypt(blob), secret)
  }

  func testEncryptionIsRandomized() throws {
    let secret = Data(repeating: 7, count: 32)
    XCTAssertNotEqual(try channel.encrypt(secret), try channel.encrypt(secret))
  }

  func testStatusReportsKeychainOnSimulator() throws {
    let status = try channel.status()
    #if targetEnvironment(simulator)
      XCTAssertEqual(status["level"] as? String, "keychain")
    #else
      XCTAssertTrue(["secure_enclave", "keychain"].contains(status["level"] as? String ?? ""))
    #endif
    XCTAssertEqual(status["userAuthRequired"] as? Bool, false)
  }

  func testDecryptWithoutKeyFailsClosed() throws {
    let blob = try channel.encrypt(Data([1, 2, 3]))
    try channel.deleteKey()
    XCTAssertThrowsError(try channel.decrypt(blob)) { error in
      XCTAssertEqual((error as? SecureKeyChannel.KeyError)?.code, "invalidated")
    }
  }

  func testRecreatedKeyCannotReadOldBlobs() throws {
    let blob = try channel.encrypt(Data([1, 2, 3]))
    try channel.recreate(requireUserAuth: false)
    XCTAssertThrowsError(try channel.decrypt(blob)) { error in
      XCTAssertEqual((error as? SecureKeyChannel.KeyError)?.code, "invalidated")
    }
  }

  func testInviteLinkBridgeAcceptsOnlyInviteLinks() {
    XCTAssertTrue(LinkBridge.shared.handle(url: URL(string: "https://fam.example.com/join/AB23CDEF")!))
    XCTAssertTrue(LinkBridge.shared.handle(url: URL(string: "openfamily://join?server=https%3A%2F%2Ffam.example.com&code=AB23CDEF")!))
    XCTAssertFalse(LinkBridge.shared.handle(url: URL(string: "https://evil.example.com/other")!))
    XCTAssertFalse(LinkBridge.shared.handle(url: URL(string: "openfamily://settings")!))
  }
}
