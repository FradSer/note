import AppleSyncKit
import Foundation
import NoteModels

// MARK: - Sync Config Store

/// Thin wrapper over `AppleSyncKit.ConfigStore` configured for note's namespace
/// (`note-sync` / `NOTE`). Preserves the static API the commands rely on and
/// keeps the concrete state types (`SyncState`/`SyncCursors`/`SyncIdMapping`) so
/// the on-disk JSON shape is unchanged.
public enum SyncConfigStore {
  public static let store = ConfigStore(namespace: "note-sync", prefix: "NOTE")

  public enum EnvKey {
    public static let apiURL = "NOTE_SYNC_API_URL"
    public static let apiToken = "NOTE_SYNC_API_TOKEN"
    public static let deviceId = "NOTE_SYNC_DEVICE_ID"
  }

  public static var configPath: String { store.configPath }

  public static func acquireLock() throws -> Int32 { try store.acquireLock() }
  public static func releaseLock(_ fd: Int32) { store.releaseLock(fd) }
  public static func validateAPIURL(_ apiURL: String) throws { try store.validateAPIURL(apiURL) }

  public static func hasEnvironmentConfig(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    store.hasEnvironmentConfig(environment)
  }

  public static func load() throws -> SyncConfig {
    try store.loadConfig(
      notFoundMessage: """
        Sync config not found. Either set the environment variables \
        \(EnvKey.apiURL) and \(EnvKey.apiToken) (and optionally \(EnvKey.deviceId)), \
        or run 'note sync config --api-url <URL> --api-token <TOKEN> --device-id <ID>'.
        """)
  }

  public static func save(_ config: SyncConfig) throws { try store.saveConfig(config) }

  public static func loadCursors() -> SyncCursors {
    store.loadJSON(from: store.cursorsPath, default: SyncCursors())
  }
  public static func saveCursors(_ cursors: SyncCursors) throws {
    try store.saveJSON(cursors, to: store.cursorsPath)
  }
  public static func loadIdMapping() throws -> SyncIdMapping {
    try store.loadJSONStrict(from: store.idMappingPath, default: SyncIdMapping())
  }
  public static func saveIdMapping(_ mapping: SyncIdMapping) throws {
    try store.saveJSON(mapping, to: store.idMappingPath)
  }
  public static func loadState() throws -> SyncState {
    try store.loadJSONStrict(from: store.statePath, default: SyncState())
  }
  public static func saveState(_ state: SyncState) throws {
    try store.saveJSON(state, to: store.statePath)
  }
}

// MARK: - Engine Wiring

/// Cross-cutting values the shared `SyncEngine` needs, shared by the macOS
/// `SyncService` and the Linux `LinuxSyncService`.
public enum NoteSyncRules {
  /// Recognizes a "not found" thrown by either note's domain layer or the kit.
  public static let isNotFound: @Sendable (Error) -> Bool = { error in
    (error as? SyncNotFound)?.isNotFound ?? false
  }
}
