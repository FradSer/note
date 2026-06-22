import XCTest

@testable import NoteModels
@testable import NoteSync

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

final class NoteEncryptorTests: XCTestCase {
  private func makeEncryptor() -> NoteEncryptor {
    NoteEncryptor(encryption: EncryptionService(key: SymmetricKey(size: .bits256)))
  }

  func testEncryptReplacesBodyWithCarrierAndDecryptsBack() async throws {
    let encryptor = makeEncryptor()
    let note = Note(
      id: "n1", title: "Codes", body: "# Codes\n\n1234 5678", folder: "Secure",
      account: nil, creationDate: "2026-01-01", modifiedDate: "2026-01-02")

    let encrypted = try await encryptor.encryptNotes([note])
    XCTAssertEqual(encrypted.count, 1)
    // The body must no longer be plaintext, but must be a valid carrier.
    XCTAssertNotEqual(encrypted[0].body, note.body)
    XCTAssertNotNil(EncryptedCarrier.fromJSON(encrypted[0].body ?? ""))
    // Title and folder stay plaintext.
    XCTAssertEqual(encrypted[0].title, "Codes")
    XCTAssertEqual(encrypted[0].folder, "Secure")

    let decrypted = try await encryptor.decryptNotes(encrypted)
    XCTAssertEqual(decrypted[0].body, note.body)
  }

  func testEmptyBodyPassesThroughUnchanged() async throws {
    let encryptor = makeEncryptor()
    let note = Note(
      id: "n1", title: "Empty", body: nil, folder: "Notes",
      account: nil, creationDate: nil, modifiedDate: nil)
    let encrypted = try await encryptor.encryptNotes([note])
    XCTAssertNil(encrypted[0].body)
  }

  func testDecryptResponseLeavesTombstonesUntouched() async throws {
    let encryptor = makeEncryptor()
    let tombstone = PullItem(
      id: "n1",
      data: Note(
        id: "n1", title: "", body: nil, folder: "", account: nil,
        creationDate: nil, modifiedDate: nil),
      deleted: true,
      updatedAt: "2026-01-01",
      lastModified: "2026-01-01")
    let response = PullResponse(items: [tombstone], cursor: "1|n1", hasMore: false)

    let decrypted = try await encryptor.decryptResponse(response)
    XCTAssertEqual(decrypted.items.count, 1)
    XCTAssertTrue(decrypted.items[0].deleted)
  }

  func testPlaintextBodySurvivesDecrypt() async throws {
    // A note whose body is not a carrier (e.g. encryption was off) is left as-is.
    let encryptor = makeEncryptor()
    let note = Note(
      id: "n1", title: "Plain", body: "just text", folder: "Notes",
      account: nil, creationDate: nil, modifiedDate: nil)
    let decrypted = try await encryptor.decryptNote(note)
    XCTAssertEqual(decrypted.body, "just text")
  }
}
