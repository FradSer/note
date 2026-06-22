import ArgumentParser
import Foundation
import NoteModels

// MARK: - Folder Commands

struct FolderCommands: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "folders",
    abstract: "Manage Apple Notes folders",
    subcommands: [List.self, Create.self, Delete.self]
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List folders")

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let backend = try await BackendFactory.makeFoldersBackend()
      let folders = try await backend.fetchFolders()
      let formatter: OutputFormatter = json ? JSONFormatter() : MarkdownFormatter()
      print(formatter.format(folders))
    }
  }

  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a folder")

    @Option(name: .shortAndLong, help: "Folder name")
    var name: String

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let backend = try await BackendFactory.makeFoldersBackend()
      let folder = try await backend.createFolder(name: name)
      let formatter: OutputFormatter = json ? JSONFormatter() : MarkdownFormatter()
      print(formatter.format(folder))
    }
  }

  struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Delete a folder by name (deletes its notes too)"
    )

    @Option(name: .shortAndLong, help: "Folder name")
    var name: String

    func run() async throws {
      let backend = try await BackendFactory.makeFoldersBackend()
      try await backend.deleteFolder(name: name)
      print("Folder deleted successfully")
    }
  }
}
