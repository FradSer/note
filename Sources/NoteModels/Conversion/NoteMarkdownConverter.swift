import Foundation

// MARK: - Note Markdown Converter

/// Converts between the HTML that Apple Notes stores in a note `body` and the
/// Markdown used everywhere else in this tool (display, sync payloads, Linux
/// editing). Apple Notes emits a constrained HTML subset -- block `<div>`s,
/// `<h1>`/`<h2>`/`<h3>` headings, `<b>`/`<i>`/`<u>` inline styles, `<ul>`/`<ol>`
/// lists, `<a>` links and `<br>` -- so a focused converter round-trips the common
/// cases without pulling in a full HTML parser. Exotic formatting (tables, nested
/// structures, inline images) degrades to plain text; image position is not
/// preserved, matching the documented AppleScript `set body` limitation.
public enum NoteMarkdownConverter {

  // MARK: - HTML -> Markdown

  public static func htmlToMarkdown(_ html: String) -> String {
    var text = html

    // Normalize newlines so tag handling is uniform.
    text = text.replacingOccurrences(of: "\r\n", with: "\n")
    text = text.replacingOccurrences(of: "\r", with: "\n")

    // Recover native Apple Notes heading styles. Notes serializes its Title /
    // Heading / Subheading paragraph styles as font-sized bold spans (24 / 18 /
    // 16 px); map those whole paragraphs back to Markdown headings before the
    // styling spans are stripped. Must run before <br> conversion and span
    // stripping, while the font-size attributes are still present.
    text = mapSizedHeadings(text)

    // Line breaks become newlines first, so a <br> trapped inside an emphasis or
    // heading run does not survive into the wrapped output.
    for br in ["<br/>", "<br>", "<br />"] {
      text = text.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive)
    }

    // Unwrap pure styling tags. Apple Notes wraps every text run in
    // <span style=...> and splits mixed CJK/Latin text into separate <font>
    // runs; these carry no Markdown meaning, so drop the tags but keep content.
    text = stripTag(text, tag: "span")
    text = stripTag(text, tag: "font")

    // Merge adjacent emphasis runs. Apple Notes emits a bold heading as a chain
    // of <b>..</b><b>..</b> (one run per font segment); without merging, each run
    // would become its own ** pair and produce stray **** markers.
    for tag in ["b", "strong", "i", "em", "u", "s", "strike", "del"] {
      text = text.replacingOccurrences(
        of: "</\(tag)>(\\s*)<\(tag)>", with: "$1", options: [.regularExpression, .caseInsensitive])
    }

    // Headings.
    for (level, tag) in [(1, "h1"), (2, "h2"), (3, "h3"), (4, "h4"), (5, "h5"), (6, "h6")] {
      let prefix = String(repeating: "#", count: level) + " "
      text = replaceTag(in: text, tag: tag) { inner in
        "\n" + prefix + collapseInlineWhitespace(inner) + "\n"
      }
    }

    // List items. Bullet lists and numbered lists both render as `- ` items;
    // numbering is not preserved across the round trip (Apple Notes renumbers).
    text = replaceTag(in: text, tag: "li") { inner in
      "\n- " + collapseInlineWhitespace(inner)
    }
    text = stripTag(text, tag: "ul")
    text = stripTag(text, tag: "ol")

    // Inline emphasis.
    text = wrapTag(text, tags: ["b", "strong"], with: "**")
    text = wrapTag(text, tags: ["i", "em"], with: "*")
    text = stripTag(text, tag: "u")
    text = wrapTag(text, tags: ["s", "strike", "del"], with: "~~")

    // Links: <a href="URL">TEXT</a> -> [TEXT](URL)
    text = replaceLinks(text)

    // Block boundaries become newlines.
    for tag in ["div", "p", "blockquote"] {
      text = text.replacingOccurrences(
        of: "</\(tag)>", with: "\n", options: .caseInsensitive)
      text = text.replacingOccurrences(
        of: "<\(tag)>", with: "", options: .caseInsensitive)
    }

    // Drop any remaining tags.
    text = stripAllTags(text)

    // Decode HTML entities.
    text = decodeEntities(text)

    // Collapse runs of blank lines and trim.
    let lines = text.components(separatedBy: "\n").map {
      $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }
    var result: [String] = []
    var blankRun = 0
    for line in lines {
      if line.isEmpty {
        blankRun += 1
        if blankRun <= 1 { result.append("") }
      } else {
        blankRun = 0
        result.append(line)
      }
    }
    return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Markdown -> HTML

