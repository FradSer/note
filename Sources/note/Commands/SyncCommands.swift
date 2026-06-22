import ArgumentParser
import Foundation
import NoteCommands
import NoteModels
import NoteSync

// MARK: - Sync Entity Type

enum SyncEntityType: String, ExpressibleByArgument, CaseIterable {
  case notes
  case folders
  case all

  /// Folders are pulled before notes so a note's folder exists when it lands.
  static let fullPullOrder: [SyncEntityType] = [.folders, .notes]
}

// MARK: - Sync Commands

struct SyncCommands: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sync",
    abstract: "Sync notes with Cloudflare D1",
    subcommands: [
      FullSync.self, Push.self, Pull.self, SyncConfigCommand.self, SyncStatusCommand.self,
      SyncNotesCommands.self, SyncFoldersCommands.self,
    ],
    defaultSubcommand: FullSync.self
  )

  // MARK: - Full Sync (default)

  struct FullSync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "run",
      abstract: "Run a full bidirectional sync (pull, then push)",
      discussion: """
        This is what bare 'note sync' runs: it pulls remote changes, then pushes \
        local changes in a single locked session. Note bodies are end-to-end \
        encrypted with NOTE_ENCRYPTION_KEY before they reach Cloudflare. Conflicts \
        resolve by last-write-wins -- a pull never overwrites a local copy modified \
        more recently than the server's version.

        Advanced subcommands (run 'note sync <name> --help'): 'push' and 'pull' \
        for one-directional sync; 'config' and 'status' to manage configuration; \
        'notes' and 'folders' to read or write Cloudflare D1 data directly.
        """
    )

    @Option(help: "Type to sync: notes, folders, all")
    var type: SyncEntityType = .all

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let lockFd = try SyncConfigStore.acquireLock()
      defer { SyncConfigStore.releaseLock(lockFd) }

      let service = try await BackendFactory.makeSyncService()
      do {
        let pullOutput = try await runPull(service, type: type)
        let pushOutput = try await runPush(service, type: type)
        try await service.shutdown()
        printFullSyncOutput(pull: pullOutput, push: pushOutput, json: json)
      } catch {
        try? await service.shutdown()
        throw error
      }
    }
  }

  // MARK: - Push

  struct Push: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Push local notes to Cloudflare D1 (one-directional)"
    )

    @Option(help: "Type to sync: notes, folders, all")
    var type: SyncEntityType = .all

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let lockFd = try SyncConfigStore.acquireLock()
      defer { SyncConfigStore.releaseLock(lockFd) }

      let service = try await BackendFactory.makeSyncService()
      do {
        let output = try await runPush(service, type: type)
        try await service.shutdown()
        printPushOutput(output, json: json)
      } catch {
        try? await service.shutdown()
        throw error
      }
    }
  }

  // MARK: - Pull

  struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Pull notes from Cloudflare D1 (one-directional)"
    )

    @Option(help: "Type to sync: notes, folders, all")
    var type: SyncEntityType = .all

    @Flag(help: "Output in JSON format")
    var json = false

    func run() async throws {
      let lockFd = try SyncConfigStore.acquireLock()
      defer { SyncConfigStore.releaseLock(lockFd) }

      let service = try await BackendFactory.makeSyncService()
      do {
        let output = try await runPull(service, type: type)
        try await service.shutdown()
        printPullOutput(output, json: json)
      } catch {
        try? await service.shutdown()
        throw error
      }
    }
  }
}

// MARK: - Sync Sequencing

/// Pushes the requested entity types, returning results keyed by entity.
func runPush(_ service: any SyncServiceProtocol, type: SyncEntityType) async throws
  -> [String: PushResult]
{
  var output: [String: PushResult] = [:]
  switch type {
  case .notes:
    output["notes"] = try await service.pushNotes()
  case .folders:
    output["folders"] = try await service.pushFolders()
  case .all:
    output["folders"] = try await service.pushFolders()
    output["notes"] = try await service.pushNotes()
  }
  return output
}

/// Pulls the requested entity types in dependency order, returning results keyed by entity.
func runPull(_ service: any SyncServiceProtocol, type: SyncEntityType) async throws
  -> [String: PullSummary]
{
  var output: [String: PullSummary] = [:]
  switch type {
  case .notes:
    output["notes"] = try await service.pullNotes()
  case .folders:
    output["folders"] = try await service.pullFolders()
  case .all:
    for entity in SyncEntityType.fullPullOrder {
      switch entity {
      case .folders:
        output["folders"] = try await service.pullFolders()
      case .notes:
        output["notes"] = try await service.pullNotes()
      case .all:
        break
      }
    }
  }
  return output
}

// MARK: - Sync Output

private struct FullSyncOutput: Encodable {
  let pull: [String: PullSummary]
  let push: [String: PushResult]
}

private func printJSON<T: Encodable>(_ value: T) {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
    print(str)
  }
}

private func pushLines(_ output: [String: PushResult]) -> [String] {
  let labels: [(String, String)] = [("folders", "Folders"), ("notes", "Notes")]
  return labels.compactMap { key, label in
    output[key].map { "\(label): synced \($0.synced), skipped \($0.skipped)" }
  }
}

private func pullLines(_ output: [String: PullSummary]) -> [String] {
  let labels: [(String, String)] = [("folders", "Folders"), ("notes", "Notes")]
  return labels.compactMap { key, label in
    output[key].map {
      "\(label): pulled \($0.pulled), deleted \($0.deleted), skipped \($0.skipped)"
    }
  }
}

func printPushOutput(_ output: [String: PushResult], json: Bool) {
  if json {
    printJSON(output)
  } else {
    for line in pushLines(output) { print(line) }
  }
}

func printPullOutput(_ output: [String: PullSummary], json: Bool) {
  if json {
    printJSON(output)
  } else {
    for line in pullLines(output) { print(line) }
  }
}

func printFullSyncOutput(pull: [String: PullSummary], push: [String: PushResult], json: Bool) {
  if json {
    printJSON(FullSyncOutput(pull: pull, push: push))
  } else {
    print("Pull:")
    for line in pullLines(pull) { print("  \(line)") }
    print("Push:")
    for line in pushLines(push) { print("  \(line)") }
  }
}
