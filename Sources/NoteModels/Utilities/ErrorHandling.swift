import AppleSyncKit
import Foundation

// MARK: - Error Handling

public enum NoteCLIError: LocalizedError, Sendable, SyncNotFound {
  case permissionDenied(String)
  case notFound(String)
  case invalidInput(String)
  case notesError(String)
  case appleScriptError(String)
  case unknown(String)

  /// Lets the shared sync engine recognize this as a not-found failure.
  public var isNotFound: Bool {
    if case .notFound = self { return true }
    return false
  }

  public var errorDescription: String? {
    switch self {
    case .permissionDenied(let message):
      return "Permission denied: \(message)"
    case .notFound(let message):
      return "Not found: \(message)"
    case .invalidInput(let message):
      return "Invalid input: \(message)"
    case .notesError(let message):
      return "Notes error: \(message)"
    case .appleScriptError(let message):
      return "AppleScript error: \(message)"
    case .unknown(let message):
      return "Error: \(message)"
    }
  }
}

/// Formats error messages for CLI output.
public enum ErrorFormatter {
  public static func format(_ error: Error) -> String {
    if let cliError = error as? NoteCLIError {
      return cliError.errorDescription ?? "Unknown error"
    }
    return "Error: \(error.localizedDescription)"
  }
}
