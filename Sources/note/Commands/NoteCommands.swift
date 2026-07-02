import ArgumentParser
import Foundation
import NoteModels
import NoteSync

// MARK: - Note Commands

struct NoteCommands: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "notes",
    abstract: "Manage Apple Notes",
    subcommands: [
      List.self, Show.self, Create.self, Edit.self, Move.self, Delete.self, Search.self,
    ]
  )

  // MARK: - List

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List notes")

    @Option(name: .shortAndLong, help: "Filter by folder name")
    var folder: String?

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let backend = try await BackendFactory.makeNotesBackend()
      let notes = try await backend.fetchNotes(folderName: folder)
      let formatter: OutputFormatter = json ? JSONFormatter() : MarkdownFormatter()
      print(formatter.format(notes))
    }
  }

  // MARK: - Show

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show a single note with its body"
    )

    @Option(name: .shortAndLong, help: "Note ID")
    var id: String

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let backend = try await BackendFactory.makeNotesBackend()
      let note = try await backend.fetchNote(byId: id)
      let formatter: OutputFormatter = json ? JSONFormatter() : MarkdownFormatter()
      print(formatter.format(note))
    }
  }

  // MARK: - Create

  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new note")

    @Option(name: .shortAndLong, help: "Note title")
    var title: String

    @Option(name: .shortAndLong, help: "Note body (Markdown)")
    var body: String?

    @Option(name: .long, help: "Read the note body (Markdown) from a file")
    var bodyFile: String?

    @Option(name: .shortAndLong, help: "Folder name (created if missing)")
    var folder: String?

    @Option(
      name: .shortAndLong,
      help: """
        Category key resolved to a folder via ~/.config/note-sync/preferences.json \
        (e.g. ideas -> Ideas). Ignored when --folder is given.
        """)
    var category: String?

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let resolvedBody = try Self.resolveBody(body: body, bodyFile: bodyFile)
      let resolvedFolder = try Self.resolveFolder(folder: folder, category: category)
      let backend = try await BackendFactory.makeNotesBackend()
      let note = try await backend.createNote(
        CreateNoteParams(title: title, body: resolvedBody, folderName: resolvedFolder))
      let formatter: OutputFormatter = json ? JSONFormatter() : MarkdownFormatter()
      print(formatter.format(note))
    }

    /// Resolves the destination folder: explicit `--folder` wins; otherwise the
    /// `--category` key is looked up in user preferences. Throws when a category
    /// is given but has no mapping (so a typo does not silently land in Notes).
    static func resolveFolder(folder: String?, category: String?) throws -> String? {
      if let folder, !folder.isEmpty { return folder }
      guard let category, !category.isEmpty else { return nil }
      let prefs = NotePreferencesStore.load()
      guard let mapped = prefs.folder(for: category) else {
        throw NoteCLIError.invalidInput(
          "No folder mapped for category '\(category)'. "
            + "Run 'note prefs add \(category) <Folder>' or pass --folder.")
      }
      return mapped
    }

    static func resolveBody(body: String?, bodyFile: String?) throws -> String? {
      if let bodyFile {
        guard let contents = try? String(contentsOfFile: bodyFile, encoding: .utf8) else {
          throw NoteCLIError.invalidInput("Could not read body file at \(bodyFile)")
        }
        return contents
      }
      return body
    }
  }

  // MARK: - Edit

  struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Edit a note's title and/or body"
    )

    @Option(name: .shortAndLong, help: "Note ID")
    var id: String

    @Option(name: .shortAndLong, help: "New title")
    var title: String?

    @Option(name: .shortAndLong, help: "New body (Markdown, replaces the whole body)")
    var body: String?

    @Option(name: .long, help: "Read the new body (Markdown) from a file")
    var bodyFile: String?

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let resolvedBody = try Create.resolveBody(body: body, bodyFile: bodyFile)
      if title == nil, resolvedBody == nil {
        throw NoteCLIError.invalidInput("Provide --title and/or --body to edit a note.")
      }
      let backend = try await BackendFactory.makeNotesBackend()
      let note = try await backend.updateNote(
        id: id, params: UpdateNoteParams(title: title, body: resolvedBody))
      let formatter: OutputFormatter = json ? JSONFormatter() : MarkdownFormatter()
      print(formatter.format(note))
    }
  }

  // MARK: - Move

  struct Move: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Move a note to another folder"
    )

    @Option(name: .shortAndLong, help: "Note ID")
    var id: String

    @Option(name: .shortAndLong, help: "Destination folder name (created if missing)")
    var folder: String

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let backend = try await BackendFactory.makeNotesBackend()
      let note = try await backend.moveNote(id: id, toFolder: folder)
      let formatter: OutputFormatter = json ? JSONFormatter() : MarkdownFormatter()
      print(formatter.format(note))
    }
  }

  // MARK: - Delete

  struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a note")

    @Option(name: .shortAndLong, help: "Note ID")
    var id: String

    func run() async throws {
      let backend = try await BackendFactory.makeNotesBackend()
      try await backend.deleteNote(id: id)
      print("Note deleted successfully")
    }
  }

  // MARK: - Search

  struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Search notes by keyword in title and body"
    )

    @Option(name: .shortAndLong, help: "Search keyword")
    var keyword: String

    @Option(name: .shortAndLong, help: "Filter by folder name")
    var folder: String?

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let backend = try await BackendFactory.makeNotesBackend()
      let notes = try await backend.searchNotes(keyword: keyword, folderName: folder)
      let formatter: OutputFormatter = json ? JSONFormatter() : MarkdownFormatter()
      print(formatter.format(notes))
    }
  }
}
