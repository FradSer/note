import AppleSyncKit
import XCTest
@testable import NoteModels

/// Guards backward compatibility: existing on-disk sync state files lack the
/// `preferences` slot (added when preferences sync was introduced). Decoding an
/// old JSON blob must yield the default, not throw, so existing devices upgrade
/// without a reset.
final class SyncModelsTests: XCTestCase {
  func testSyncStateDecodesLegacyJSONMissingPreferences() throws {
    // Pre-preferences shape: only notes + noteFolders.
    let json = """
      {
        "notes": { "lastModifiedByRemoteId": {}, "knownRemoteIds": [] },
        "noteFolders": { "lastModifiedByRemoteId": {}, "knownRemoteIds": [] }
      }
      """.data(using: .utf8)!
    let state = try JSONDecoder().decode(SyncState.self, from: json)
    XCTAssertEqual(state.preferences, SyncEntityState())
  }

  func testSyncCursorsDecodesLegacyJSONMissingPreferences() throws {
    let json = #"{"notes":"a|b","noteFolders":null}"#.data(using: .utf8)!
    let cursors = try JSONDecoder().decode(SyncCursors.self, from: json)
    XCTAssertNil(cursors.preferences)
    XCTAssertEqual(cursors.notes, "a|b")
  }

  func testSyncIdMappingDecodesLegacyJSONMissingPreferences() throws {
    let json = #"{"notes":{"a":"b"},"noteFolders":{}}"#.data(using: .utf8)!
    let mapping = try JSONDecoder().decode(SyncIdMapping.self, from: json)
    XCTAssertEqual(mapping.preferences, [:])
    XCTAssertEqual(mapping.notes, ["a": "b"])
  }

  func testRoundTripPreservesPreferences() throws {
    let state = SyncState(
      notes: SyncEntityState(),
      noteFolders: SyncEntityState(),
      preferences: SyncEntityState(lastModifiedByRemoteId: ["default": "2026-07-02T10:00:00Z"])
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(SyncState.self, from: data)
    XCTAssertEqual(decoded.preferences.lastModifiedByRemoteId["default"], "2026-07-02T10:00:00Z")
  }

  func testNotePreferencesSnapshotIdDefaultsToDefault() {
    let snap = NotePreferencesSnapshot(folders: ["ideas": "Ideas"])
    XCTAssertEqual(snap.id, "default")
    XCTAssertEqual(snap.folders, ["ideas": "Ideas"])
  }
}
