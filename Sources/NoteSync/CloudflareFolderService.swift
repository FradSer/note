import AppleSyncKit
import Foundation
import NoteModels

// MARK: - Cloudflare Folder Service

/// Reads and writes folders directly against Cloudflare D1. Folder names are
/// plaintext, so no encryption is involved.
public actor CloudflareFolderService: FoldersBackend {
  private let client: D1SyncClient

  public init(client: D1SyncClient) {
    self.client = client
  }

  public func fetchFolders() async throws -> [NoteFolder] {
    try await client.pullAll(entity: "note_folders")
  }

  public func createFolder(name: String) async throws -> NoteFolder {
    let folder = NoteFolder(id: UUID().uuidString, name: name, account: nil, parent: nil)
    _ = try await client.push(entity: "note_folders", items: [folder], id: { $0.id })
    return folder
  }

  public func deleteFolder(name: String) async throws {
    let all: [NoteFolder] = try await client.pullAll(entity: "note_folders")
    let matches = all.filter { $0.name == name }
    guard !matches.isEmpty else {
      throw NoteCLIError.notFound("Folder '\(name)' not found")
    }
    let now = ISO8601DateFormatter.syncISO8601.string(from: Date())
    for folder in matches {
      try await client.delete(entity: "note_folders", id: folder.id, lastModified: now)
    }
  }
}
