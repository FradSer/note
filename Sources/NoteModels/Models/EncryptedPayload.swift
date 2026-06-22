import Foundation

// MARK: - Encrypted Payload

/// The sensitive content of a note that is end-to-end encrypted before it ever
/// reaches Cloudflare D1. Only the note body is encrypted; titles and folder
/// names remain plaintext so notes stay listable without the key.
public struct EncryptedPayload: Codable, Sendable, Equatable {
  public var body: String?

  public init(body: String? = nil) {
    self.body = body
  }

  public var isEmpty: Bool {
    body == nil
  }
}
