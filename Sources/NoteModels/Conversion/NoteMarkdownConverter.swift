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

    // Line breaks and block boundaries become newlines.
    text = text.replacingOccurrences(
      of: "<br/>", with: "\n", options: .caseInsensitive)
    text = text.replacingOccurrences(
      of: "<br>", with: "\n", options: .caseInsensitive)
    text = text.replacingOccurrences(
      of: "<br />", with: "\n", options: .caseInsensitive)
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
    while i < lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.isEmpty {
        html += "<div><br></div>"
        i += 1
        continue
      }

      // Headings.
      if let (level, content) = headingMatch(trimmed) {
        html += "<h\(level)>\(inlineToHTML(content))</h\(level)>"
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
        continue
      }

      // Plain paragraph line.
      html += "<div>\(inlineToHTML(trimmed))</div>"
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
    text = replaceMarkdownLinks(text)

    return text
  }

  // MARK: - Private: HTML helpers

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
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
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

  private static func replaceMarkdownLinks(_ text: String) -> String {
    let pattern = "\\[([^\\]]*)\\]\\(([^)]*)\\)"
    return regexReplace(text, pattern: pattern, options: []) { groups in
      guard groups.count > 2 else { return groups.first ?? "" }
      return "<a href=\"\(groups[2])\">\(groups[1])</a>"
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
