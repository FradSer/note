import Foundation

// MARK: - Markdown Formatter

public struct MarkdownFormatter: OutputFormatter {
  public init() {}

  public func format<T: Encodable>(_ data: T) -> String {
    if let notes = data as? [Note] {
      return formatNotes(notes)
    } else if let note = data as? Note {
      return formatNote(note)
    } else if let folders = data as? [NoteFolder] {
      return formatFolders(folders)
    } else if let folder = data as? NoteFolder {
      return formatFolder(folder)
    } else {
      return JSONFormatter().format(data)
    }
  }

  // MARK: - Note Formatting

  private func formatNotes(_ notes: [Note]) -> String {
    guard !notes.isEmpty else {
      return "No notes found."
    }

    var output = "### Notes\n\n"

    let grouped = Dictionary(grouping: notes, by: { $0.folder })

    for (folderName, folderNotes) in grouped.sorted(by: { $0.key < $1.key }) {
      output += "**\(folderName)**\n\n"

      for note in folderNotes.sorted(by: { ($0.title) < ($1.title) }) {
        output += "- \(note.title)\n"
        if let modified = note.modifiedDate {
          output += "  - Modified: \(modified)\n"
        }
        output += "  - ID: `\(note.id)`\n"
      }

      output += "\n"
    }

    return output
  }

  private func formatNote(_ note: Note) -> String {
    var output = "### \(note.title)\n\n"

    output += "**Folder:** \(note.folder)\n\n"

    if let modified = note.modifiedDate {
      output += "**Modified:** \(modified)\n\n"
    }

    if let body = note.body, !body.isEmpty {
      output += "---\n\n\(body)\n\n"
    }

    output += "**ID:** `\(note.id)`\n"

    return output
  }

  // MARK: - Folder Formatting

  private func formatFolders(_ folders: [NoteFolder]) -> String {
    guard !folders.isEmpty else {
      return "No folders found."
    }

    var output = "### Folders\n\n"

    for folder in folders.sorted(by: { $0.name < $1.name }) {
      output += "- **\(folder.name)**"
      if let parent = folder.parent, !parent.isEmpty {
        output += " (in \(parent))"
      }
      output += "\n"
    }

    return output
  }

  private func formatFolder(_ folder: NoteFolder) -> String {
    var output = "### Folder: \(folder.name)\n\n"
    if let account = folder.account {
      output += "**Account:** \(account)\n\n"
    }
    if let parent = folder.parent, !parent.isEmpty {
      output += "**Parent:** \(parent)\n"
    }
    return output
  }
}
