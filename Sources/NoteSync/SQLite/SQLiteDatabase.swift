import Foundation
import NoteModels
import SQLite

// MARK: - SQLite Database

/// Thread-safe SQLite database manager using SQLite.swift.
public actor SQLiteDatabase {
  // MARK: - Properties

  // SQLite.swift's Connection serializes access internally, so it is safe to hand
  // out from a nonisolated context even though it is not Sendable.
  private nonisolated(unsafe) let connection: Connection

  /// Default database path at ~/.local/share/note-sync/local.db
  public static var defaultPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local")
      .appendingPathComponent("share")
      .appendingPathComponent("note-sync")
      .appendingPathComponent("local.db")
      .path
  }

  // MARK: - Initialization

  private init(connection: Connection) {
    self.connection = connection
  }

  // MARK: - Public Methods

  /// Opens or creates a SQLite database at the specified path.
  public static func open(at path: String? = nil) throws -> SQLiteDatabase {
    let dbPath = path ?? defaultPath

    let directory = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    let connection: Connection
    do {
      connection = try Connection(dbPath)
      try connection.execute("PRAGMA journal_mode = WAL")
      try connection.execute("PRAGMA synchronous = NORMAL")
      try connection.execute("PRAGMA foreign_keys = ON")
    } catch {
      throw NoteCLIError.unknown(
        "Failed to open database at \(dbPath): \(error.localizedDescription)")
    }

    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: dbPath) {
      do {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath)
      } catch {
        throw NoteCLIError.unknown(
          "Failed to set database file permissions: \(error.localizedDescription)")
      }
    }

    do {
      try runMigrations(on: connection)
    } catch {
      throw NoteCLIError.unknown("Database migration failed: \(error.localizedDescription)")
    }

    return SQLiteDatabase(connection: connection)
  }

  /// Returns the underlying Connection for direct use by services.
  /// Connection is thread-safe (uses internal serial queue).
  public nonisolated var databaseConnection: Connection {
    connection
  }

  // MARK: - Migrations

  private static func runMigrations(on connection: Connection) throws {
    let currentVersion = try connection.scalar("PRAGMA user_version") as! Int64
    guard currentVersion < 1 else { return }

    try connection.transaction {
      try connection.execute(
        """
          CREATE TABLE IF NOT EXISTS notes (
            id TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            last_modified TEXT NOT NULL,
            deleted INTEGER DEFAULT 0,
            updated_at TEXT DEFAULT (datetime('now')),
            is_local_only INTEGER DEFAULT 0
          )
        """)

      try connection.execute(
        """
          CREATE TABLE IF NOT EXISTS note_folders (
            id TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            last_modified TEXT NOT NULL,
            deleted INTEGER DEFAULT 0,
            updated_at TEXT DEFAULT (datetime('now')),
            is_local_only INTEGER DEFAULT 0
          )
        """)

      try connection.execute(
        """
          CREATE TABLE IF NOT EXISTS sync_cursors (
            entity_type TEXT PRIMARY KEY,
            cursor TEXT
          )
        """)

      try connection.execute(
        """
          CREATE TABLE IF NOT EXISTS sync_id_mappings (
            remote_id TEXT PRIMARY KEY,
            local_id TEXT NOT NULL,
            entity_type TEXT NOT NULL
          )
        """)

      try connection.execute(
        """
          CREATE TABLE IF NOT EXISTS sync_state (
            remote_id TEXT PRIMARY KEY,
            entity_type TEXT NOT NULL,
            last_modified TEXT NOT NULL,
            snapshot TEXT
          )
        """)

      try connection.execute(
        "CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at)")
      try connection.execute(
        "CREATE INDEX IF NOT EXISTS idx_note_folders_updated_at ON note_folders(updated_at)")

      try connection.execute("PRAGMA user_version = 1")
    }
  }
}
