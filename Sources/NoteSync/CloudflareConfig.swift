import Foundation
import NoteModels

// MARK: - Cloudflare Config

public struct CloudflareConfig: Codable, Sendable, Equatable {
  public let apiURL: String
  public let apiToken: String
  public let deviceId: String

  public init(apiURL: String, apiToken: String, deviceId: String) {
    self.apiURL = apiURL
    self.apiToken = apiToken
    self.deviceId = deviceId
  }

  /// Loads the Cloudflare config from environment variables first, falling back
  /// to `~/.config/note-sync/config.json` when no environment variables are set.
  /// Throws when only one of the two required environment variables is set.
  public static func load() throws -> CloudflareConfig {
    if let envConfig = try loadFromEnvironment() {
      return envConfig
    }
    let path = SyncConfigStore.configPath
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw NoteCLIError.notFound(
        """
        Cloudflare config not found. Either set the environment variables \
        \(SyncConfigStore.EnvKey.apiURL) and \(SyncConfigStore.EnvKey.apiToken) \
        (and optionally \(SyncConfigStore.EnvKey.deviceId)), \
        or run 'note sync config --api-url <URL> --api-token <TOKEN> --device-id <ID>'.
        """
      )
    }
    let config = try JSONDecoder().decode(CloudflareConfig.self, from: data)
    try SyncConfigStore.validateAPIURL(config.apiURL)
    return config
  }

  /// Saves the Cloudflare config to `~/.config/note-sync/config.json` with 0o600
  /// permissions so the API token is not readable by other users.
  public static func save(_ config: CloudflareConfig) throws {
    try SyncConfigStore.validateAPIURL(config.apiURL)
    try SyncConfigStore.saveJSON(config, to: SyncConfigStore.configPath)
  }

  /// Converts to `SyncConfig` for reuse with the existing sync infrastructure.
  public func toSyncConfig() -> SyncConfig {
    SyncConfig(apiURL: apiURL, apiToken: apiToken, deviceId: deviceId)
  }

  // MARK: - Private

  /// Builds a `CloudflareConfig` from environment variables. Returns `nil` when
  /// neither required variable is set, so the caller can fall back to the config
  /// file. Throws when exactly one required variable is set, or the URL is not HTTPS.
  static func loadFromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> CloudflareConfig? {
    func value(_ key: String) -> String? {
      guard let raw = environment[key], !raw.isEmpty else { return nil }
      return raw
    }

    switch (value(SyncConfigStore.EnvKey.apiURL), value(SyncConfigStore.EnvKey.apiToken)) {
    case (nil, nil):
      return nil
    case (let apiURL?, let apiToken?):
      try SyncConfigStore.validateAPIURL(apiURL)
      let deviceId = value(SyncConfigStore.EnvKey.deviceId) ?? ProcessInfo.processInfo.hostName
      return CloudflareConfig(apiURL: apiURL, apiToken: apiToken, deviceId: deviceId)
    default:
      throw NoteCLIError.invalidInput(
        "Both \(SyncConfigStore.EnvKey.apiURL) and \(SyncConfigStore.EnvKey.apiToken) must be set to use "
          + "environment-based Cloudflare config."
      )
    }
  }
}
