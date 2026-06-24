import Foundation

// MARK: - Sync Exclusions

/// Folder-name blacklist for sync. Notes (and the folders themselves) whose
/// folder name matches an entry are never pushed to Cloudflare D1; any copy
/// already on the server is purged on the next push, while the local copy is
/// shielded from the resulting delete tombstone on pull. Persisted plaintext in
/// `~/.config/note-sync/exclude.json` and/or merged from the
/// `NOTE_SYNC_EXCLUDE_FOLDERS` environment variable.
public struct SyncExclusions: Codable, Sendable, Equatable {
  public var folders: [String]

  public init(folders: [String] = []) {
    self.folders = folders
  }
}

// MARK: - Folder Blacklist

/// Case-insensitive, whitespace-trimmed matcher over a set of excluded folder
/// names. Built once per sync run and consulted on both push (filter out) and
/// pull (skip + protect the local copy).
public struct FolderBlacklist: Sendable {
  private let normalized: Set<String>

  public init(folders: [String]) {
    self.normalized = Set(folders.map(Self.normalize).filter { !$0.isEmpty })
  }

  public var isEmpty: Bool { normalized.isEmpty }

  public func contains(_ folderName: String) -> Bool {
    normalized.contains(Self.normalize(folderName))
  }

  private static func normalize(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
