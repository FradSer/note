#if os(macOS)

  import AppleSyncKit
  import Foundation
  import NoteModels
  import NoteSync

  // MARK: - Sync Service (macOS)

  /// Bidirectional sync between local Apple Notes (via AppleScript) and Cloudflare
  /// D1, delegating the algorithm to the shared `AppleSyncKit.SyncEngine`
  /// (snapshot strategy). Note bodies are end-to-end encrypted on push and
  /// decrypted on pull, so the Worker only ever stores ciphertext.
  actor SyncService: SyncServiceProtocol {
    private let notesService = NotesService()
    private let folderService = FolderService()
    private let syncClient: D1SyncClient
    private let encryptor: NoteEncryptor?
    private let blacklist: FolderBlacklist

    init(config: SyncConfig, encryptor: NoteEncryptor?) {
      self.syncClient = D1SyncClient(config: config)
      self.encryptor = encryptor
      self.blacklist = SyncExclusionStore.loadBlacklist()
    }

    func shutdown() async throws {
      try await syncClient.shutdown()
    }

    private func requireEncryptor() throws -> NoteEncryptor {
      guard let encryptor else {
        throw EncryptionError.keyNotConfigured("NOTE_ENCRYPTION_KEY")
      }
      return encryptor
    }

    // MARK: - Push

    func pushNotes() async throws -> PushResult {
      let encryptor = try requireEncryptor()
      let notes = try await notesService.fetchNotes(folderName: nil)
        .filter { !blacklist.contains($0.folder) }
      return try await SyncEngine.pushSnapshot(
        items: notes, getId: { $0.id }, store: SyncConfigStore.store,
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
        delete: { try await self.syncClient.delete(entity: "notes", id: $0, lastModified: $1) })
    }

    func pushFolders() async throws -> PushResult {
      let folders = try await folderService.fetchFolders()
        .filter { !blacklist.contains($0.name) }
      return try await SyncEngine.pushSnapshot(
        items: folders, getId: { $0.id }, store: SyncConfigStore.store,
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
        })
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
      let blacklist = self.blacklist

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
          // Excluded-folder notes are dropped here so the engine never records,
          // re-creates, or deletes them locally.
          return try await encryptor.decryptResponse(
            blacklist.filteringPull(response) { $0.folder })
        },
        applyDelete: { try await self.notesService.deleteNote(id: $0) },
        applyUpsert: { localId, item in
          do {
            _ = try await self.notesService.updateNote(
              id: localId, params: UpdateNoteParams(body: item.data.body))
            return nil
          } catch let error as NoteCLIError where error.isNotFound {
            try await self.ensureFolderExists(named: item.data.folder)
            let created = try await self.notesService.createNote(
              CreateNoteParams(title: "", body: item.data.body, folderName: item.data.folder))
            return created.id
          }
        })
    }

    func pullFolders() async throws -> PullSummary {
      let blacklist = self.blacklist
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
          let response: PullResponse<NoteFolder> = try await self.syncClient.pull(
            entity: "note_folders", cursor: cursor)
          return blacklist.filteringPull(response) { $0.name }
        },
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
        })
    }

    // MARK: - Preferences (file as local store)

    func pushPreferences() async throws -> PushResult {
      // File contents only — env overrides (NOTE_PREFERENCES_FOLDERS) are
      // per-shell and must never be pushed to D1.
      let prefs = NotePreferencesStore.filePreferences()
      let snapshot = NotePreferencesSnapshot(id: "default", folders: prefs.folders)
      let isEmpty = prefs.folders.isEmpty
      return try await SyncEngine.pushSnapshot(
        items: [snapshot], getId: { $0.id }, store: SyncConfigStore.store,
        defaultState: SyncState(), stateKeyPath: \.preferences,
        defaultMapping: SyncIdMapping(), mappingKeyPath: \.preferences,
        volatileKeys: preferencesSnapshotVolatileKeys,
        deletionCandidates: { _, _ in
          // Single-row entity. The snapshot always carries id "default" (even
          // when the folders map is empty), so the engine's default
          // "remote id no longer local" logic never fires. An intentionally
          // cleared local map (isEmpty) means the user removed all
          // preferences, so tombstone the remote row — "no preferences"
          // propagates as a delete, not an empty-map upsert that lingers.
          isEmpty ? ["default"] : []
        },
        push: { items, overrides, lastModified in
          try await self.syncClient.push(
            entity: "note_preferences", items: items, id: { $0.id },
            idOverrides: overrides, lastModifiedByRemoteId: lastModified)
        },
        delete: {
          try await self.syncClient.delete(entity: "note_preferences", id: $0, lastModified: $1)
        })
    }

    func pullPreferences() async throws -> PullSummary {
      // Local "last modified" is the file mtime, NOT the last-synced state
      // timestamp — otherwise a local `prefs add` (which bumps mtime but not
      // SyncState) would be overwritten by a stale-but-newer remote.
      let localLastModified: [String: String]
      if let mtime = NotePreferencesStore.fileModificationDate() {
        localLastModified = ["default": ISO8601DateFormatter.syncISO8601.string(from: mtime)]
      } else {
        localLastModified = [:]
      }
      let localIdsWithoutTimestamp: Set<String> =
        localLastModified.isEmpty ? ["default"] : []
      return try await SyncEngine.pull(
        entityName: "preferences", store: SyncConfigStore.store,
        defaultState: SyncState(), stateKeyPath: \.preferences,
        defaultCursors: SyncCursors(), cursorKeyPath: \.preferences,
        defaultMapping: SyncIdMapping(), mappingKeyPath: \.preferences,
        volatileKeys: preferencesSnapshotVolatileKeys,
        localLastModifiedById: localLastModified,
        localIdsWithoutTimestamp: localIdsWithoutTimestamp,
        isNotFound: NoteSyncRules.isNotFound,
        pull: { cursor in
          let response: PullResponse<NotePreferencesSnapshot> = try await self.syncClient.pull(
            entity: "note_preferences", cursor: cursor)
          return response
        },
        applyDelete: { _ in
          // Remote map was soft-deleted -> clear the local file.
          try NotePreferencesStore.save(NotePreferences(folders: [:]))
        },
        applyUpsert: { _, item in
          // LWW at map granularity: replace the whole file with the remote map.
          try NotePreferencesStore.save(NotePreferences(folders: item.data.folders))
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

    private func ensureFolderExists(named folderName: String) async throws {
      let normalized = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty else { return }
      let existing = try await folderService.fetchFolders()
      guard existing.contains(where: { $0.name == normalized }) == false else { return }
      _ = try await folderService.createFolder(name: normalized)
    }
  }

#endif
