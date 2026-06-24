import XCTest

@testable import NoteModels
@testable import NoteSync

final class SyncExclusionStoreTests: XCTestCase {
  func testParseSplitsOnCommasAndNewlines() {
    XCTAssertEqual(
      SyncExclusionStore.parse("Private, Secrets\nWork"),
      ["Private", "Secrets", "Work"])
  }

  func testParseTrimsAndDropsBlanks() {
    XCTAssertEqual(
      SyncExclusionStore.parse(" Private ,, \n  ,Secrets "),
      ["Private", "Secrets"])
  }

  func testDedupKeepsFirstSpellingCaseInsensitively() {
    XCTAssertEqual(
      SyncExclusionStore.dedup(["Private", "private", "Secrets", " PRIVATE "]),
      ["Private", "Secrets"])
  }

  func testLoadMergesEnvironmentOnTopOfFile() {
    // No exclude.json is expected in the test environment, so the effective set
    // is driven by the environment variable here.
    let exclusions = SyncExclusionStore.load([
      SyncExclusionStore.envKey: "Vault, Vault, Diary"
    ])
    XCTAssertTrue(exclusions.folders.contains("Vault"))
    XCTAssertTrue(exclusions.folders.contains("Diary"))
    XCTAssertEqual(exclusions.folders.filter { $0.lowercased() == "vault" }.count, 1)
  }
}
