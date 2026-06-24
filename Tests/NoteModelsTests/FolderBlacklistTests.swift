import XCTest

@testable import NoteModels

final class FolderBlacklistTests: XCTestCase {
  func testMatchesCaseInsensitivelyAndTrimsWhitespace() {
    let blacklist = FolderBlacklist(folders: ["  Private  ", "Secrets"])
    XCTAssertTrue(blacklist.contains("private"))
    XCTAssertTrue(blacklist.contains("PRIVATE"))
    XCTAssertTrue(blacklist.contains("  secrets "))
    XCTAssertFalse(blacklist.contains("Notes"))
  }

  func testEmptyBlacklistMatchesNothing() {
    let blacklist = FolderBlacklist(folders: [])
    XCTAssertTrue(blacklist.isEmpty)
    XCTAssertFalse(blacklist.contains("Private"))
  }

  func testBlankEntriesAreIgnored() {
    let blacklist = FolderBlacklist(folders: ["", "   "])
    XCTAssertTrue(blacklist.isEmpty)
    XCTAssertFalse(blacklist.contains(""))
  }
}
