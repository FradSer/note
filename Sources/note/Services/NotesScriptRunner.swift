#if os(macOS)

  import Foundation
  import NoteModels

  // MARK: - Notes Script Runner

  /// Runs AppleScript against Apple Notes via `/usr/bin/osascript`. The script is
  /// fed on stdin and all user-supplied values (folder names, titles, bodies, IDs)
  /// are passed as `argv` arguments -- never string-interpolated into the script --
  /// so note content containing quotes or backslashes can never corrupt or inject
  /// into the script (the fragility documented in antoniorodr/memo).
  enum NotesScriptRunner {
    /// ASCII Unit Separator (0x1F): field delimiter inside a record.
    static let unitSeparator = "\u{001F}"
    /// ASCII Record Separator (0x1E): record delimiter between notes.
    static let recordSeparator = "\u{001E}"

    /// Runs `script` with the given `arguments` (exposed to the script as `argv`)
    /// and returns trimmed stdout. Throws `NoteCLIError` on a non-zero exit.
    @discardableResult
    static func run(_ script: String, arguments: [String] = []) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-"] + arguments

      let stdin = Pipe()
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardInput = stdin
      process.standardOutput = stdout
      process.standardError = stderr

      do {
        try process.run()
      } catch {
        throw NoteCLIError.appleScriptError(
          "Failed to launch osascript: \(error.localizedDescription)")
      }

      stdin.fileHandleForWriting.write(Data(script.utf8))
      stdin.fileHandleForWriting.closeFile()

      let outData = stdout.fileHandleForReading.readDataToEndOfFile()
      let errData = stderr.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()

      guard process.terminationStatus == 0 else {
        let message = String(decoding: errData, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("-1743") || message.lowercased().contains("not authori") {
          throw NoteCLIError.permissionDenied(
            "Automation access to Notes is required. Grant it under System Settings > "
              + "Privacy & Security > Automation, then retry.")
        }
        throw NoteCLIError.appleScriptError(message.isEmpty ? "osascript failed" : message)
      }

      return String(decoding: outData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

#endif
