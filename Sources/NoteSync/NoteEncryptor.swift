import AppleSyncKit
import Foundation
import NoteModels

// MARK: - Note Encryptor

/// Transparently end-to-end encrypts the note `body` at the D1 boundary using the
/// shared `AppleSyncKit.EncryptionService`. The Worker only ever stores
/// ciphertext; titles and folder names stay plaintext so notes remain listable
/// without the key. Encryption happens on push, decryption on pull, so the local
/// store always holds plaintext Markdown.
public actor NoteEncryptor {
  private let encryption: EncryptionService

  public init(encryption: EncryptionService) {
    self.encryption = encryption
  }

  /// Builds an encryptor from `NOTE_ENCRYPTION_KEY`, or throws a helpful error
  /// when the key is missing or malformed.
  public static func fromEnvironment() throws -> NoteEncryptor {
    let key = try EncryptionService.keyFromEnvironment("NOTE_ENCRYPTION_KEY")
    return NoteEncryptor(encryption: EncryptionService(key: key))
  }

  // MARK: - Encrypt

  public func encryptNotes(_ notes: [Note]) async throws -> [Note] {
    var result: [Note] = []
    result.reserveCapacity(notes.count)
    for note in notes {
      result.append(try await encryptNote(note))
    }
    return result
  }

  private func encryptNote(_ note: Note) async throws -> Note {
    let payload = EncryptedPayload(body: note.body)
    guard !payload.isEmpty else { return note }

    let aadDate = Self.aadDate(for: note)
    let encrypted = try await encryption.encrypt(
      payload, recordId: note.id, modifiedDate: aadDate)
    let carrier = EncryptedCarrier(p: encrypted.encryptedPayload, i: encrypted.encryptedIV)
    return note.with(body: .some(try carrier.toJSONString()))
  }

  // MARK: - Decrypt

  /// Decrypts every non-deleted item's body in a pull response, leaving deleted
  /// tombstones and plaintext bodies untouched.
  public func decryptResponse(_ response: PullResponse<Note>) async throws -> PullResponse<Note> {
    var items: [PullItem<Note>] = []
    items.reserveCapacity(response.items.count)
    for item in response.items {
      if item.deleted {
        items.append(item)
      } else {
        let decrypted = try await decryptNote(item.data)
        items.append(
          PullItem(
            id: item.id, data: decrypted, deleted: item.deleted,
            updatedAt: item.updatedAt, lastModified: item.lastModified))
      }
    }
    return PullResponse(items: items, cursor: response.cursor, hasMore: response.hasMore)
  }

  public func decryptNotes(_ notes: [Note]) async throws -> [Note] {
    var result: [Note] = []
    result.reserveCapacity(notes.count)
    for note in notes {
      result.append(try await decryptNote(note))
    }
    return result
  }

  public func decryptNote(_ note: Note) async throws -> Note {
    guard let body = note.body, let carrier = EncryptedCarrier.fromJSON(body) else {
      return note
    }
    let aadDate = Self.aadDate(for: note)
    let payload: EncryptedPayload = try await encryption.decrypt(
      carrier.p, iv: carrier.i, recordId: note.id, modifiedDate: aadDate)
    return note.with(body: .some(payload.body))
  }

  // MARK: - Helpers

  private static func aadDate(for note: Note) -> String {
    note.modifiedDate ?? note.creationDate ?? ""
  }
}
