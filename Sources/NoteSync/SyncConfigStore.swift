import Foundation
import NoteModels

// MARK: - Sync Config Store

public enum SyncConfigStore {
  private static var baseDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config")
      .appendingPathComponent("note-sync")
  }

  /// Acquire an exclusive, non-blocking file lock to prevent concurrent sync operations.
  /// Returns the file descriptor. Call `releaseLock(_:)` when done.
  public static func acquireLock() throws -> Int32 {
    let dir = baseDirectory
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lockPath = dir.appendingPathComponent(".lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else {
      throw NoteCLIError.unknown("Could not create sync lock file")
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw NoteCLIError.unknown("Another sync operation is already running")
    }
    return fd
  }

  public static func releaseLock(_ fd: Int32) {
    flock(fd, LOCK_UN)
    close(fd)
  }

  public static var configPath: String {
    baseDirectory.appendingPathComponent("config.json").path
  }

  public static var cursorsPath: String {
    baseDirectory.appendingPathComponent("cursors.json").path
  }

  public static var idMappingPath: String {
    baseDirectory.appendingPathComponent("id-mapping.json").path
  }

  public static var statePath: String {
    baseDirectory.appendingPathComponent("state.json").path
  }

  // MARK: - Config

  /// Environment variable names for sync configuration.
  public enum EnvKey {
    public static let apiURL = "NOTE_SYNC_API_URL"
    public static let apiToken = "NOTE_SYNC_API_TOKEN"
    public static let deviceId = "NOTE_SYNC_DEVICE_ID"
  }

  /// Validates that an API URL uses HTTPS.
  public static func validateAPIURL(_ apiURL: String) throws {
    guard apiURL.lowercased().hasPrefix("https://") else {
      throw NoteCLIError.invalidInput("API URL must use HTTPS. Got: \(apiURL)")
    }
  }

  /// Builds a `SyncConfig` from environment variables. Returns `nil` when neither
  /// required variable is set, so the caller can fall back to the config file.
  /// Throws when exactly one required variable is set, or the URL is not HTTPS.
  static func loadFromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> SyncConfig? {
    func value(_ key: String) -> String? {
      guard let raw = environment[key], !raw.isEmpty else { return nil }
      return raw
    }

    switch (value(EnvKey.apiURL), value(EnvKey.apiToken)) {
    case (nil, nil):
      return nil
    case (let apiURL?, let apiToken?):
      try validateAPIURL(apiURL)
      let deviceId = value(EnvKey.deviceId) ?? ProcessInfo.processInfo.hostName
      return SyncConfig(apiURL: apiURL, apiToken: apiToken, deviceId: deviceId)
    default:
      throw NoteCLIError.invalidInput(
        "Both \(EnvKey.apiURL) and \(EnvKey.apiToken) must be set to use "
          + "environment-based sync config.")
    }
  }

  /// Whether both required environment variables are set.
  public static func hasEnvironmentConfig(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    func isSet(_ key: String) -> Bool { !(environment[key] ?? "").isEmpty }
    return isSet(EnvKey.apiURL) && isSet(EnvKey.apiToken)
  }

  /// Loads the sync config: environment variables take precedence, then the
  /// config file written by `note sync config`.
  public static func load() throws -> SyncConfig {
    if let envConfig = try loadFromEnvironment() {
      return envConfig
    }
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: configPath))
    } catch {
      throw NoteCLIError.notFound(
        """
        Sync config not found. Either set the environment variables \
        \(EnvKey.apiURL) and \(EnvKey.apiToken) (and optionally \(EnvKey.deviceId)), \
        or run 'note sync config --api-url <URL> --api-token <TOKEN> --device-id <ID>'.
        """
      )
    }
    let config = try JSONDecoder().decode(SyncConfig.self, from: data)
    try validateAPIURL(config.apiURL)
    return config
  }

  /// Loads config from a specific path. Used by tests and `load()`.
  public static func loadConfig(from path: String) throws -> SyncConfig {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let config = try JSONDecoder().decode(SyncConfig.self, from: data)
    try validateAPIURL(config.apiURL)
    return config
  }

  public static func save(_ config: SyncConfig) throws {
    try validateAPIURL(config.apiURL)
    try saveJSON(config, to: configPath)
  }

  // MARK: - Cursors

  public static func loadCursors() -> SyncCursors {
    loadJSON(from: cursorsPath, default: SyncCursors())
  }

  public static func saveCursors(_ cursors: SyncCursors) throws {
    try saveJSON(cursors, to: cursorsPath)
  }

  // MARK: - ID Mapping

  public static func loadIdMapping() throws -> SyncIdMapping {
    try loadJSONStrict(from: idMappingPath, default: SyncIdMapping())
  }

  /// Loads ID mapping from a specific path. Used by tests.
  public static func loadIdMapping(from path: String) throws -> SyncIdMapping {
    try loadJSONStrict(from: path, default: SyncIdMapping())
  }

  public static func saveIdMapping(_ mapping: SyncIdMapping) throws {
    try saveJSON(mapping, to: idMappingPath)
  }

  // MARK: - State

  public static func loadState() throws -> SyncState {
    try loadJSONStrict(from: statePath, default: SyncState())
  }

  /// Loads sync state from a specific path. Used by tests.
  public static func loadState(from path: String) throws -> SyncState {
    try loadJSONStrict(from: path, default: SyncState())
  }

  public static func saveState(_ state: SyncState) throws {
    try saveJSON(state, to: statePath)
  }

  // MARK: - Private Helpers

  /// Wraps the current `errno` in a `NoteCLIError`. The default argument captures
  /// `errno` at the call site, before any later call can clobber it.
  private static func posixError(_ context: String, _ code: Int32 = errno) -> NoteCLIError {
    NoteCLIError.unknown("\(context): \(String(cString: strerror(code)))")
  }

  /// Writes JSON to `path` via a 0o600 temp file plus atomic rename, so the token
  /// is never momentarily readable at the default umask the way a plain
  /// write-then-chmod would leave it.
  static func saveJSON<T: Encodable>(_ value: T, to path: String) throws {
    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(value)
    let tempPath = path + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
    let fd = open(tempPath, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
    guard fd >= 0 else {
      throw posixError("Cannot create \(tempPath)")
    }
    do {
      try data.withUnsafeBytes { bytes in
        var written = 0
        while written < bytes.count {
          let n = write(fd, bytes.baseAddress! + written, bytes.count - written)
          guard n > 0 else {
            throw posixError("Write failed")
          }
          written += n
        }
      }
    } catch {
      close(fd)
      try? FileManager.default.removeItem(atPath: tempPath)
      throw error
    }
    close(fd)
    guard rename(tempPath, path) == 0 else {
      let error = posixError("Cannot save \(path)")
      try? FileManager.default.removeItem(atPath: tempPath)
      throw error
    }
  }

  private static func loadJSON<T: Decodable>(from path: String, default defaultValue: T) -> T {
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      return defaultValue
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      fputs("Warning: Could not parse \(path): \(error.localizedDescription)\n", stderr)
      return defaultValue
    }
  }

  /// Returns the default when the file is missing; throws on parse errors.
  private static func loadJSONStrict<T: Decodable>(
    from path: String,
    default defaultValue: T
  ) throws -> T {
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      return defaultValue
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw NoteCLIError.unknown(
        "Could not parse \(path): \(error.localizedDescription). "
          + "Repair or remove the file before syncing again."
      )
    }
  }
}
