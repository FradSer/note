import Foundation

// MARK: - Note Folder Model

/// A folder in Apple Notes. Folders are identified by name within an account;
/// `parent` is the enclosing folder name (empty for top-level folders).
public struct NoteFolder: Codable, Sendable {
  public let id: String
  public let name: String
  public let account: String?
  public let parent: String?

  public init(id: String, name: String, account: String?, parent: String?) {
    self.id = id
    self.name = name
    self.account = account
    self.parent = parent
  }
}