  public static func markdownToHTML(_ markdown: String) -> String {
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")

    var html = ""
    var i = 0
    var lastWasHeading = false
    while i < lines.count {
      let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

      if trimmed.isEmpty {
        // Suppress a blank line adjacent to a heading: Apple Notes' importer
        // mangles an <h*> that sits next to an empty paragraph (it coerces it into
        // <b><h1>), and native heading styles carry their own spacing anyway.
        var j = i + 1
        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
        let nextIsHeading =
          j < lines.count && headingMatch(lines[j].trimmingCharacters(in: .whitespaces)) != nil
        if lastWasHeading || nextIsHeading {
          i += 1
          continue
        }
        html += "<div><br></div>"
        i += 1
        continue
      }

      // Headings map to Apple Notes' native paragraph styles: its HTML importer
      // turns <h1>/<h2>/<h3> into Title/Heading/Subheading. Deeper levels collapse
      // to Subheading. (A raw font-sized span would only be inline-styled body
      // text, not a real style.)
      if let (level, content) = headingMatch(trimmed) {
        let tag = "h\(min(level, 3))"
        html += "<\(tag)>\(inlineToHTML(content))</\(tag)>"
        lastWasHeading = true
        i += 1
        continue
      }

      // Bullet / numbered lists: gather consecutive item lines.
      if isListItem(trimmed) {
        var items: [String] = []
        while i < lines.count {
          let itemLine = lines[i].trimmingCharacters(in: .whitespaces)
          guard isListItem(itemLine) else { break }
          items.append(inlineToHTML(listItemContent(itemLine)))
          i += 1
        }
        html += "<ul>" + items.map { "<li>\($0)</li>" }.joined() + "</ul>"
        lastWasHeading = false
        continue
      }

      // Plain paragraph line.
      html += "<div>\(inlineToHTML(trimmed))</div>"
      lastWasHeading = false
      i += 1
    }

    return html
  }

  // MARK: - Inline Conversion

  /// Converts inline Markdown (bold/italic/strikethrough/links) into HTML after
  /// escaping HTML-special characters in the surrounding text.
  static func inlineToHTML(_ markdown: String) -> String {
    var text = escapeHTML(markdown)

    text = replaceDelimited(text, delimiter: "**", open: "<b>", close: "</b>")
    text = replaceDelimited(text, delimiter: "~~", open: "<s>", close: "</s>")
    text = replaceDelimited(text, delimiter: "*", open: "<i>", close: "</i>")

    // Links: [TEXT](URL). Escaping already ran, so URL/text are HTML-safe.
    text = renderMarkdownLinks(text)

    return text
  }

  // MARK: - Private: HTML helpers

  /// Apple Notes paragraph styles serialized as font sizes: Title 24px, Heading
  /// 18px, Subheading 16px. Each maps to a Markdown heading level.
  private static let headingSizes: [(size: Int, level: Int)] = [(24, 1), (18, 2), (16, 3)]

  /// Converts each `<div>` paragraph that represents a heading into a Markdown
  /// heading. A heading is recognized either by a heading font size (Apple's
  /// native serialization) or by a literal `<h1>`/`<h2>`/`<h3>` tag (which Apple
  /// occasionally keeps when two headings are adjacent). An empty heading
  /// paragraph is dropped; a non-heading div is left untouched.
  private static func mapSizedHeadings(_ text: String) -> String {
    regexReplace(
      text, pattern: "<div>(.*?)</div>",
      options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) { groups in
      guard groups.count > 1 else { return groups.first ?? "" }
      let inner = groups[1]
      var level = 0
      for n in 1...3
      where inner.range(
        of: "<h\(n)\\b", options: [.regularExpression, .caseInsensitive]) != nil
      {
        level = n
        break
      }
      if level == 0 {
        for (size, lvl) in headingSizes
        where inner.range(
          of: "font-size:\\s*\(size)px", options: [.regularExpression, .caseInsensitive]) != nil
        {
          level = lvl
          break
        }
      }
      guard level > 0 else { return groups[0] }
      let content = collapseInlineWhitespace(inner)
      guard !content.isEmpty else { return "" }
      return "\n" + String(repeating: "#", count: level) + " " + content + "\n"
    }
  }

  private static func replaceTag(
    in text: String, tag: String, transform: (String) -> String
  ) -> String {
    let pattern = "<\(tag)\\b[^>]*>(.*?)</\(tag)>"
    return regexReplace(
      text, pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) { groups in
      transform(groups.count > 1 ? groups[1] : "")
    }
  }

