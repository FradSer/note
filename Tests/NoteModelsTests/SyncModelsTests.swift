import XCTest

@testable import NoteModels

final class SyncModelsTests: XCTestCase {
  // MARK: - ID Mapping Inversion

  func testInvertMappingRoundTrips() {
    let remoteToLocal = ["r1": "l1", "r2": "l2"]
    let result = SyncIdMapping.inverted(remoteToLocal)
    XCTAssertEqual(result.mapping, ["l1": "r1", "l2": "r2"])
    XCTAssertTrue(result.collisions.isEmpty)
  }

  func testInvertMappingReportsCollisionDeterministically() {
    let remoteToLocal = ["rB": "shared", "rA": "shared"]
    let result = SyncIdMapping.inverted(remoteToLocal)
    // The lexicographically smaller remote ID (rA) is kept.
    XCTAssertEqual(result.mapping["shared"], "rA")
    XCTAssertEqual(result.collisions.count, 1)
    XCTAssertEqual(result.collisions.first?.keptRemoteId, "rA")
    XCTAssertEqual(result.collisions.first?.droppedRemoteId, "rB")
  }

  // MARK: - Snapshot / change detection

  func testSnapshotIgnoresVolatileKeys() throws {
    let base = Note(
      id: "a", title: "T", body: "b", folder: "F", account: "iCloud",
      creationDate: "2026-01-01", modifiedDate: "2026-01-02")
    // Same content, different id/dates/account => same snapshot.
    let other = Note(
      id: "z", title: "T", body: "b", folder: "F", account: "OnMyMac",
      creationDate: "2030-09-09", modifiedDate: "2030-10-10")

    var state = SyncEntityState()
    try state.recordSyncedValue(base, remoteId: "remote", lastModified: "2026-01-02")
    // `lastModified(for:)` returns the stored value when content is unchanged.
    let unchanged = try state.lastModified(
      for: other, remoteId: "remote", fallback: "FALLBACK")
    XCTAssertEqual(unchanged, "2026-01-02")
  }

  func testSnapshotDetectsContentChange() throws {
    let base = Note(
      id: "a", title: "T", body: "b", folder: "F", account: nil,
      creationDate: nil, modifiedDate: nil)
    let changed = Note(
      id: "a", title: "T", body: "DIFFERENT", folder: "F", account: nil,
      creationDate: nil, modifiedDate: nil)

    var state = SyncEntityState()
    try state.recordSyncedValue(base, remoteId: "remote", lastModified: "2026-01-02")
    let result = try state.lastModified(
      for: changed, remoteId: "remote", fallback: "FALLBACK")
    XCTAssertEqual(result, "FALLBACK")
  }

  // MARK: - Deletion candidates

  func testDeletionCandidates() {
    var state = SyncEntityState()
    state.recordKnownRemoteId("r1")
    state.recordKnownRemoteId("r2")
    state.recordKnownRemoteId("r3")
    let candidates = state.deletionCandidates(currentRemoteIds: ["r1", "r3"])
    XCTAssertEqual(candidates, ["r2"])
  }

  // MARK: - Timestamp parsing

  func testTimestampParsingTolerantOfFormats() {
    XCTAssertNotNil(SyncTimestamp.parse("2026-03-10T14:00:00Z"))
    XCTAssertNotNil(SyncTimestamp.parse("2026-03-10T14:00:00.123Z"))
    XCTAssertNotNil(SyncTimestamp.parse("2026-03-10 14:00:00"))
    XCTAssertNil(SyncTimestamp.parse(""))
    XCTAssertNil(SyncTimestamp.parse("nonsense"))
  }
}
