#if os(macOS)

  import Foundation
  import NoteModels

  // MARK: - Folder Service (AppleScript)

  /// Manages Apple Notes folders through AppleScript.
  public actor FolderService: FoldersBackend {
    public init() {}

    public func fetchFolders() async throws -> [NoteFolder] {
      let raw = try NotesScriptRunner.run(Self.listScript)
      guard !raw.isEmpty else { return [] }
      return raw.components(separatedBy: NotesScriptRunner.recordSeparator)
        .filter { !$0.isEmpty }
        .compactMap { record in
          let fields = record.components(separatedBy: NotesScriptRunner.unitSeparator)
          guard fields.count >= 4 else { return nil }
          return NoteFolder(
            id: fields[0],
            name: fields[1],
            account: fields[3].isEmpty ? nil : fields[3],
            parent: fields[2].isEmpty ? nil : fields[2]
          )
        }
    }

    public func createFolder(name: String) async throws -> NoteFolder {
      let id = try NotesScriptRunner.run(Self.createScript, arguments: [name])
      return NoteFolder(id: id, name: name, account: nil, parent: nil)
    }

    public func deleteFolder(name: String) async throws {
      do {
        try NotesScriptRunner.run(Self.deleteScript, arguments: [name])
      } catch let error as NoteCLIError {
        if case .appleScriptError(let message) = error,
          message.contains("-1728") || message.lowercased().contains("can")
        {
          throw NoteCLIError.notFound("Folder '\(name)' not found")
        }
        throw error
      }
    }

    // MARK: - AppleScript Sources

    static let listScript = """
      on run argv
        set US to (ASCII character 31)
        set RS to (ASCII character 30)
        set output to ""
        tell application "Notes"
          repeat with f in every folder
            set fName to name of f
            set parentName to ""
            set accName to ""
            try
              set c to container of f
              set cClass to (class of c) as text
              if cClass is "folder" then
                set parentName to name of c
              else
                set accName to name of c
              end if
            end try
            set output to output & (id of f) & US & fName & US & parentName & US & accName & RS
          end repeat
        end tell
        return output
      end run
      """

    static let createScript = """
      on run argv
        set folderName to item 1 of argv
        tell application "Notes"
          set newFolder to make new folder with properties {name:folderName}
          return id of newFolder
        end tell
      end run
      """

    static let deleteScript = """
      on run argv
        set folderName to item 1 of argv
        tell application "Notes"
          delete (first folder whose name is folderName)
        end tell
        return "ok"
      end run
      """
  }

#endif
