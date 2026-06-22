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

  func testRecoversNativeAppleNotesHeadings() {
    // Apple Notes serializes its Title/Heading/Subheading styles as 24/18/16px
    // bold spans; the converter must map them back to Markdown heading levels.
    let html =
      "<div><b><span style=\"font-size: 24px\">Title Line</span></b></div>"
      + "<div><b><span style=\"font-size: 18px\">Heading Line</span></b></div>"
      + "<div><b><span style=\"font-size: 16px\">Subheading</span></b></div>"
      + "<div>body text</div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertTrue(md.contains("# Title Line"))
    XCTAssertTrue(md.contains("## Heading Line"))
    XCTAssertTrue(md.contains("### Subheading"))
    XCTAssertTrue(md.contains("body text"))
  }

  func testRecoversMixedScriptNativeHeading() {
    // A mixed CJK/Latin heading is a chain of equally-sized <b><span> runs; it
    // must collapse to a single clean heading, not stray **** markers.
    let html =
      "<div><b><span style=\"font-size: 18px\">1. AI </span></b>"
      + "<b><span style=\"font-size: 18px\">辅助</span></b>"
      + "<b><span style=\"font-size: 18px\"> GitHub</span></b></div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertEqual(md, "## 1. AI 辅助 GitHub")
    XCTAssertFalse(md.contains("****"))
  }

  func testMergesAdjacentBoldRunsWithoutHeadingSize() {
    // Bold body text split into CJK/Latin runs (no heading size) must merge into
    // a single bold span rather than emitting stray **** markers.
    let html =
      "<div><b><span style=\"color: red\">foo </span></b>"
      + "<b><span style=\"color: red\">条</span></b></div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertEqual(md, "**foo 条**")
    XCTAssertFalse(md.contains("****"))
  }

  func testStripsSpanAndFontWrappers() {
    let html = "<div><span style=\"x\">plain</span> <font face=\"Y\">text</font></div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertEqual(md, "plain text")
  }

  func testCollapsesBlankLines() {
    let html = "<div>a</div><div><br></div><div><br></div><div>b</div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertFalse(md.contains("\n\n\n"))
  }

  // MARK: - Markdown -> HTML

  func testHeadingToHTMLUsesNativeTags() {
    // Headings are emitted as <h*> tags, which Apple Notes' importer maps to its
    // native Title/Heading/Subheading paragraph styles (a raw font-sized span
    // would only be inline-styled body text).
    XCTAssertEqual(NoteMarkdownConverter.markdownToHTML("# Title"), "<h1>Title</h1>")
    XCTAssertEqual(NoteMarkdownConverter.markdownToHTML("## Section"), "<h2>Section</h2>")
    XCTAssertEqual(NoteMarkdownConverter.markdownToHTML("#### Deep"), "<h3>Deep</h3>")
  }

  func testBlankLineAdjacentToHeadingSuppressed() {
    // A blank line next to a heading is dropped so Apple Notes' importer does not
    // mangle the adjacent <h*> into <b><h1>.
    let html = NoteMarkdownConverter.markdownToHTML("# Title\n\n## Section")
    XCTAssertEqual(html, "<h1>Title</h1><h2>Section</h2>")
  }

  func testHeadingRoundTripPreservesLevel() {
    let html = NoteMarkdownConverter.markdownToHTML("# Title\n\n## Section")
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertTrue(md.contains("# Title"))
    XCTAssertTrue(md.contains("## Section"))
    XCTAssertFalse(md.contains("**"))
  }

  func testLegacyLiteralHeadingTagRecovered() {
    // Notes sometimes stores a heading as <b><h1>..</h1></b> with an empty
    // trailing <h1>; recover a single clean heading, not stray ** or # markers.
    let html = "<div><b><h1>核心</h1></b><b><h1><br></h1></b></div>"
    let md = NoteMarkdownConverter.htmlToMarkdown(html)
    XCTAssertEqual(md, "# 核心")
    XCTAssertFalse(md.contains("**"))
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

  func testLinkToHTMLPreservesURLAsText() {
    // Apple Notes strips <a href> on write, so links are rendered as text to keep
    // the URL. Notes auto-links a bare URL at display time.
    let html = NoteMarkdownConverter.markdownToHTML("see [docs](https://x.com)")
    XCTAssertFalse(html.contains("<a "))
    XCTAssertTrue(html.contains("docs (https://x.com)"))
  }

  func testBareLabelEqualToURLCollapses() {
    let html = NoteMarkdownConverter.markdownToHTML("[https://x.com](https://x.com)")
    XCTAssertTrue(html.contains("https://x.com"))
    XCTAssertFalse(html.contains("https://x.com (https://x.com)"))
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
