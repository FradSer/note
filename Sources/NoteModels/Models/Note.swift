import Foundation

// MARK: - Note Model

/// A single Apple Note. On macOS the body round-trips through Markdown (Apple
/// Notes stores HTML natively); the `body` field holds Markdown. When a note is
/// pushed to Cloudflare D1 the body is carried as an encrypted carrier string,
/// transparently encrypted on push and decrypted on pull.
public struct Note: Codable, Sendable {
  public let id: String
  public let title: String
  public let body: String?
  public let folder: String
  public let account: String?
  public let creationDate: String?
  public let modifiedDate: String?

  public init(
    id: String,
    title: String,
    body: String?,
    folder: String,
    account: String?,
    creationDate: String?,
    modifiedDate: String?
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.folder = folder
    self.account = account
    self.creationDate = creationDate
    self.modifiedDate = modifiedDate
  }

  /// Returns a copy with the supplied fields replaced.
  public func with(
    id: String? = nil,
    title: String? = nil,
    body: String?? = nil,
    folder: String? = nil,
    account: String?? = nil,
    creationDate: String?? = nil,
    modifiedDate: String?? = nil
  ) -> Note {
    Note(
      id: id ?? self.id,
      title: title ?? self.title,
      body: body ?? self.body,
      folder: folder ?? self.folder,
      account: account ?? self.account,
      creationDate: creationDate ?? self.creationDate,
      modifiedDate: modifiedDate ?? self.modifiedDate
    )
  }
}
