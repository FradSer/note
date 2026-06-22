import Foundation
import NoteModels

// MARK: - Cloudflare Folder Service

/// Reads and writes folders directly against Cloudflare D1. Folder names are
/// plaintext, so no encryption is involved.
public actor CloudflareFolderService: FoldersBackend {
  private let client: D1Client

  public init(client: D1Client) {
    self.client = client
  }

  public func fetchFolders() async throws -> [NoteFolder] {
    try await client.pullAllFolders()
  }

  public func createFolder(name: String) async throws -> NoteFolder {
    let folder = NoteFolder(id: UUID().uuidString, name: name, account: nil, parent: nil)
    _ = try await client.pushFolders(
      [folder], idOverrides: [:], lastModifiedByRemoteId: [:])
    return folder
  }

  public func deleteFolder(name: String) async throws {
    let all = try await client.pullAllFolders()
    let matches = all.filter { $0.name == name }
    guard !matches.isEmpty else {
      throw NoteCLIError.notFound("Folder '\(name)' not found")
    }
    let now = ISO8601DateFormatter.noteISO8601.string(from: Date())
    for folder in matches {
      try await client.deleteFolder(id: folder.id, lastModified: now)
    }
  }
}
