import XCTest

@testable import AppleSyncKit
@testable import NoteModels
@testable import NoteSync

final class FolderBlacklistPullTests: XCTestCase {
  private func note(_ id: String, folder: String) -> PullItem<Note> {
    PullItem(
      id: id,
      data: Note(
        id: id, title: id, body: nil, folder: folder, account: nil,
        creationDate: nil, modifiedDate: nil),
      deleted: false, updatedAt: "2026-01-01T00:00:00Z",
      lastModified: "2026-01-01T00:00:00Z")
  }

  func testDropsExcludedItemsButPreservesCursorAndHasMore() {
    let response = PullResponse(
      items: [note("a", folder: "Private"), note("b", folder: "Work")],
      cursor: "42|b", hasMore: true)
    let filtered = FolderBlacklist(folders: ["private"]).filteringPull(response) { $0.folder }

    XCTAssertEqual(filtered.items.map(\.id), ["b"])
    XCTAssertEqual(filtered.cursor, "42|b")
    XCTAssertTrue(filtered.hasMore)
  }

  func testAlsoDropsExcludedDeleteTombstones() {
    var tombstone = note("a", folder: "Private")
    tombstone = PullItem(
      id: tombstone.id, data: tombstone.data, deleted: true,
      updatedAt: tombstone.updatedAt, lastModified: tombstone.lastModified)
    let response = PullResponse(items: [tombstone], cursor: "7|a", hasMore: false)

    let filtered = FolderBlacklist(folders: ["Private"]).filteringPull(response) { $0.folder }
    XCTAssertTrue(filtered.items.isEmpty)
  }

  func testEmptyBlacklistIsANoOp() {
    let response = PullResponse(items: [note("a", folder: "Private")], cursor: "1|a", hasMore: false)
    let filtered = FolderBlacklist(folders: []).filteringPull(response) { $0.folder }
    XCTAssertEqual(filtered.items.map(\.id), ["a"])
  }
}
