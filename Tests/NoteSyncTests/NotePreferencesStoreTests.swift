import XCTest

@testable import NoteModels
@testable import NoteSync

final class NotePreferencesStoreTests: XCTestCase {
  func testFolderLookupIsCaseInsensitiveAndTrimmed() {
    let prefs = NotePreferences(folders: ["ideas": "Ideas", "Work": "Work"])
    XCTAssertEqual(prefs.folder(for: "ideas"), "Ideas")
    XCTAssertEqual(prefs.folder(for: "IDEAS"), "Ideas")
    XCTAssertEqual(prefs.folder(for: "  Ideas "), "Ideas")
    XCTAssertEqual(prefs.folder(for: "work"), "Work")
    XCTAssertNil(prefs.folder(for: "missing"))
    XCTAssertNil(prefs.folder(for: "   "))
  }

  func testParseSplitsEntriesOnColon() {
    let pairs = NotePreferencesStore.parse("ideas:Ideas, work : Work ,invoice:Bills")
    XCTAssertEqual(pairs.map { $0.key }, ["ideas", "work", "invoice"])
    XCTAssertEqual(pairs.map { $0.folder }, ["Ideas", "Work", "Bills"])
  }

  func testParseDropsMalformedAndBlanks() {
    let pairs = NotePreferencesStore.parse("ideas:Ideas,,nope, :Bills, key:")
    // "nope" has no colon, " :Bills" has empty key, "key:" has empty folder.
    XCTAssertEqual(pairs.map { $0.key }, ["ideas"])
    XCTAssertEqual(pairs.map { $0.folder }, ["Ideas"])
  }

  func testSetReplacesCaseInsensitiveKeyKeepingLastSpelling() {
    var prefs = NotePreferences(folders: ["ideas": "Ideas"])
    let prior = NotePreferencesStore.set(&prefs, category: "IDEAS", folder: "Brainstorms")
    XCTAssertEqual(prior, "Ideas")
    XCTAssertEqual(prefs.folders.count, 1)
    XCTAssertEqual(prefs.folder(for: "ideas"), "Brainstorms")
  }

  func testRemoveIsCaseInsensitive() {
    var prefs = NotePreferences(folders: ["ideas": "Ideas", "work": "Work"])
    let removed = NotePreferencesStore.remove(&prefs, category: "WORK")
    XCTAssertEqual(removed, "Work")
    XCTAssertEqual(prefs.folders.count, 1)
    XCTAssertNil(prefs.folder(for: "work"))
  }

  func testLoadMergesEnvironmentOnTopOfFile() {
    // No preferences.json is expected in the test environment, so the effective
    // set is driven by the environment variable here.
    let prefs = NotePreferencesStore.load([
      NotePreferencesStore.envKey: "ideas:Ideas, work:Work, ideas:Brainstorms"
    ])
    // Env override wins on collision; last spelling of the key wins.
    XCTAssertEqual(prefs.folder(for: "ideas"), "Brainstorms")
    XCTAssertEqual(prefs.folder(for: "work"), "Work")
  }

  func testSaveBumpsFileModificationDate() throws {
    // ConfigStore writes to the real ~/.config/note-sync/ (uses
    // homeDirectoryForCurrentUser, not $HOME). Clean up the file we touch.
    let path = NotePreferencesStore.preferencesPath
    try? FileManager.default.removeItem(atPath: path)
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertNil(NotePreferencesStore.fileModificationDate())  // no file yet
    try NotePreferencesStore.save(NotePreferences(folders: ["a": "A"]))
    let first = NotePreferencesStore.fileModificationDate()
    XCTAssertNotNil(first)
    // Filesystem mtime resolution can be coarse; sleep past 1s to guarantee a
    // detectable change on a second save.
    Thread.sleep(forTimeInterval: 1.1)
    try NotePreferencesStore.save(NotePreferences(folders: ["b": "B"]))
    let second = NotePreferencesStore.fileModificationDate()
    XCTAssertNotNil(second)
    XCTAssertGreaterThan(second!, first!)
  }
}
