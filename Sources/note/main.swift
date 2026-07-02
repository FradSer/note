import ArgumentParser
import Foundation
import NoteModels

@main
struct NoteCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "note",
    abstract: "CLI tool for managing Apple Notes, with Cloudflare D1 sync",
    version: "0.1.0",
    subcommands: [
      NoteCommands.self,
      FolderCommands.self,
      SyncCommands.self,
      PreferencesCommand.self,
    ]
  )
}
