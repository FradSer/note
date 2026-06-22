import Foundation
import NoteModels

// MARK: - Cloudflare Note Service

/// Reads and writes notes directly against Cloudflare D1, transparently
/// decrypting bodies on read and encrypting on write. Used by the advanced
/// `note sync notes` subcommands to inspect or edit D1 data without a local store.
public actor CloudflareNoteService: NotesBackend {
  private let client: D1Client
  private let encryptor: NoteEncryptor

  public init(client: D1Client, encryptor: NoteEncryptor) {
    self.client = client
    self.encryptor = encryptor
  }

  // MARK: - Fetch

  public func fetchNotes(folderName: String?) async throws -> [Note] {
    let all = try await client.pullAllNotes()
    let filtered = folderName.map { name in all.filter { $0.folder == name } } ?? all
    return try await encryptor.decryptNotes(filtered)
  }

  public func fetchNote(byId id: String) async throws -> Note {
    let all = try await client.pullAllNotes()
    guard let note = all.first(where: { $0.id == id }) else {
      throw NoteCLIError.notFound("Note with ID '\(id)' not found")
    }
    return try await encryptor.decryptNote(note)
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
    let note = Note(
      id: UUID().uuidString,
      title: params.title,
      body: params.body,
      folder: params.folderName ?? "Notes",
      account: nil,
      creationDate: now,
      modifiedDate: now
    )
    try await push(note)
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
    try await push(updated)
    return updated
  }

  // MARK: - Move

  public func moveNote(id: String, toFolder folderName: String) async throws -> Note {
    let existing = try await fetchNote(byId: id)
    let now = ISO8601DateFormatter.noteISO8601.string(from: Date())
    let updated = existing.with(folder: folderName, modifiedDate: .some(now))
    try await push(updated)
    return updated
  }

  // MARK: - Delete

  public func deleteNote(id: String) async throws {
    try await client.deleteNote(
      id: id, lastModified: ISO8601DateFormatter.noteISO8601.string(from: Date()))
  }

  // MARK: - Private

  private func push(_ note: Note) async throws {
    let encrypted = try await encryptor.encryptNotes([note])
    _ = try await client.pushNotes(
      encrypted, idOverrides: [:], lastModifiedByRemoteId: [:])
  }
}
