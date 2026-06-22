#if os(macOS)

  import Foundation
  import NoteModels

  // MARK: - Notes Service (AppleScript)

  /// Manages Apple Notes through AppleScript. Apple exposes no public framework
  /// for Notes, so every operation shells out to `osascript`. Note bodies are HTML
  /// in Apple Notes and Markdown everywhere here, so reads convert HTML -> Markdown
  /// and writes convert Markdown -> HTML. A note's title is the first line of its
  /// body, matching Apple Notes' own behaviour.
  public actor NotesService: NotesBackend {
    public init() {}

    // MARK: - Fetch

    public func fetchNotes(folderName: String?) async throws -> [Note] {
      let raw = try NotesScriptRunner.run(Self.listScript, arguments: [folderName ?? ""])
      return parseNotes(raw)
    }

    public func fetchNote(byId id: String) async throws -> Note {
      let raw: String
      do {
        raw = try NotesScriptRunner.run(Self.fetchByIdScript, arguments: [id])
      } catch let error as NoteCLIError {
        throw Self.mapNotFound(error, id: id)
      }
      let fields = raw.components(separatedBy: NotesScriptRunner.unitSeparator)
      guard fields.count >= 6 else {
        throw NoteCLIError.notFound("Note with ID '\(id)' not found")
      }
      return makeNote(fields: fields)
    }

    public func searchNotes(keyword: String, folderName: String?) async throws -> [Note] {
      let all = try await fetchNotes(folderName: folderName)
      let lowered = keyword.lowercased()
      return all.filter { note in
        note.title.lowercased().contains(lowered)
          || (note.body?.lowercased().contains(lowered) ?? false)
      }
    }

    // MARK: - Create

    public func createNote(_ params: CreateNoteParams) async throws -> Note {
      let markdown = Self.composeMarkdown(title: params.title, body: params.body)
      let html = NoteMarkdownConverter.markdownToHTML(markdown)
      let id = try NotesScriptRunner.run(
        Self.createScript, arguments: [params.folderName ?? "", html])
      return try await fetchNote(byId: id)
    }

    // MARK: - Update

    public func updateNote(id: String, params: UpdateNoteParams) async throws -> Note {
      let existing = try await fetchNote(byId: id)

      let newMarkdown: String
      if let body = params.body {
        // Body holds the full Markdown document; apply a new title to its first
        // line when one is supplied.
        newMarkdown = params.title.map { Self.replaceTitleLine(in: body, title: $0) } ?? body
      } else if let title = params.title {
        newMarkdown = Self.replaceTitleLine(in: existing.body ?? "", title: title)
      } else {
        return existing
      }

      let html = NoteMarkdownConverter.markdownToHTML(newMarkdown)
      do {
        try NotesScriptRunner.run(Self.updateScript, arguments: [id, html])
      } catch let error as NoteCLIError {
        throw Self.mapNotFound(error, id: id)
      }
      return try await fetchNote(byId: id)
    }

    // MARK: - Move

    public func moveNote(id: String, toFolder folderName: String) async throws -> Note {
      let newId: String
      do {
        newId = try NotesScriptRunner.run(Self.moveScript, arguments: [id, folderName])
      } catch let error as NoteCLIError {
        throw Self.mapNotFound(error, id: id)
      }
      return try await fetchNote(byId: newId)
    }

    // MARK: - Delete

    public func deleteNote(id: String) async throws {
      do {
        try NotesScriptRunner.run(Self.deleteScript, arguments: [id])
      } catch let error as NoteCLIError {
        throw Self.mapNotFound(error, id: id)
      }
    }

    // MARK: - Parsing

    private func parseNotes(_ raw: String) -> [Note] {
      guard !raw.isEmpty else { return [] }
      return raw.components(separatedBy: NotesScriptRunner.recordSeparator)
        .filter { !$0.isEmpty }
        .compactMap { record in
          let fields = record.components(separatedBy: NotesScriptRunner.unitSeparator)
          guard fields.count >= 6 else { return nil }
          return makeNote(fields: fields)
        }
    }

    /// Field order matches the AppleScript output:
    /// id, folder, title, creationDate, modifiedDate, body(HTML).
    private func makeNote(fields: [String]) -> Note {
      let body = NoteMarkdownConverter.htmlToMarkdown(fields[5])
      return Note(
        id: fields[0],
        title: fields[2],
        body: body.isEmpty ? nil : body,
        folder: fields[1],
        account: nil,
        creationDate: emptyToNil(fields[3]),
        modifiedDate: emptyToNil(fields[4])
      )
    }

    private nonisolated func emptyToNil(_ value: String) -> String? {
      value.isEmpty ? nil : value
    }

    // MARK: - Markdown Helpers

    /// Combines a title and optional body into a single Markdown document whose
    /// first line is the title heading. An empty title returns the body verbatim,
    /// which lets the sync layer recreate a pulled note from its full Markdown
    /// without duplicating the title line.
    static func composeMarkdown(title: String, body: String?) -> String {
      let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if title.isEmpty { return trimmedBody }
      guard !trimmedBody.isEmpty else { return "# \(title)" }
      return "# \(title)\n\n\(trimmedBody)"
    }

    /// Replaces the leading heading line of `markdown` with `# title`, or prepends
    /// one when the document has no heading first line.
    static func replaceTitleLine(in markdown: String, title: String) -> String {
      var lines = markdown.components(separatedBy: "\n")
      if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
        lines[0] = "# \(title)"
        return lines.joined(separator: "\n")
      }
      return "# \(title)\n\n\(markdown)"
    }

    private static func mapNotFound(_ error: NoteCLIError, id: String) -> NoteCLIError {
      if case .appleScriptError(let message) = error,
        message.contains("-1728") || message.lowercased().contains("can’t get")
          || message.lowercased().contains("can't get")
      {
        return NoteCLIError.notFound("Note with ID '\(id)' not found")
      }
      return error
    }

    // MARK: - AppleScript Sources

    private static let dateHandlers = """
      on isoDate(d)
        set g to d - (time to GMT)
        return my fmtDate(g)
      end isoDate

      on fmtDate(d)
        set y to (year of d) as integer
        set mo to (month of d) as integer
        set dy to (day of d) as integer
        set hh to (hours of d) as integer
        set mm to (minutes of d) as integer
        set ss to (seconds of d) as integer
        return (y as string) & "-" & my pad(mo) & "-" & my pad(dy) & " " & my pad(hh) & ":" & my pad(mm) & ":" & my pad(ss)
      end fmtDate

      on pad(n)
        if n < 10 then return "0" & (n as string)
        return n as string
      end pad
      """

    static let listScript = """
      on run argv
        set US to (ASCII character 31)
        set RS to (ASCII character 30)
        set folderFilter to ""
        if (count of argv) > 0 then set folderFilter to item 1 of argv
        set deletedNames to {"Recently Deleted", "Recently Deleted Notes"}
        set output to ""
        tell application "Notes"
          repeat with f in folders
            set fName to name of f
            if (fName is not in deletedNames) then
              if (folderFilter is "" or folderFilter is fName) then
                repeat with n in notes of f
                  set output to output & (id of n) & US & fName & US & (name of n) & US & my isoDate(creation date of n) & US & my isoDate(modification date of n) & US & (body of n) & RS
                end repeat
              end if
            end if
          end repeat
        end tell
        return output
      end run

      \(dateHandlers)
      """

    static let fetchByIdScript = """
      on run argv
        set US to (ASCII character 31)
        set theId to item 1 of argv
        tell application "Notes"
          set matches to notes whose id is theId
          if (count of matches) is 0 then error "Note not found (-1728)"
          set n to item 1 of matches
          set c to container of n
          return (id of n) & US & (name of c) & US & (name of n) & US & my isoDate(creation date of n) & US & my isoDate(modification date of n) & US & (body of n)
        end tell
      end run

      \(dateHandlers)
      """

    static let createScript = """
      on run argv
        set folderName to item 1 of argv
        set htmlBody to item 2 of argv
        tell application "Notes"
          if folderName is "" then
            set newNote to make new note with properties {body:htmlBody}
          else
            set targetFolder to missing value
            try
              set targetFolder to first folder whose name is folderName
            on error
              set targetFolder to make new folder with properties {name:folderName}
            end try
            set newNote to make new note at targetFolder with properties {body:htmlBody}
          end if
          return id of newNote
        end tell
      end run
      """

    static let updateScript = """
      on run argv
        set theId to item 1 of argv
        set htmlBody to item 2 of argv
        tell application "Notes"
          set matches to notes whose id is theId
          if (count of matches) is 0 then error "Note not found (-1728)"
          set body of (item 1 of matches) to htmlBody
        end tell
        return "ok"
      end run
      """

    static let moveScript = """
      on run argv
        set theId to item 1 of argv
        set targetFolderName to item 2 of argv
        tell application "Notes"
          set theNote to missing value
          set accToUse to missing value
          set noteBody to ""
          repeat with acc in accounts
            repeat with f in folders of acc
              try
                set n to first note of f whose id is theId
                set theNote to n
                set noteBody to body of n
                set accToUse to acc
                exit repeat
              end try
            end repeat
            if theNote is not missing value then exit repeat
          end repeat
          if theNote is missing value then error "Note -1728"
          set destFolder to missing value
          try
            set destFolder to folder targetFolderName of accToUse
          on error
            set destFolder to make new folder with properties {name:targetFolderName} at accToUse
          end try
          set newNote to make new note at destFolder with properties {body:noteBody}
          delete theNote
          return id of newNote
        end tell
      end run
      """

    static let deleteScript = """
      on run argv
        set theId to item 1 of argv
        tell application "Notes"
          set matches to notes whose id is theId
          if (count of matches) is 0 then error "Note not found (-1728)"
          delete (item 1 of matches)
        end tell
        return "ok"
      end run
      """
  }

#endif
