import AppleSyncKit
import ArgumentParser
import Foundation
import NoteModels
import NoteSync

// MARK: - Direct D1 Access

/// Advanced subcommands that read and write Cloudflare D1 directly, without a
/// local store. Useful from a device that only wants the cloud copy. Note bodies
/// are decrypted on read and encrypted on write using NOTE_ENCRYPTION_KEY.
private enum DirectAccess {
  static func withNoteService<R>(
    _ body: @Sendable (CloudflareNoteService) async throws -> R
  ) async throws -> R {
    let config = try SyncConfigStore.load()
    return try await D1SyncClient.withClient(config: config) { client in
      let encryptor = try NoteEncryptor.fromEnvironment()
      let service = CloudflareNoteService(client: client, encryptor: encryptor)
      return try await body(service)
    }
  }

  static func withFolderService<R>(
    _ body: @Sendable (CloudflareFolderService) async throws -> R
  ) async throws -> R {
    let config = try SyncConfigStore.load()
    return try await D1SyncClient.withClient(config: config) { client in
      let service = CloudflareFolderService(client: client)
      return try await body(service)
    }
  }

  static func formatter(json: Bool) -> OutputFormatter {
    json ? JSONFormatter() : MarkdownFormatter()
  }
}

// MARK: - Notes (direct D1)

struct SyncNotesCommands: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "notes",
    abstract: "Read or write notes directly in Cloudflare D1",
    subcommands: [List.self, Show.self, Create.self, Delete.self]
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List notes in D1")

    @Option(name: .shortAndLong, help: "Filter by folder name")
    var folder: String?

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let notes = try await DirectAccess.withNoteService {
        try await $0.fetchNotes(folderName: folder)
      }
      print(DirectAccess.formatter(json: json).format(notes))
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a note from D1")

    @Option(name: .shortAndLong, help: "Note ID")
    var id: String

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let note = try await DirectAccess.withNoteService {
        try await $0.fetchNote(byId: id)
      }
      print(DirectAccess.formatter(json: json).format(note))
    }
  }

  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a note in D1")

    @Option(name: .shortAndLong, help: "Note title")
    var title: String

    @Option(name: .shortAndLong, help: "Note body (Markdown)")
    var body: String?

    @Option(name: .shortAndLong, help: "Folder name")
    var folder: String?

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let note = try await DirectAccess.withNoteService {
        try await $0.createNote(
          CreateNoteParams(title: title, body: body, folderName: folder))
      }
      print(DirectAccess.formatter(json: json).format(note))
    }
  }

  struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a note in D1")

    @Option(name: .shortAndLong, help: "Note ID")
    var id: String

    func run() async throws {
      try await DirectAccess.withNoteService { try await $0.deleteNote(id: id) }
      print("Note deleted from D1")
    }
  }
}

// MARK: - Folders (direct D1)

struct SyncFoldersCommands: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "folders",
    abstract: "Read or write folders directly in Cloudflare D1",
    subcommands: [List.self, Create.self, Delete.self]
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List folders in D1")

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let folders = try await DirectAccess.withFolderService { try await $0.fetchFolders() }
      print(DirectAccess.formatter(json: json).format(folders))
    }
  }

  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a folder in D1")

    @Option(name: .shortAndLong, help: "Folder name")
    var name: String

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let folder = try await DirectAccess.withFolderService {
        try await $0.createFolder(name: name)
      }
      print(DirectAccess.formatter(json: json).format(folder))
    }
  }

  struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a folder in D1")

    @Option(name: .shortAndLong, help: "Folder name")
    var name: String

    func run() async throws {
      try await DirectAccess.withFolderService { try await $0.deleteFolder(name: name) }
      print("Folder deleted from D1")
    }
  }
}
