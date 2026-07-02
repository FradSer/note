import Foundation

// MARK: - Note Preferences

/// User-defined mapping from a free-form "category" (e.g. "ideas", "work",
/// "invoice") to the Apple Notes folder a note in that category should land in.
/// Persisted plaintext in `~/.config/note-sync/preferences.json` and consulted by
/// `note notes create --category <CAT>` to resolve the destination folder. The
/// category key is matched case-insensitively after trimming; the folder value
/// is used verbatim (Apple Notes folders are case-sensitive on creation).
public struct NotePreferences: Codable, Sendable, Equatable {
  /// Category key -> folder name.
  public var folders: [String: String]

  public init(folders: [String: String] = [:]) {
    self.folders = folders
  }

  /// Returns the folder mapped to `category`, matching the key
  /// case-insensitively and after trimming whitespace. `nil` when unset.
  public func folder(for category: String) -> String? {
    let key = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !key.isEmpty else { return nil }
    return folders.first(where: { $0.key.lowercased() == key })?.value
  }
}

// MARK: - Note Preferences Snapshot (sync carrier)

/// The per-row carrier the sync engine pushes/pulls for preferences. The whole
/// `folders` map syncs as a single D1 row with a fixed id (`"default"`),
/// last-write-wins at map granularity. Stored plaintext in the `note_preferences`
/// table alongside `note_folders` (folder names only, no secrets).
public struct NotePreferencesSnapshot: Codable, Sendable, Equatable {
  /// Always `"default"` — a single row represents the entire preference map.
  public let id: String
  public var folders: [String: String]

  public init(id: String = "default", folders: [String: String]) {
    self.id = id
    self.folders = folders
  }
}

// MARK: - Preferences Snapshot Volatile Keys

/// Fields excluded from the content snapshot used for change detection. The
/// whole `folders` map IS the content; `id` is identity, not content, but the
/// engine strips it via the snapshot encoder regardless. An empty set means any
/// change to any category→folder pair makes the snapshot differ and triggers a
/// push.
public let preferencesSnapshotVolatileKeys: Set<String> = ["id"]
