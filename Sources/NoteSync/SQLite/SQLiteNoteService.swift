import Foundation
import NoteModels
import SQLite

// MARK: - SQLite Note Service

/// SQLite-backed note storage using SQLite.swift. Stores each Note as JSON in a
/// `data` column and tracks sync state via `is_local_only` and `deleted` flags.
/// Used as the local backend on non-macOS platforms.
public actor SQLiteNoteService: NotesBackend {
  private let connection: Connection

  public init(connection: Connection) {
    self.connection = connection
  }

  // MARK: - Fetch

  public func fetchNotes(folderName: String?) async throws -> [Note] {
    var sql = "SELECT data FROM notes WHERE deleted = 0"
    var bindings: [Binding?] = []

    if let folderName {
      sql += " AND json_extract(data, '$.folder') = ?"
      bindings.append(folderName)
    }

    sql += " ORDER BY updated_at DESC"

    return try connection.prepare(sql, bindings).map { row in
      try Self.decodeNote(from: row[0])
    }
  }

  public func fetchNote(byId id: String) async throws -> Note {
    let sql = "SELECT data FROM notes WHERE id = ? AND deleted = 0"
    for row in try connection.prepare(sql, [id]) {
      return try Self.decodeNote(from: row[0])
    }
    throw NoteCLIError.notFound("Note with ID '\(id)' not found")
  }

  public func searchNotes(keyword: String, folderName: String?) async throws -> [Note] {
    let all = try await fetchNotes(folderName: folderName)
    let lowered = keyword.lowercased()
    return all.filter { note in
      note.title.lowercased().contains(lowered)
        || (note.body?.lowercased().contains(lowered) ?? false)
    }
  }

  // MARK: - Create

  public func createNote(_ params: CreateNoteParams) async throws -> Note {
    let now = ISO8601DateFormatter.noteISO8601.string(from: Date())
    let id = UUID().uuidString

    let note = Note(
      id: id,
      title: params.title,
      body: params.body,
      folder: params.folderName ?? "Notes",
      account: nil,
      creationDate: now,
      modifiedDate: now
    )

    let jsonString = try Self.encode(note)
    try connection.run(
      """
      INSERT INTO notes (id, data, last_modified, deleted, updated_at, is_local_only)
      VALUES (?, ?, ?, 0, NULL, 1)
      """,
      id, jsonString, now
    )

    return note
  }

  // MARK: - Update

  public func updateNote(id: String, params: UpdateNoteParams) async throws -> Note {
    let existing = try await fetchNote(byId: id)
    let now = ISO8601DateFormatter.noteISO8601.string(from: Date())

    let updated = existing.with(
      title: params.title ?? existing.title,
      body: params.body.map { .some($0) } ?? .some(existing.body),
      modifiedDate: .some(now)
    )

    let jsonString = try Self.encode(updated)
    try connection.run(
      """
      UPDATE notes
      SET data = ?, last_modified = ?, updated_at = NULL, is_local_only = 1
      WHERE id = ? AND deleted = 0
      """,
      jsonString, now, id
    )

    return updated
  }

  // MARK: - Move

  public func moveNote(id: String, toFolder folderName: String) async throws -> Note {
    let existing = try await fetchNote(byId: id)
    let now = ISO8601DateFormatter.noteISO8601.string(from: Date())
    let updated = existing.with(folder: folderName, modifiedDate: .some(now))

    let jsonString = try Self.encode(updated)
    try connection.run(
      """
      UPDATE notes
      SET data = ?, last_modified = ?, updated_at = NULL, is_local_only = 1
      WHERE id = ? AND deleted = 0
      """,
      jsonString, now, id
    )

    return updated
  }

  // MARK: - Delete

  public func deleteNote(id: String) async throws {
    let now = ISO8601DateFormatter.noteISO8601.string(from: Date())
    try connection.run(
      """
      UPDATE notes
      SET deleted = 1, last_modified = ?, updated_at = NULL, is_local_only = 1
      WHERE id = ? AND deleted = 0
      """,
      now, id
    )

    if connection.changes == 0 {
      throw NoteCLIError.notFound("Note with ID '\(id)' not found")
    }
  }

  // MARK: - Private Helpers

  private static func decodeNote(from value: Binding?) throws -> Note {
    guard let jsonString = value as? String,
      let jsonData = jsonString.data(using: .utf8)
    else {
      throw NoteCLIError.unknown("Failed to decode note data")
    }
    return try JSONDecoder().decode(Note.self, from: jsonData)
  }

  private static func encode(_ note: Note) throws -> String {
    let jsonData = try JSONEncoder().encode(note)
    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
      throw NoteCLIError.unknown("Failed to encode note as JSON")
    }
    return jsonString
  }
}
