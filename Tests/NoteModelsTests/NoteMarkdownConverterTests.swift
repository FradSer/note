import XCTest

@testable import NoteModels

final class NoteMarkdownConverterTests: XCTestCase {
  // MARK: - HTML -> Markdown

  func testHeadingConversion() {
    let html = "<h1>Title</h1><div>Body line</div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertTrue(md.contains("# Title"))
    XCTAssertTrue(md.contains("Body line"))
  }

  func testBoldAndItalicConversion() {
    let html = "<div><b>bold</b> and <i>italic</i></div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertTrue(md.contains("**bold**"))
    XCTAssertTrue(md.contains("*italic*"))
  }

  func testListConversion() {
    let html = "<ul><li>first</li><li>second</li></ul>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertTrue(md.contains("- first"))
    XCTAssertTrue(md.contains("- second"))
  }

  func testLinkConversion() {
    let html = "<div><a href=\"https://example.com\">Example</a></div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertTrue(md.contains("[Example](https://example.com)"))
  }

  func testEntityDecoding() {
    let html = "<div>Tom &amp; Jerry &lt;3 &quot;quoted&quot;</div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertTrue(md.contains("Tom & Jerry <3 \"quoted\""))
  }

  func testBrBecomesNewline() {
    let html = "line one<br>line two"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertEqual(md, "line one\nline two")
  }

  func testCollapsesBlankLines() {
    let html = "<div>a</div><div><br></div><div><br></div><div>b</div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertFalse(md.contains("\n\n\n"))
  }

  // MARK: - Markdown -> HTML

  func testHeadingToHTML() {
    let html = NoteMarkdownConverter.markdownToHTML("# Title")
    XCTAssertEqual(html, "<h1>Title</h1>")
  }

  func testParagraphToDiv() {
    let html = NoteMarkdownConverter.markdownToHTML("hello world")
    XCTAssertEqual(html, "<div>hello world</div>")
  }

  func testBoldToHTML() {
    let html = NoteMarkdownConverter.markdownToHTML("a **strong** word")
    XCTAssertTrue(html.contains("<b>strong</b>"))
  }

  func testListToHTML() {
    let html = NoteMarkdownConverter.markdownToHTML("- one\n- two")
    XCTAssertEqual(html, "<ul><li>one</li><li>two</li></ul>")
  }

  func testLinkToHTML() {
    let html = NoteMarkdownConverter.markdownToHTML("see [docs](https://x.com)")
    XCTAssertTrue(html.contains("<a href=\"https://x.com\">docs</a>"))
  }

  func testHTMLSpecialCharsEscapedInPlainText() {
    let html = NoteMarkdownConverter.markdownToHTML("a < b & c > d")
    XCTAssertTrue(html.contains("&lt;"))
    XCTAssertTrue(html.contains("&amp;"))
    XCTAssertTrue(html.contains("&gt;"))
  }

  // MARK: - Round Trip

  func testRoundTripPreservesHeadingAndList() {
    let original = "# Shopping\n\n- milk\n- eggs"
    let html = NoteMarkdownConverter.markdownToHTML(original)
    let back = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertTrue(back.contains("# Shopping"))
    XCTAssertTrue(back.contains("- milk"))
    XCTAssertTrue(back.contains("- eggs"))
  }

  func testRoundTripPreservesInlineEmphasis() {
    let original = "Some **bold** and *italic* text"
    let html = NoteMarkdownConverter.markdownToHTML(original)
    let back = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertTrue(back.contains("**bold**"))
    XCTAssertTrue(back.contains("*italic*"))
  }
}
