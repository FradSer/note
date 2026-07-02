import AppleSyncKit
import Foundation
import NoteModels

// MARK: - Note Preferences Store

/// Loads and persists the user's category-to-folder preferences in
/// `~/.config/note-sync/preferences.json` (mode 0o600, atomic rename via the
/// shared kit helpers), alongside the sync config, exclude list, and cursor
/// state. Preferences sync to D1 as the `note_preferences` entity on `note sync`
/// (the whole map as one row, plaintext, last-write-wins). The
/// `NOTE_PREFERENCES_FOLDERS` environment variable layers per-shell overrides on
/// top at read time (`cat1:Folder1,cat2:Folder2`) — env overrides are local
/// only and are never pushed to D1; the sync layer reads `filePreferences()`.
public enum NotePreferencesStore {
  /// Reuses the sync namespace (`~/.config/note-sync/`) so all local note-cli
  /// config lives in one directory.
  static let store = SyncConfigStore.store

  public static let envKey = "NOTE_PREFERENCES_FOLDERS"

  /// Path to `~/.config/note-sync/preferences.json`.
  public static var preferencesPath: String {
    URL(fileURLWithPath: SyncConfigStore.configPath)
      .deletingLastPathComponent()
      .appendingPathComponent("preferences.json").path
  }

  /// The file's modification date, used by the sync pull's local-newer check so
  /// a local `prefs add` (which bumps mtime) is not overwritten by a stale but
  /// newer-seeming remote. `nil` when the file does not yet exist.
  public static func fileModificationDate() -> Date? {
    let path = preferencesPath
    guard
      let attrs = try? FileManager.default.attributesOfItem(atPath: path),
      let date = attrs[.modificationDate] as? Date
    else { return nil }
    return date
  }

  /// Preferences persisted in `preferences.json` only (no environment merge).
  public static func filePreferences() -> NotePreferences {
    store.loadJSON(from: preferencesPath, default: NotePreferences())
  }

  /// The effective preferences: file entries merged with the environment
  /// override, with environment values winning on key collision
  /// (case-insensitive key match).
  public static func load(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> NotePreferences {
    var merged = filePreferences().folders
    if let raw = environment[envKey] {
      for (key, folder) in parse(raw) {
        _ = setCaseInsensitive(&merged, key: key, folder: folder)
      }
    }
    return NotePreferences(folders: merged)
  }

  public static func save(_ preferences: NotePreferences) throws {
    try store.saveJSON(preferences, to: preferencesPath)
  }

  /// Sets a category -> folder mapping, replacing any existing key that matches
  /// case-insensitively (so re-setting "Ideas" overwrites "ideas"). Returns the
  /// previously mapped folder, if any.
  @discardableResult
  public static func set(
    _ preferences: inout NotePreferences, category: String, folder: String
  ) -> String? {
    setCaseInsensitive(&preferences.folders, key: category, folder: folder)
  }

  /// Removes a category key (case-insensitive match). Returns the removed
  /// folder, if any.
  @discardableResult
  public static func remove(
    _ preferences: inout NotePreferences, category: String
  ) -> String? {
    let target = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !target.isEmpty,
      let hit = preferences.folders.first(where: { $0.key.lowercased() == target })
    else { return nil }
    let value = hit.value
    preferences.folders[hit.key] = nil
    return value
  }

  /// Parses `cat1:Folder1,cat2:Folder2` into ordered pairs. A colon is the only
  /// valid separator between category and folder; commas and newlines separate
  /// entries. Blank segments are dropped.
  static func parse(_ raw: String) -> [(key: String, folder: String)] {
    raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .compactMap { entry -> (String, String)? in
        let parts = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !folder.isEmpty else { return nil }
        return (key, folder)
      }
  }

  /// Writes `folder` at `key`, first removing any pre-existing key that matches
  /// case-insensitively so the canonical spelling of the last write wins.
  static func setCaseInsensitive(
    _ folders: inout [String: String], key: String, folder: String
  ) -> String? {
    let lowered = key.lowercased()
    let prior = folders.first(where: { $0.key.lowercased() == lowered })?.value
    for existing in folders.keys where existing.lowercased() == lowered {
      folders[existing] = nil
    }
    folders[key] = folder
    return prior
  }
}