  private static func wrapTag(_ text: String, tags: [String], with marker: String) -> String {
    var result = text
    for tag in tags {
      result = replaceTag(in: result, tag: tag) { inner in
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return inner }
        return marker + trimmed + marker
      }
    }
    return result
  }

  private static func stripTag(_ text: String, tag: String) -> String {
    var result = text.replacingOccurrences(
      of: "<\(tag)\\b[^>]*>", with: "", options: .regularExpression)
    result = result.replacingOccurrences(
      of: "</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
    return result
  }

  private static func stripAllTags(_ text: String) -> String {
    text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
  }

  private static func replaceLinks(_ text: String) -> String {
    let pattern = "<a\\b[^>]*?href=\"([^\"]*)\"[^>]*>(.*?)</a>"
    return regexReplace(
      text, pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) { groups in
      guard groups.count > 2 else { return groups.first ?? "" }
      let url = groups[1]
      let label = stripAllTags(groups[2])
      return "[\(label)](\(url))"
    }
  }

  private static func collapseInlineWhitespace(_ text: String) -> String {
    stripAllTags(text)
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  private static func decodeEntities(_ text: String) -> String {
    var result = text
    let entities: [(String, String)] = [
      ("&nbsp;", " "),
      ("&amp;", "&"),
      ("&lt;", "<"),
      ("&gt;", ">"),
      ("&quot;", "\""),
      ("&#39;", "'"),
      ("&apos;", "'"),
    ]
    for (entity, replacement) in entities {
      result = result.replacingOccurrences(of: entity, with: replacement)
    }
    return result
  }

  // MARK: - Private: Markdown helpers

  private static func headingMatch(_ line: String) -> (Int, String)? {
    var level = 0
    var index = line.startIndex
    while index < line.endIndex, line[index] == "#", level < 6 {
      level += 1
      index = line.index(after: index)
    }
    guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
    let content = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    return (level, content)
  }

  private static func isListItem(_ line: String) -> Bool {
    if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
      return true
    }
    return line.range(of: "^[0-9]+\\. ", options: .regularExpression) != nil
  }

  private static func listItemContent(_ line: String) -> String {
    if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
      return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    if let range = line.range(of: "^[0-9]+\\. ", options: .regularExpression) {
      return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
    return line
  }

  private static func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  /// Replaces paired `delimiter`-wrapped spans with `open`/`close` tags. Operates
  /// on already-escaped text so it can safely emit raw HTML tags.
  private static func replaceDelimited(
    _ text: String, delimiter: String, open: String, close: String
  ) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: delimiter)
    // Non-greedy span that does not start/end on whitespace.
    let pattern = "\(escaped)(\\S(?:.*?\\S)?)\(escaped)"
    return regexReplace(text, pattern: pattern, options: [.dotMatchesLineSeparators]) { groups in
      guard groups.count > 1 else { return groups.first ?? "" }
      return open + groups[1] + close
    }
  }

  /// Renders `[label](url)` as plain text rather than an `<a href>` anchor.
  /// Apple Notes' `set body` silently strips the `href` from anchor tags (keeping
  /// only the label as underlined text), which loses the URL entirely. Emitting
  /// the bare URL as text preserves it -- Notes auto-detects and links it at
  /// display time. `label (url)` keeps both; a label equal to or absent from the
  /// URL collapses to just the URL.
  private static func renderMarkdownLinks(_ text: String) -> String {
    let pattern = "\\[([^\\]]*)\\]\\(([^)]*)\\)"
    return regexReplace(text, pattern: pattern, options: []) { groups in
      guard groups.count > 2 else { return groups.first ?? "" }
      let label = groups[1].trimmingCharacters(in: .whitespaces)
      let url = groups[2]
      if label.isEmpty || label == url { return url }
      return "\(label) (\(url))"
    }
  }

  // MARK: - Private: Regex utility

  private static func regexReplace(
    _ text: String,
    pattern: String,
    options: NSRegularExpression.Options,
    transform: ([String]) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
      return text
    }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    guard !matches.isEmpty else { return text }

    var result = ""
    var lastEnd = 0
    for match in matches {
      result += nsText.substring(
        with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
      var groups: [String] = []
      for groupIndex in 0..<match.numberOfRanges {
        let range = match.range(at: groupIndex)
        groups.append(range.location == NSNotFound ? "" : nsText.substring(with: range))
      }
      result += transform(groups)
      lastEnd = match.range.location + match.range.length
    }
    result += nsText.substring(from: lastEnd)
    return result
  }
}
