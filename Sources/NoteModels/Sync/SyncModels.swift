import AppleSyncKit
import Foundation

// MARK: - Entity-keyed sync state

// These keep `note`'s on-disk JSON shape (keys `notes` / `noteFolders`). The
// generic pieces (SyncConfig, results, SyncEntityState, snapshot encoder, mapping
// inversion, timestamp/cursor helpers) live in AppleSyncKit.

public struct SyncIdMapping: Codable, Sendable {
  public var notes: [String: String]
  public var noteFolders: [String: String]
  public var preferences: [String: String]

  public init(
    notes: [String: String] = [:],
    noteFolders: [String: String] = [:],
    preferences: [String: String] = [:]
  ) {
    self.notes = notes
    self.noteFolders = noteFolders
    self.preferences = preferences
  }

  // Decodes each field independently with a default, so a state file written
  // before `preferences` existed (no key) still loads instead of stranding the
  // device on upgrade.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
    self.noteFolders = try c.decodeIfPresent([String: String].self, forKey: .noteFolders) ?? [:]
    self.preferences = try c.decodeIfPresent([String: String].self, forKey: .preferences) ?? [:]
  }
}

public struct SyncCursors: Codable, Sendable {
  public var notes: String?
  public var noteFolders: String?
  public var preferences: String?

  public init(
    notes: String? = nil,
    noteFolders: String? = nil,
    preferences: String? = nil
  ) {
    self.notes = notes
    self.noteFolders = noteFolders
    self.preferences = preferences
  }
}

public struct SyncState: Codable, Sendable {
  public var notes: SyncEntityState
  public var noteFolders: SyncEntityState
  public var preferences: SyncEntityState

  public init(
    notes: SyncEntityState = SyncEntityState(),
    noteFolders: SyncEntityState = SyncEntityState(),
    preferences: SyncEntityState = SyncEntityState()
  ) {
    self.notes = notes
    self.noteFolders = noteFolders
    self.preferences = preferences
  }

  // Decodes each field independently with a default, so a state file written
  // before `preferences` existed still loads instead of stranding the device.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.notes = try c.decodeIfPresent(SyncEntityState.self, forKey: .notes) ?? SyncEntityState()
    self.noteFolders =
      try c.decodeIfPresent(SyncEntityState.self, forKey: .noteFolders) ?? SyncEntityState()
    self.preferences =
      try c.decodeIfPresent(SyncEntityState.self, forKey: .preferences) ?? SyncEntityState()
  }
}

// MARK: - Snapshot volatile keys

/// Fields excluded from the content snapshot used for change detection: identity
/// and timestamps that differ per device. Passed to the shared engine.
public let noteSnapshotVolatileKeys: Set<String> = [
  "id", "creationDate", "modifiedDate", "account",
]
