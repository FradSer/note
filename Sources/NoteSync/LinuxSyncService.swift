import Foundation
import NoteModels
import SQLite

// MARK: - Linux Sync Service

/// Sync service for non-macOS platforms (Linux, etc.) that uses SQLite as the
/// local data store. Mirrors the macOS `SyncService` pattern but operates on
/// SQLite.swift records instead of Apple Notes. Note bodies are end-to-end
/// encrypted on push and decrypted on pull, so the local store always holds
/// plaintext Markdown.
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
      throw EncryptionError.keyNotConfigured
    }
    return encryptor
  }

  // MARK: - Push

  public func pushNotes() async throws -> PushResult {
    let encryptor = try requireEncryptor()
    let allItems: [Note] = try await fetchNonDeleted(from: "notes")
    let localOnlyItems: [Note] = try await fetchLocalOnly(from: "notes")
    let deletedRecords = try await fetchDeletedRecords(from: "notes")

    return try await pushEntities(
      allItems: allItems,
      localOnlyItems: localOnlyItems,
      deletedRecords: deletedRecords,
      getId: { $0.id },
      getMapping: { $0.notes },
      removeMapping: { $0.notes.removeValue(forKey: $1) },
      getEntityState: { $0.notes },
      setEntityState: { $0.notes = $1 },
      deletionCandidates: { $0.deletionCandidates(currentRemoteIds: $1) },
      push: {
        let encrypted = try await encryptor.encryptNotes($0)
        return try await self.syncClient.pushNotes(
          encrypted, idOverrides: $1, lastModifiedByRemoteId: $2)
      },
      delete: { try await self.syncClient.deleteNote(id: $0, lastModified: $1) },
      tableName: "notes"
    )
  }

  public func pushFolders() async throws -> PushResult {
    let allItems: [NoteFolder] = try await fetchNonDeleted(from: "note_folders")
    let localOnlyItems: [NoteFolder] = try await fetchLocalOnly(from: "note_folders")
    let deletedRecords = try await fetchDeletedRecords(from: "note_folders")

    return try await pushEntities(
      allItems: allItems,
      localOnlyItems: localOnlyItems,
      deletedRecords: deletedRecords,
      getId: { $0.id },
      getMapping: { $0.noteFolders },
      removeMapping: { $0.noteFolders.removeValue(forKey: $1) },
      getEntityState: { $0.noteFolders },
      setEntityState: { $0.noteFolders = $1 },
      deletionCandidates: { $0.deletionCandidates(currentRemoteIds: $1) },
      push: {
        try await self.syncClient.pushFolders(
          $0, idOverrides: $1, lastModifiedByRemoteId: $2)
      },
      delete: { try await self.syncClient.deleteFolder(id: $0, lastModified: $1) },
      tableName: "note_folders"
    )
  }

  // MARK: - Generic Push

  /// Pushes locally modified items, records their synced state, then soft-deletes
  /// remote IDs no longer present locally. The `is_local_only` flag replaces the
  /// snapshot comparison used by the macOS SyncService: items flagged as local-only
  /// are always pushed. Deletions are driven by the `deleted` column plus the
  /// state-based `deletionCandidates` safety net.
  private func pushEntities<E: Encodable & Sendable>(
    allItems: [E],
    localOnlyItems: [E],
    deletedRecords: [DeletedRecord],
    getId: (E) -> String,
    getMapping: (SyncIdMapping) -> [String: String],
    removeMapping: (inout SyncIdMapping, String) -> Void,
    getEntityState: (SyncState) -> SyncEntityState,
    setEntityState: (inout SyncState, SyncEntityState) -> Void,
    deletionCandidates: (SyncEntityState, Set<String>) -> [String],
    push: ([E], [String: String], [String: String]) async throws -> PushResult,
    delete: (String, String?) async throws -> Void,
    tableName: String
  ) async throws -> PushResult {
    var seenIds = Set<String>()
    var uniqueItems = [E]()
    for item in allItems {
      let id = getId(item)
      if !seenIds.contains(id) {
        seenIds.insert(id)
        uniqueItems.append(item)
      }
    }

    var localOnlySeen = Set<String>()
    var uniqueLocalOnly = [E]()
    for item in localOnlyItems {
      let id = getId(item)
      if !localOnlySeen.contains(id) {
        localOnlySeen.insert(id)
        uniqueLocalOnly.append(item)
      }
    }

    var idMapping = try SyncConfigStore.loadIdMapping()
    var state = try SyncConfigStore.loadState()
    var entityState = getEntityState(state)
    let localToRemote = invertMapping(getMapping(idMapping))

    let currentRemoteIds = SyncPushHelpers.currentRemoteIds(
      items: uniqueItems,
      getId: getId,
      localToRemote: localToRemote
    )

    var deletedRemoteIds = deletionCandidates(entityState, currentRemoteIds)
    for record in deletedRecords {
      let remoteId = localToRemote[record.id] ?? record.id
      if !deletedRemoteIds.contains(remoteId) {
        deletedRemoteIds.append(remoteId)
      }
    }

    let fallbackLastModified = ISO8601DateFormatter.noteISO8601.string(from: Date())
    var lastModifiedByRemoteId = [String: String]()
    for item in uniqueLocalOnly {
      let remoteId = localToRemote[getId(item)] ?? getId(item)
      lastModifiedByRemoteId[remoteId] = fallbackLastModified
    }

    let result = try await push(uniqueLocalOnly, localToRemote, lastModifiedByRemoteId)

    for item in uniqueLocalOnly {
      let remoteId = localToRemote[getId(item)] ?? getId(item)
      if let lastModified = lastModifiedByRemoteId[remoteId] {
        try entityState.recordSyncedValue(item, remoteId: remoteId, lastModified: lastModified)
      }
    }
    setEntityState(&state, entityState)
    try SyncConfigStore.saveState(state)

    let pushedLocalIds = uniqueLocalOnly.map { getId($0) }
    if !pushedLocalIds.isEmpty {
      try await clearLocalOnly(table: tableName, ids: pushedLocalIds)
    }

    guard !deletedRemoteIds.isEmpty else { return result }

    for remoteId in deletedRemoteIds {
      try await delete(remoteId, entityState.lastModifiedByRemoteId[remoteId])
      let localId = getMapping(idMapping)[remoteId] ?? remoteId
      removeMapping(&idMapping, remoteId)
      entityState.removeRemoteId(remoteId)
      setEntityState(&state, entityState)
      try SyncConfigStore.saveIdMapping(idMapping)
      try SyncConfigStore.saveState(state)
      try await removeRecord(table: tableName, id: localId)
    }

    return result
  }

  // MARK: - Pull

  public func pullNotes() async throws -> PullSummary {
    let encryptor = try requireEncryptor()
    let localNotes: [Note] = try await fetchNonDeleted(from: "notes")
    let localLastModified = lastModifiedIndex(
      localNotes.map {
        (id: $0.id, lastModified: $0.modifiedDate, creationDate: $0.creationDate)
      })
    let localIds = Set(localNotes.map(\.id))

    return try await pullEntities(
      entityName: "notes",
      tableName: "notes",
      localLastModifiedById: localLastModified,
      localIdsWithoutTimestamp: localIds.subtracting(Set(localLastModified.keys)),
      pull: { cursor in
        let response = try await self.syncClient.pullNotes(cursor: cursor)
        return try await encryptor.decryptResponse(response)
      },
      getCursor: { $0.notes },
      setCursor: { $0.notes = $1 },
      getMapping: { $0.notes },
      setMapping: { mapping, key, value in
        if let value {
          mapping.notes[key] = value
        } else {
          mapping.notes.removeValue(forKey: key)
        }
      },
      getEntityState: { $0.notes },
      setEntityState: { $0.notes = $1 }
    )
  }

  public func pullFolders() async throws -> PullSummary {
    // Folders carry no modification timestamp, so the pull always applies the
    // server value (an empty conflict index disables the guard).
    return try await pullEntities(
      entityName: "folders",
      tableName: "note_folders",
      localLastModifiedById: [:],
      localIdsWithoutTimestamp: [],
      pull: { cursor in try await self.syncClient.pullFolders(cursor: cursor) },
      getCursor: { $0.noteFolders },
      setCursor: { $0.noteFolders = $1 },
      getMapping: { $0.noteFolders },
      setMapping: { mapping, key, value in
        if let value {
          mapping.noteFolders[key] = value
        } else {
          mapping.noteFolders.removeValue(forKey: key)
        }
      },
      getEntityState: { $0.noteFolders },
      setEntityState: { $0.noteFolders = $1 }
    )
  }

  // MARK: - Generic Pull Loop

  private func pullEntities<T: Codable & Sendable>(
    entityName: String,
    tableName: String,
    localLastModifiedById: [String: String],
    localIdsWithoutTimestamp: Set<String>,
    pull: (String?) async throws -> PullResponse<T>,
    getCursor: (SyncCursors) -> String?,
    setCursor: (inout SyncCursors, String?) -> Void,
    getMapping: (SyncIdMapping) -> [String: String],
    setMapping: (inout SyncIdMapping, String, String?) -> Void,
    getEntityState: (SyncState) -> SyncEntityState,
    setEntityState: (inout SyncState, SyncEntityState) -> Void
  ) async throws -> PullSummary {
    var cursors = SyncConfigStore.loadCursors()
    var idMapping = try SyncConfigStore.loadIdMapping()
    var state = try SyncConfigStore.loadState()
    var entityState = getEntityState(state)
    var pulled = 0
    var deleted = 0
    var skipped = 0
    var hasMore = true

    func persist() throws {
      setEntityState(&state, entityState)
      try SyncConfigStore.saveCursors(cursors)
      try SyncConfigStore.saveIdMapping(idMapping)
      try SyncConfigStore.saveState(state)
    }

    while hasMore {
      let response: PullResponse<T>
      do {
        response = try await pull(getCursor(cursors))
      } catch {
        try? persist()
        throw error
      }
      hasMore = response.hasMore
      var hadFailures = false

      for item in response.items {
        let localId = getMapping(idMapping)[item.id] ?? item.id

        if item.deleted {
          do {
            try await hardDeleteRecord(table: tableName, id: localId)
          } catch let error as NoteCLIError where isNotFoundError(error) {
            // Already gone locally, clean up mapping.
          } catch {
            fputs("Warning: Could not delete \(entityName) \(item.id): \(error)\n", stderr)
            hadFailures = true
            continue
          }
          setMapping(&idMapping, item.id, nil)
          entityState.removeRemoteId(item.id)
          deleted += 1
          continue
        }

        if localIdsWithoutTimestamp.contains(localId) {
          fputs(
            "Skipped \(entityName) \(item.id): local copy has no timestamp for conflict comparison\n",
            stderr)
          skipped += 1
          continue
        }

        if let localValue = localLastModifiedById[localId],
          let localModified = SyncTimestamp.parse(localValue),
          let serverModified = SyncTimestamp.parse(item.lastModified),
          localModified > serverModified
        {
          fputs(
            "Skipped \(entityName) \(item.id): local copy is newer; it will be pushed on next sync\n",
            stderr)
          skipped += 1
          continue
        }

        do {
          try await upsertRecord(
            table: tableName,
            id: localId,
            data: item.data,
            lastModified: item.lastModified
          )
          if getMapping(idMapping)[item.id] == nil {
            setMapping(&idMapping, item.id, localId)
          }
          try entityState.recordSyncedValue(
            item.data, remoteId: item.id, lastModified: item.lastModified)
          pulled += 1
        } catch {
          fputs("Warning: Could not sync \(entityName) \(item.id): \(error)\n", stderr)
          hadFailures = true
        }
      }

      setCursor(
        &cursors,
        SyncCursorPolicy.nextCursor(
          currentCursor: getCursor(cursors),
          responseCursor: response.cursor,
          hadFailures: hadFailures
        )
      )
      try persist()

      if hadFailures {
        throw NoteCLIError.unknown(
          "Pull \(entityName) failed for one or more items. Cursor was not advanced."
        )
      }
    }

    return PullSummary(pulled: pulled, deleted: deleted, skipped: skipped)
  }

  // MARK: - SQLite Fetch Helpers

  private func fetchNonDeleted<T: Codable>(from table: String) async throws -> [T] {
    let sql = "SELECT data FROM \(table) WHERE deleted = 0"
    return try connection.prepare(sql).map { row in
      try Self.decode(T.self, from: row[0], table: table)
    }
  }

  private func fetchLocalOnly<T: Codable>(from table: String) async throws -> [T] {
    let sql = "SELECT data FROM \(table) WHERE is_local_only = 1 AND deleted = 0"
    return try connection.prepare(sql).map { row in
      try Self.decode(T.self, from: row[0], table: table)
    }
  }

  private func fetchDeletedRecords(from table: String) async throws -> [DeletedRecord] {
    let sql = "SELECT id, last_modified FROM \(table) WHERE deleted = 1"
    return try connection.prepare(sql).map { row in
      DeletedRecord(id: row[0] as! String, lastModified: row[1] as! String)
    }
  }

  private static func decode<T: Codable>(
    _ type: T.Type, from value: Binding?, table: String
  ) throws -> T {
    guard let jsonString = value as? String,
      let jsonData = jsonString.data(using: .utf8)
    else {
      throw NoteCLIError.unknown("Failed to decode record data from \(table)")
    }
    return try JSONDecoder().decode(T.self, from: jsonData)
  }

  // MARK: - SQLite Write Helpers

  private func clearLocalOnly(table: String, ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
    let sql = "UPDATE \(table) SET is_local_only = 0 WHERE id IN (\(placeholders))"
    try connection.run(sql, ids.map { $0 as Binding? })
  }

  private func removeRecord(table: String, id: String) async throws {
    try connection.run("DELETE FROM \(table) WHERE id = ?", id)
    if connection.changes == 0 {
      throw NoteCLIError.notFound("Record with ID '\(id)' not found in \(table)")
    }
  }

  private func hardDeleteRecord(table: String, id: String) async throws {
    try connection.run("DELETE FROM \(table) WHERE id = ?", id)
  }

  private func upsertRecord<T: Encodable>(
    table: String,
    id: String,
    data: T,
    lastModified: String
  ) async throws {
    let jsonData = try JSONEncoder().encode(data)
    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
      throw NoteCLIError.unknown("Failed to encode record data for \(table)")
    }

    let sql = """
      INSERT INTO \(table) (id, data, last_modified, deleted, is_local_only)
      VALUES (?, ?, ?, 0, 0)
      ON CONFLICT(id) DO UPDATE SET
        data = excluded.data,
        last_modified = excluded.last_modified,
        deleted = 0,
        is_local_only = 0,
        updated_at = datetime('now')
      """
    try connection.run(sql, id, jsonString, lastModified)
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

  private nonisolated func isNotFoundError(_ error: NoteCLIError) -> Bool {
    if case .notFound = error {
      return true
    }
    return false
  }

  private nonisolated func invertMapping(_ mapping: [String: String]) -> [String: String] {
    let result = SyncIdMapping.inverted(mapping)
    for collision in result.collisions {
      fputs(
        "Warning: duplicate ID mapping -- local '\(collision.localId)' maps to both "
          + "'\(collision.keptRemoteId)' and '\(collision.droppedRemoteId)'\n",
        stderr)
    }
    return result.mapping
  }
}

// MARK: - Deleted Record

private struct DeletedRecord: Sendable {
  let id: String
  let lastModified: String
}
