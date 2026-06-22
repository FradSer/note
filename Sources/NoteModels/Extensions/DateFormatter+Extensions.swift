import Foundation

// MARK: - Date Formatter Extensions

extension DateFormatter {
  /// Standard date-time formatter: yyyy-MM-dd HH:mm:ss
  public static let noteDateTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    return formatter
  }()
}

// MARK: - ISO8601DateFormatter Extensions

extension ISO8601DateFormatter {
  /// ISO 8601 formatter for sync timestamps.
  public static let noteISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
