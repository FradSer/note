import XCTest

@testable import note

#if os(macOS)

  final class NotesServiceMarkdownTests: XCTestCase {
    func testComposeMarkdownWithTitleAndBody() {
      let md = NotesService.composeMarkdown(title: "Shopping", body: "- milk")
      XCTAssertEqual(md, "# Shopping\n\n- milk")
    }

    func testComposeMarkdownWithEmptyBody() {
      let md = NotesService.composeMarkdown(title: "Shopping", body: nil)
      XCTAssertEqual(md, "# Shopping")
    }

    func testComposeMarkdownWithEmptyTitleReturnsBodyVerbatim() {
      // Used by the sync pull path to recreate a note from its full Markdown
      // without prepending a duplicate title line.
      let full = "# Existing\n\nbody content"
      let md = NotesService.composeMarkdown(title: "", body: full)
      XCTAssertEqual(md, full)
    }

    func testReplaceTitleLineReplacesExistingHeading() {
      let md = NotesService.replaceTitleLine(in: "# Old\n\nbody", title: "New")
      XCTAssertEqual(md, "# New\n\nbody")
    }

    func testReplaceTitleLinePrependsWhenNoHeading() {
      let md = NotesService.replaceTitleLine(in: "plain body", title: "New")
      XCTAssertEqual(md, "# New\n\nplain body")
    }
  }

#endif
