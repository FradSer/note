import Foundation
import NoteModels
import NoteSync

// MARK: - Backend Factory

/// Creates the appropriate backend services for the current platform. On macOS,
/// returns AppleScript-backed services for local Apple Notes. On other platforms,
/// returns SQLite-backed services for local storage with sync via D1.
enum BackendFactory {
  #if os(macOS)
    static func makeNotesBackend() async throws -> any NotesBackend {
      NotesService()
    }

    static func makeFoldersBackend() async throws -> any FoldersBackend {
      FolderService()
    }

    /// macOS: creates a SyncService for bidirectional push/pull. The body
    /// encryptor is built from `NOTE_ENCRYPTION_KEY`; when the key is absent the
    /// service still syncs folders but throws a helpful error on note sync.
    static func makeSyncService() async throws -> any SyncServiceProtocol {
      let config = try SyncConfigStore.load()
      let encryptor = try? NoteEncryptor.fromEnvironment()
      return SyncService(config: config, encryptor: encryptor)
    }
  #else
    static func makeNotesBackend() async throws -> any NotesBackend {
      let db = try SQLiteDatabase.open()
      return SQLiteNoteService(connection: db.databaseConnection)
    }

    static func makeFoldersBackend() async throws -> any FoldersBackend {
      let db = try SQLiteDatabase.open()
      return SQLiteFolderService(connection: db.databaseConnection)
    }

    /// Linux: creates a LinuxSyncService for bidirectional push/pull between
    /// SQLite and D1.
    static func makeSyncService() async throws -> any SyncServiceProtocol {
      let config = try SyncConfigStore.load()
      let db = try SQLiteDatabase.open()
      let encryptor = try? NoteEncryptor.fromEnvironment()
      return LinuxSyncService(config: config, database: db, encryptor: encryptor)
    }
  #endif
}
