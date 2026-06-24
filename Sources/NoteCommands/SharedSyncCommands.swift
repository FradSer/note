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

// MARK: - Exclude (Blacklist)

public struct SyncExcludeCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "exclude",
    abstract: "Manage folders excluded from sync (blacklist)",
    discussion: """
      Notes in an excluded folder are never pushed to Cloudflare D1; any copy \
      already on the server is purged on the next push, while the local copy is \
      kept. Matching is case-insensitive on the folder name. Entries are stored \
      in exclude.json next to the sync config; the NOTE_SYNC_EXCLUDE_FOLDERS \
      environment variable (comma- or newline-separated) is merged on top.
      """,
    subcommands: [List.self, Add.self, Remove.self],
    defaultSubcommand: List.self
  )

  public init() {}

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List excluded folders")

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let effective = SyncExclusionStore.load()
      if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(effective), let str = String(data: data, encoding: .utf8)
        {
          print(str)
        }
      } else if effective.folders.isEmpty {
        print("No excluded folders.")
      } else {
        print("Excluded folders:")
        for folder in effective.folders { print("  \(folder)") }
      }
    }
  }

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Exclude a folder from sync (persists to exclude.json)")

    @Argument(help: "Folder name to exclude")
    var folder: String

    func run() async throws {
      var exclusions = SyncExclusionStore.fileExclusions()
      guard FolderBlacklist(folders: exclusions.folders).contains(folder) == false else {
        print("Already excluded: \(folder)")
        return
      }
      exclusions.folders.append(folder)
      try SyncExclusionStore.save(exclusions)
      print("Excluded folder: \(folder)")
      print("Saved to \(SyncExclusionStore.excludePath)")
      print(
        "Note: set the same exclusion on every device — a device that has not "
          + "excluded this folder will re-sync it.")
    }
  }

  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Stop excluding a folder (removes it from exclude.json)")

    @Argument(help: "Folder name to remove from the blacklist")
    var folder: String

    func run() async throws {
      let target = folder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      var exclusions = SyncExclusionStore.fileExclusions()
      let before = exclusions.folders.count
      exclusions.folders.removeAll {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
      }
      guard exclusions.folders.count < before else {
        print("Folder not in exclude.json: \(folder)")
        return
      }
      try SyncExclusionStore.save(exclusions)
      print("Removed excluded folder: \(folder)")
    }
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
    let excluded = SyncExclusionStore.load().folders

    print("Config source: \(source)")
    print("API URL: \(config.apiURL)")
    print("Device ID: \(config.deviceId)")
    print("Token: \(String(config.apiToken.prefix(4)))...")
    print("Encryption key (NOTE_ENCRYPTION_KEY): \(hasKey ? "set" : "NOT set")")
    print("Excluded folders: \(excluded.isEmpty ? "none" : excluded.joined(separator: ", "))")
    print("")
    print("Last sync cursors:")
    print("  Notes:   \(cursors.notes ?? "never")")
    print("  Folders: \(cursors.noteFolders ?? "never")")
  }
}
