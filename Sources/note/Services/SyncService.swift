#if os(macOS)

  import Foundation
  import NoteModels
  import NoteSync

  // MARK: - Sync Service (macOS)

  /// Bidirectional sync between local Apple Notes (via AppleScript) and Cloudflare
  /// D1. Note bodies are end-to-end encrypted on push and decrypted on pull, so
  /// the Worker only ever stores ciphertext. Mirrors the Linux service but reads
  /// and writes Apple Notes instead of SQLite.
  actor SyncService: SyncServiceProtocol {
    private let notesService = NotesService()
    private let folderService = FolderService()
    private let syncClient: D1SyncClient
    private let encryptor: NoteEncryptor?

    init(config: SyncConfig, encryptor: NoteEncryptor?) {
      self.syncClient = D1SyncClient(config: config)
      self.encryptor = encryptor
    }

    func shutdown() async throws {
      try await syncClient.shutdown()
    }

    private func requireEncryptor() throws -> NoteEncryptor {
      guard let encryptor else {
        throw EncryptionError.keyNotConfigured
      }
      return encryptor
    }

    // MARK: - Push

    func pushNotes() async throws -> PushResult {
      let encryptor = try requireEncryptor()
      let notes = try await notesService.fetchNotes(folderName: nil)
      return try await pushEntities(
        items: notes,
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
        delete: { try await self.syncClient.deleteNote(id: $0, lastModified: $1) }
      )
    }

    func pushFolders() async throws -> PushResult {
      let folders = try await folderService.fetchFolders()
      return try await pushEntities(
        items: folders,
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
        delete: { try await self.syncClient.deleteFolder(id: $0, lastModified: $1) }
      )
    }

    // MARK: - Generic Push

    private func pushEntities<E: Encodable & Sendable>(
      items: [E],
      getId: (E) -> String,
      getMapping: (SyncIdMapping) -> [String: String],
      removeMapping: (inout SyncIdMapping, String) -> Void,
      getEntityState: (SyncState) -> SyncEntityState,
      setEntityState: (inout SyncState, SyncEntityState) -> Void,
      deletionCandidates: (SyncEntityState, Set<String>) -> [String],
      push: ([E], [String: String], [String: String]) async throws -> PushResult,
      delete: (String, String?) async throws -> Void
    ) async throws -> PushResult {
      var seenIds = Set<String>()
      var uniqueItems = [E]()
      for item in items {
        let id = getId(item)
        if !seenIds.contains(id) {
          seenIds.insert(id)
          uniqueItems.append(item)
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
      let deletedRemoteIds = deletionCandidates(entityState, currentRemoteIds)
      let fallbackLastModified = ISO8601DateFormatter.noteISO8601.string(from: Date())
      var itemsToPush = [E]()
      var lastModifiedByRemoteId = [String: String]()

      for item in uniqueItems {
        let remoteId = localToRemote[getId(item)] ?? getId(item)
        let lastModified = try entityState.lastModified(
          for: item, remoteId: remoteId, fallback: fallbackLastModified)

        if lastModified == fallbackLastModified {
          itemsToPush.append(item)
          lastModifiedByRemoteId[remoteId] = lastModified
        }
      }

      let result = try await push(itemsToPush, localToRemote, lastModifiedByRemoteId)

      for item in itemsToPush {
        let remoteId = localToRemote[getId(item)] ?? getId(item)
        if let lastModified = lastModifiedByRemoteId[remoteId] {
          try entityState.recordSyncedValue(item, remoteId: remoteId, lastModified: lastModified)
        }
      }
      setEntityState(&state, entityState)
      try SyncConfigStore.saveState(state)

      guard !deletedRemoteIds.isEmpty else { return result }

      for remoteId in deletedRemoteIds {
        try await delete(remoteId, entityState.lastModifiedByRemoteId[remoteId])
        removeMapping(&idMapping, remoteId)
        entityState.removeRemoteId(remoteId)
        setEntityState(&state, entityState)
        try SyncConfigStore.saveIdMapping(idMapping)
        try SyncConfigStore.saveState(state)
      }
      return result
    }

    // MARK: - Pull

    func pullNotes() async throws -> PullSummary {
      let encryptor = try requireEncryptor()
      let localNotes = try await notesService.fetchNotes(folderName: nil)
      let localLastModified = lastModifiedIndex(
        localNotes.map {
          (id: $0.id, lastModified: $0.modifiedDate, creationDate: $0.creationDate)
        })
      let localIds = Set(localNotes.map(\.id))

      return try await pullEntities(
        entityName: "notes",
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
        setEntityState: { $0.notes = $1 },
        applyDelete: { localId in
          try await self.notesService.deleteNote(id: localId)
        },
        applyUpsert: { localId, item in
          do {
            _ = try await self.notesService.updateNote(
              id: localId, params: UpdateNoteParams(body: item.data.body))
            return nil
          } catch let error as NoteCLIError where self.isNotFoundError(error) {
            try await self.ensureFolderExists(named: item.data.folder)
            let created = try await self.notesService.createNote(
              CreateNoteParams(title: "", body: item.data.body, folderName: item.data.folder))
            return created.id
          }
        }
      )
    }

    func pullFolders() async throws -> PullSummary {
      try await pullEntities(
        entityName: "folders",
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
        setEntityState: { $0.noteFolders = $1 },
        applyDelete: { localId in
          let folders = try await self.folderService.fetchFolders()
          guard let folder = folders.first(where: { $0.id == localId }) else {
            throw NoteCLIError.notFound("Folder \(localId) not found")
          }
          try await self.folderService.deleteFolder(name: folder.name)
        },
        applyUpsert: { localId, item in
          let folders = try await self.folderService.fetchFolders()
          if let existing = folders.first(where: { $0.name == item.data.name }) {
            return existing.id == localId ? nil : existing.id
          }
          let created = try await self.folderService.createFolder(name: item.data.name)
          return created.id
        }
      )
    }

    // MARK: - Generic Pull Loop

    private func pullEntities<T: Codable & Sendable>(
      entityName: String,
      localLastModifiedById: [String: String],
      localIdsWithoutTimestamp: Set<String>,
      pull: (String?) async throws -> PullResponse<T>,
      getCursor: (SyncCursors) -> String?,
      setCursor: (inout SyncCursors, String?) -> Void,
      getMapping: (SyncIdMapping) -> [String: String],
      setMapping: (inout SyncIdMapping, String, String?) -> Void,
      getEntityState: (SyncState) -> SyncEntityState,
      setEntityState: (inout SyncState, SyncEntityState) -> Void,
      applyDelete: (String) async throws -> Void,
      applyUpsert: (String, PullItem<T>) async throws -> String?
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
              try await applyDelete(localId)
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
            let newLocalId = try await applyUpsert(localId, item)
            if let newLocalId {
              setMapping(&idMapping, item.id, newLocalId)
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

    private func ensureFolderExists(named folderName: String) async throws {
      let normalized = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty else { return }
      let existing = try await folderService.fetchFolders()
      guard existing.contains(where: { $0.name == normalized }) == false else { return }
      _ = try await folderService.createFolder(name: normalized)
    }

    private func isNotFoundError(_ error: NoteCLIError) -> Bool {
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

#endif
