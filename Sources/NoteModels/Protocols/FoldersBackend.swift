import Foundation

// MARK: - Folders Backend Protocol

public protocol FoldersBackend: Sendable {
  func fetchFolders() async throws -> [NoteFolder]
  func createFolder(name: String) async throws -> NoteFolder
  func deleteFolder(name: String) async throws
}
