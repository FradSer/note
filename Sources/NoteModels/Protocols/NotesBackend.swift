import Foundation

// MARK: - Notes Backend Protocol

public protocol NotesBackend: Sendable {
  func fetchNotes(folderName: String?) async throws -> [Note]
  func fetchNote(byId id: String) async throws -> Note
  func searchNotes(keyword: String, folderName: String?) async throws -> [Note]
  func createNote(_ params: CreateNoteParams) async throws -> Note
  func updateNote(id: String, params: UpdateNoteParams) async throws -> Note
  func moveNote(id: String, toFolder folderName: String) async throws -> Note
  func deleteNote(id: String) async throws
}

// MARK: - Create Note Params

public struct CreateNoteParams: Sendable {
  public let title: String
  public let body: String?
  public let folderName: String?

  public init(title: String, body: String? = nil, folderName: String? = nil) {
    self.title = title
    self.body = body
    self.folderName = folderName
  }
}

// MARK: - Update Note Params

public struct UpdateNoteParams: Sendable {
  public let title: String?
  public let body: String?

  public init(title: String? = nil, body: String? = nil) {
    self.title = title
    self.body = body
  }
}
