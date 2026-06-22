import XCTest

@testable import NoteModels
@testable import NoteSync

final class CloudflareConfigTests: XCTestCase {
  func testLoadsFromBothEnvVars() throws {
    let env = [
      "NOTE_SYNC_API_URL": "https://example.workers.dev",
      "NOTE_SYNC_API_TOKEN": "tok",
      "NOTE_SYNC_DEVICE_ID": "laptop",
    ]
    let config = try CloudflareConfig.loadFromEnvironment(env)
    XCTAssertEqual(config?.apiURL, "https://example.workers.dev")
    XCTAssertEqual(config?.apiToken, "tok")
    XCTAssertEqual(config?.deviceId, "laptop")
  }

  func testReturnsNilWhenNeitherSet() throws {
    let config = try CloudflareConfig.loadFromEnvironment([:])
    XCTAssertNil(config)
  }

  func testThrowsWhenOnlyOneSet() {
    XCTAssertThrowsError(
      try CloudflareConfig.loadFromEnvironment(["NOTE_SYNC_API_URL": "https://x.dev"]))
  }

  func testRejectsNonHTTPSURL() {
    let env = [
      "NOTE_SYNC_API_URL": "http://insecure.dev",
      "NOTE_SYNC_API_TOKEN": "tok",
    ]
    XCTAssertThrowsError(try CloudflareConfig.loadFromEnvironment(env))
  }

  func testValidateAPIURLAcceptsHTTPS() {
    XCTAssertNoThrow(try SyncConfigStore.validateAPIURL("https://ok.dev"))
    XCTAssertThrowsError(try SyncConfigStore.validateAPIURL("ftp://nope.dev"))
  }
}
