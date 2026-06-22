import XCTest

@testable import NoteModels
@testable import NoteSync

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

final class EncryptionServiceTests: XCTestCase {
  private func makeKey() -> SymmetricKey {
    SymmetricKey(size: .bits256)
  }

  func testEncryptDecryptRoundTrip() async throws {
    let service = EncryptionService(key: makeKey())
    let payload = EncryptedPayload(body: "# Secret\n\nbackup code 1234")

    let sealed = try await service.encrypt(
      payload, recordId: "n1", modifiedDate: "2026-03-10T10:00:00Z")
    XCTAssertFalse(sealed.encryptedPayload.isEmpty)
    XCTAssertFalse(sealed.encryptedIV.isEmpty)

    let opened = try await service.decrypt(
      sealed.encryptedPayload, iv: sealed.encryptedIV,
      recordId: "n1", modifiedDate: "2026-03-10T10:00:00Z")
    XCTAssertEqual(opened.body, "# Secret\n\nbackup code 1234")
  }

  func testWrongKeyFailsToDecrypt() async throws {
    let encryptService = EncryptionService(key: makeKey())
    let decryptService = EncryptionService(key: makeKey())
    let payload = EncryptedPayload(body: "secret")

    let sealed = try await encryptService.encrypt(
      payload, recordId: "n1", modifiedDate: "d")

    do {
      _ = try await decryptService.decrypt(
        sealed.encryptedPayload, iv: sealed.encryptedIV, recordId: "n1", modifiedDate: "d")
      XCTFail("Expected decryption to fail with the wrong key")
    } catch let error as EncryptionError {
      XCTAssertEqual(error, .decryptionFailed)
    }
  }

  func testTamperedAADFailsToDecrypt() async throws {
    let service = EncryptionService(key: makeKey())
    let payload = EncryptedPayload(body: "secret")
    let sealed = try await service.encrypt(payload, recordId: "n1", modifiedDate: "d1")

    do {
      _ = try await service.decrypt(
        sealed.encryptedPayload, iv: sealed.encryptedIV, recordId: "n1", modifiedDate: "d2")
      XCTFail("Expected decryption to fail when the AAD context differs")
    } catch let error as EncryptionError {
      XCTAssertEqual(error, .decryptionFailed)
    }
  }

  func testKeyFromBase64ValidatesLength() {
    let shortKey = Data(repeating: 0, count: 16).base64EncodedString()
    XCTAssertThrowsError(try EncryptionService.keyFromBase64(shortKey)) { error in
      XCTAssertEqual(error as? EncryptionError, .invalidKeyLength)
    }

    let goodKey = Data(repeating: 0, count: 32).base64EncodedString()
    XCTAssertNoThrow(try EncryptionService.keyFromBase64(goodKey))
  }
}
