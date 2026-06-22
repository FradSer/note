import Foundation
import NoteModels
import SQLite

// MARK: - SQLite Folder Service

/// SQLite-backed folder storage. Stores each NoteFolder as JSON in a `data`
/// column. Used as the local backend on non-macOS platforms.
public actor SQLiteFolderService: FoldersBackend {
  private let connection: Connection

  public init(connection: Connection) {
    self.connection = connection
  }

  public func fetchFolders() async throws -> [NoteFolder] {
    let sql = "SELECT data FROM note_folders WHERE deleted = 0 ORDER BY updated_at DESC"
    return try connection.prepare(sql).map { row in
      try Self.decodeFolder(from: row[0])
    }
  }

  public func createFolder(name: String) async throws -> NoteFolder {
    let now = ISO8601DateFormatter.syncISO8601.string(from: Date())
    let id = UUID().uuidString
    let folder = NoteFolder(id: id, name: name, account: nil, parent: nil)

    let jsonString = try Self.encode(folder)
    try connection.run(
      """
      INSERT INTO note_folders (id, data, last_modified, deleted, updated_at, is_local_only)
      VALUES (?, ?, ?, 0, NULL, 1)
      """,
      id, jsonString, now
    )

    return folder
  }

  public func deleteFolder(name: String) async throws {
    let now = ISO8601DateFormatter.syncISO8601.string(from: Date())
    // Soft-delete every folder matching the name (folders are keyed by name).
    let folders = try await fetchFolders().filter { $0.name == name }
    guard !folders.isEmpty else {
      throw NoteCLIError.notFound("Folder '\(name)' not found")
    }
    for folder in folders {
      try connection.run(
        """
        UPDATE note_folders
        SET deleted = 1, last_modified = ?, updated_at = NULL, is_local_only = 1
        WHERE id = ? AND deleted = 0
        """,
        now, folder.id
      )
    }
  }

  // MARK: - Private Helpers

  private static func decodeFolder(from value: Binding?) throws -> NoteFolder {
    guard let jsonString = value as? String,
      let jsonData = jsonString.data(using: .utf8)
    else {
      throw NoteCLIError.unknown("Failed to decode folder data")
    }
    return try JSONDecoder().decode(NoteFolder.self, from: jsonData)
  }

  private static func encode(_ folder: NoteFolder) throws -> String {
    let jsonData = try JSONEncoder().encode(folder)
    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
      throw NoteCLIError.unknown("Failed to encode folder as JSON")
    }
    return jsonString
  }
}
