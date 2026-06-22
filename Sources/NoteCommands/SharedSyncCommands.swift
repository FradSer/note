import AppleSyncKit
import ArgumentParser
import Foundation
import NoteModels
import NoteSync

// MARK: - Shared Sync Subcommands

public struct SyncConfigCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Configure sync settings"
  )

  @Option(help: "Cloudflare Worker API URL")
  public var apiUrl: String

  @Option(help: "API Bearer token")
  public var apiToken: String

  @Option(help: "Device identifier (default: system hostname)")
  public var deviceId: String?

  public init() {}

  public func run() async throws {
    let resolvedDeviceId = deviceId ?? ProcessInfo.processInfo.hostName
    let config = SyncConfig(apiURL: apiUrl, apiToken: apiToken, deviceId: resolvedDeviceId)
    try SyncConfigStore.save(config)
    print("Sync config saved to \(SyncConfigStore.configPath)")
  }
}

public struct SyncStatusCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show sync configuration and cursor state"
  )

  public init() {}

  public func run() async throws {
    let config = try SyncConfigStore.load()
    let cursors = SyncConfigStore.loadCursors()

    let source =
      SyncConfigStore.hasEnvironmentConfig()
      ? "environment variables" : SyncConfigStore.configPath
    let hasKey = (ProcessInfo.processInfo.environment["NOTE_ENCRYPTION_KEY"] ?? "").isEmpty == false

    print("Config source: \(source)")
    print("API URL: \(config.apiURL)")
    print("Device ID: \(config.deviceId)")
    print("Token: \(String(config.apiToken.prefix(4)))...")
    print("Encryption key (NOTE_ENCRYPTION_KEY): \(hasKey ? "set" : "NOT set")")
    print("")
    print("Last sync cursors:")
    print("  Notes:   \(cursors.notes ?? "never")")
    print("  Folders: \(cursors.noteFolders ?? "never")")
  }
}
