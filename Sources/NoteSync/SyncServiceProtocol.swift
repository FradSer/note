import AppleSyncKit

// MARK: - Sync Service Protocol

/// Common interface for bidirectional sync services on both macOS (Apple Notes
/// via AppleScript) and Linux (SQLite). Both `SyncService` and `LinuxSyncService`
/// conform to this protocol.
public protocol SyncServiceProtocol: Sendable {
  func pushNotes() async throws -> PushResult
  func pushFolders() async throws -> PushResult
  func pushPreferences() async throws -> PushResult
  func pullNotes() async throws -> PullSummary
  func pullFolders() async throws -> PullSummary
  func pullPreferences() async throws -> PullSummary
  func shutdown() async throws
}
