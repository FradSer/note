import ArgumentParser
import Foundation
import NoteModels
import NoteSync

// MARK: - Preferences Command

/// Manages the user's category-to-folder routing preferences, persisted in
/// `~/.config/note-sync/preferences.json`. Used by `note notes create --category`
/// to land a note in the right folder without spelling the folder each time. The
/// `NOTE_PREFERENCES_FOLDERS` environment variable (`cat1:Folder1,cat2:Folder2`)
/// layers overrides on top at read time.
struct PreferencesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prefs",
    abstract: "Manage category-to-folder preferences",
    discussion: """
      Maps a free-form category (e.g. "ideas", "work", "invoice") to the Apple \
      Notes folder a note in that category should be created in. Consumed by \
      'note notes create --category <CAT>'. Stored in \
      ~/.config/note-sync/preferences.json (local-only, never synced); the \
      NOTE_PREFERENCES_FOLDERS environment variable (cat:Folder,...) overrides \
      at read time. Category keys match case-insensitively; folder values are \
      used verbatim.
      """,
    subcommands: [List.self, Add.self, Remove.self, Get.self],
    defaultSubcommand: List.self
  )

  // MARK: - List

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List category-to-folder mappings")

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let prefs = NotePreferencesStore.load()
      if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(prefs), let str = String(data: data, encoding: .utf8) {
          print(str)
        }
      } else if prefs.folders.isEmpty {
        print("No category mappings. Use 'note prefs add <category> <folder>'.")
      } else {
        print("Category mappings:")
        for key in prefs.folders.keys.sorted() {
          print("  \(key) -> \(prefs.folders[key] ?? "")")
        }
      }
    }
  }

  // MARK: - Add / Set

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Map a category to a folder (persists to preferences.json)"
    )

    @Argument(help: "Category key (matched case-insensitively on lookup)")
    var category: String

    @Argument(help: "Folder name (created on note creation if missing)")
    var folder: String

    func run() async throws {
      let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
      let folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !category.isEmpty, !folder.isEmpty else {
        throw NoteCLIError.invalidInput("Category and folder must both be non-empty.")
      }
      var prefs = NotePreferencesStore.filePreferences()
      let prior = NotePreferencesStore.set(&prefs, category: category, folder: folder)
      try NotePreferencesStore.save(prefs)
      if let prior {
        print("Updated: \(category) -> \(folder) (was \(prior))")
      } else {
        print("Mapped: \(category) -> \(folder)")
      }
      print("Saved to \(NotePreferencesStore.preferencesPath)")
    }
  }

  // MARK: - Remove

  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Remove a category mapping (from preferences.json)"
    )

    @Argument(help: "Category key to remove")
    var category: String

    func run() async throws {
      var prefs = NotePreferencesStore.filePreferences()
      guard let removed = NotePreferencesStore.remove(&prefs, category: category) else {
        print("Category not in preferences.json: \(category)")
        return
      }
      try NotePreferencesStore.save(prefs)
      print("Removed: \(category) (was -> \(removed))")
    }
  }

  // MARK: - Get

  struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show the folder mapped to a category (effective, incl. env)"
    )

    @Argument(help: "Category key")
    var category: String

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let prefs = NotePreferencesStore.load()
      let folder = prefs.folder(for: category)
      if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Out: Encodable {
          let category: String
          let folder: String?
        }
        if let data = try? encoder.encode(Out(category: category, folder: folder)),
          let str = String(data: data, encoding: .utf8)
        {
          print(str)
        }
      } else if let folder {
        print("\(category) -> \(folder)")
      } else {
        print("No mapping for category: \(category)")
      }
    }
  }
}
