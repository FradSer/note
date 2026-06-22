import Foundation
import NoteModels

// MARK: - D1 Client Protocol

/// Abstraction over `D1SyncClient` that enables mock injection in tests.
/// `D1SyncClient` conforms to this protocol via an unconditional extension.
public protocol D1Client: Sendable {
  // MARK: Notes

  func pullAllNotes() async throws -> [Note]
  func pushNotes(
    _ notes: [Note],
    idOverrides: [String: String],
    lastModifiedByRemoteId: [String: String]
  ) async throws -> PushResult
  func deleteNote(id: String, lastModified: String?) async throws

  // MARK: Folders

  func pullAllFolders() async throws -> [NoteFolder]
  func pushFolders(
    _ folders: [NoteFolder],
    idOverrides: [String: String],
    lastModifiedByRemoteId: [String: String]
  ) async throws -> PushResult
  func deleteFolder(id: String, lastModified: String?) async throws
}
