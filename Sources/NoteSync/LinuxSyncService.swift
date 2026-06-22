import AppleSyncKit
import Foundation
import NoteModels
import SQLite

// MARK: - Linux Sync Service

/// Sync service for non-macOS platforms that uses SQLite as the local store.
/// Delegates the push/pull algorithm to the shared `AppleSyncKit.SyncEngine`
/// (local-only strategy), encrypting note bodies on push and decrypting on pull
/// so the local store always holds plaintext Markdown.
public actor LinuxSyncService: SyncServiceProtocol {
  private let connection: Connection
  private let syncClient: D1SyncClient
  private let encryptor: NoteEncryptor?

  public init(config: SyncConfig, database: SQLiteDatabase, encryptor: NoteEncryptor?) {
    self.connection = database.databaseConnection
    self.syncClient = D1SyncClient(config: config)
    self.encryptor = encryptor
  }

  public func shutdown() async throws {
    try await syncClient.shutdown()
  }

  private func requireEncryptor() throws -> NoteEncryptor {
    guard let encryptor else {
      throw EncryptionError.keyNotConfigured("NOTE_ENCRYPTION_KEY")
    }
    return encryptor
  }

  private var dbStore: SQLiteSyncStore { SQLiteSyncStore(connection: connection) }

  // MARK: - Push

  public func pushNotes() async throws -> PushResult {
    let encryptor = try requireEncryptor()
    let dbStore = self.dbStore
    let allItems: [Note] = try dbStore.fetchNonDeleted(from: "notes")
    let localOnly: [Note] = try dbStore.fetchLocalOnly(from: "notes")
    let deletedRecords = try dbStore.fetchDeletedRecords(from: "notes")

    return try await SyncEngine.pushLocalOnly(
      allItems: allItems, localOnlyItems: localOnly, deletedRecords: deletedRecords,
      getId: { $0.id }, store: SyncConfigStore.store,
      defaultState: SyncState(), stateKeyPath: \.notes,
      defaultMapping: SyncIdMapping(), mappingKeyPath: \.notes,
      volatileKeys: noteSnapshotVolatileKeys,
      deletionCandidates: { $0.deletionCandidates(currentRemoteIds: $1) },
      push: { items, overrides, lastModified in
        let encrypted = try await encryptor.encryptNotes(items)
        return try await self.syncClient.push(
          entity: "notes", items: encrypted, id: { $0.id },
          idOverrides: overrides, lastModifiedByRemoteId: lastModified)
      },
      delete: { try await self.syncClient.delete(entity: "notes", id: $0, lastModified: $1) },
      clearLocalOnly: { try dbStore.clearLocalOnly(table: "notes", ids: $0) },
      removeRecord: { try dbStore.removeRecord(table: "notes", id: $0) })
  }

  public func pushFolders() async throws -> PushResult {
    let dbStore = self.dbStore
    let allItems: [NoteFolder] = try dbStore.fetchNonDeleted(from: "note_folders")
    let localOnly: [NoteFolder] = try dbStore.fetchLocalOnly(from: "note_folders")
    let deletedRecords = try dbStore.fetchDeletedRecords(from: "note_folders")

    return try await SyncEngine.pushLocalOnly(
      allItems: allItems, localOnlyItems: localOnly, deletedRecords: deletedRecords,
      getId: { $0.id }, store: SyncConfigStore.store,
      defaultState: SyncState(), stateKeyPath: \.noteFolders,
      defaultMapping: SyncIdMapping(), mappingKeyPath: \.noteFolders,
      volatileKeys: noteSnapshotVolatileKeys,
      deletionCandidates: { $0.deletionCandidates(currentRemoteIds: $1) },
      push: { items, overrides, lastModified in
        try await self.syncClient.push(
          entity: "note_folders", items: items, id: { $0.id },
          idOverrides: overrides, lastModifiedByRemoteId: lastModified)
      },
      delete: {
        try await self.syncClient.delete(entity: "note_folders", id: $0, lastModified: $1)
      },
      clearLocalOnly: { try dbStore.clearLocalOnly(table: "note_folders", ids: $0) },
      removeRecord: { try dbStore.removeRecord(table: "note_folders", id: $0) })
  }

  // MARK: - Pull

  public func pullNotes() async throws -> PullSummary {
    let encryptor = try requireEncryptor()
    let dbStore = self.dbStore
    let localNotes: [Note] = try dbStore.fetchNonDeleted(from: "notes")
    let localLastModified = lastModifiedIndex(
      localNotes.map { (id: $0.id, lastModified: $0.modifiedDate, creationDate: $0.creationDate) })
    let localIds = Set(localNotes.map(\.id))

    return try await SyncEngine.pull(
      entityName: "notes", store: SyncConfigStore.store,
      defaultState: SyncState(), stateKeyPath: \.notes,
      defaultCursors: SyncCursors(), cursorKeyPath: \.notes,
      defaultMapping: SyncIdMapping(), mappingKeyPath: \.notes,
      volatileKeys: noteSnapshotVolatileKeys,
      localLastModifiedById: localLastModified,
      localIdsWithoutTimestamp: localIds.subtracting(Set(localLastModified.keys)),
      isNotFound: NoteSyncRules.isNotFound,
      pull: { cursor in
        let response: PullResponse<Note> = try await self.syncClient.pull(
          entity: "notes", cursor: cursor)
        return try await encryptor.decryptResponse(response)
      },
      applyDelete: { try dbStore.hardDeleteRecord(table: "notes", id: $0) },
      applyUpsert: { localId, item in
        try dbStore.upsertRecord(
          table: "notes", id: localId, data: item.data, lastModified: item.lastModified)
        return nil
      })
  }

  public func pullFolders() async throws -> PullSummary {
    let dbStore = self.dbStore
    return try await SyncEngine.pull(
      entityName: "folders", store: SyncConfigStore.store,
      defaultState: SyncState(), stateKeyPath: \.noteFolders,
      defaultCursors: SyncCursors(), cursorKeyPath: \.noteFolders,
      defaultMapping: SyncIdMapping(), mappingKeyPath: \.noteFolders,
      volatileKeys: noteSnapshotVolatileKeys,
      localLastModifiedById: [:],
      localIdsWithoutTimestamp: [],
      isNotFound: NoteSyncRules.isNotFound,
      pull: { cursor in
        try await self.syncClient.pull(entity: "note_folders", cursor: cursor)
          as PullResponse<NoteFolder>
      },
      applyDelete: { try dbStore.hardDeleteRecord(table: "note_folders", id: $0) },
      applyUpsert: { localId, item in
        try dbStore.upsertRecord(
          table: "note_folders", id: localId, data: item.data, lastModified: item.lastModified)
        return nil
      })
  }

  // MARK: - Helpers

  private nonisolated func lastModifiedIndex(
    _ pairs: [(id: String, lastModified: String?, creationDate: String?)]
  ) -> [String: String] {
    var index: [String: String] = [:]
    for pair in pairs {
      if let lastModified = pair.lastModified {
        index[pair.id] = lastModified
      } else if let creationDate = pair.creationDate {
        index[pair.id] = creationDate
      }
    }
    return index
  }
}
