import AppleSyncKit
import Foundation
import NoteModels

// MARK: - Sync Exclusion Store

/// Loads and persists the folder blacklist for sync. The effective exclusion
/// set is the union of `~/.config/note-sync/exclude.json` and the
/// `NOTE_SYNC_EXCLUDE_FOLDERS` environment variable (comma- or newline-separated),
/// so a folder listed in either source is excluded. Matching is delegated to
/// `FolderBlacklist` (case-insensitive, whitespace-trimmed).
public enum SyncExclusionStore {
  public static let envKey = "NOTE_SYNC_EXCLUDE_FOLDERS"

  public static var excludePath: String {
    URL(fileURLWithPath: SyncConfigStore.configPath)
      .deletingLastPathComponent()
      .appendingPathComponent("exclude.json").path
  }

  /// The folder names persisted in `exclude.json` only (no environment merge).
  public static func fileExclusions() -> SyncExclusions {
    SyncConfigStore.store.loadJSON(from: excludePath, default: SyncExclusions())
  }

  /// The effective exclusion set: file entries merged with the environment
  /// variable, deduplicated case-insensitively (first spelling wins).
  public static func load(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> SyncExclusions {
    var folders = fileExclusions().folders
    if let raw = environment[envKey] {
      folders.append(contentsOf: parse(raw))
    }
    return SyncExclusions(folders: dedup(folders))
  }

  /// A ready-to-use matcher built from the effective exclusion set.
  public static func loadBlacklist(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> FolderBlacklist {
    FolderBlacklist(folders: load(environment).folders)
  }

  public static func save(_ exclusions: SyncExclusions) throws {
    try SyncConfigStore.store.saveJSON(
      SyncExclusions(folders: dedup(exclusions.folders)), to: excludePath)
  }

  static func parse(_ raw: String) -> [String] {
    raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  static func dedup(_ folders: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for folder in folders {
      let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if seen.insert(trimmed.lowercased()).inserted { result.append(trimmed) }
    }
    return result
  }
}

// MARK: - Pull Filtering

extension FolderBlacklist {
  /// Drops items in an excluded folder from a pull page, preserving the cursor
  /// and `hasMore` so pagination still advances. Filtering at the pull boundary
  /// keeps excluded items entirely invisible to the sync engine: they are never
  /// created locally, never delete a local copy via a tombstone, and -- crucially
  /// -- never recorded as known remote ids. Recording them would make them
  /// deletion candidates on the next push, which would purge them from D1 and
  /// from every other device, even ones that never opted in to the blacklist.
  public func filteringPull<T>(
    _ response: PullResponse<T>, folder: (T) -> String
  ) -> PullResponse<T> {
    guard !isEmpty else { return response }
    let kept = response.items.filter { contains(folder($0.data)) == false }
    guard kept.count != response.items.count else { return response }
    return PullResponse(items: kept, cursor: response.cursor, hasMore: response.hasMore)
  }
}
