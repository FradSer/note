import XCTest
@testable import note

/// Verifies preferences are part of the full sync pull order and land last
/// (no data dependency on notes/folders).
final class SyncEntityTypeTests: XCTestCase {
  func testFullPullOrderIncludesPreferencesLast() {
    XCTAssertEqual(SyncEntityType.fullPullOrder, [.folders, .notes, .preferences])
  }

  func testPreferencesIsCaseIterable() {
    // .preferences must be addressable as a sync --type value.
    XCTAssertNotNil(SyncEntityType(rawValue: "preferences"))
    XCTAssertTrue(SyncEntityType.allCases.contains(.preferences))
  }
}
