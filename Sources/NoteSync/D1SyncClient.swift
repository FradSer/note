import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NoteModels

// MARK: - D1 Client Conformance

extension D1SyncClient: D1Client {}

// MARK: - D1 Sync Client

public actor D1SyncClient {
  /// Must stay in sync with `MAX_BATCH_SIZE` in the Cloudflare Worker.
  private static let maxBatchSize = 500

  private let config: SyncConfig
  private let httpClient: HTTPClient

  /// `urlQueryAllowed` minus the separators that must be escaped inside a value.
  private static let queryValueAllowed: CharacterSet = {
    var set = CharacterSet.urlQueryAllowed
    set.remove(charactersIn: "&=+")
    return set
  }()

  private static func encodeQuery(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
  }

  public init(config: SyncConfig) {
    self.config = config
    self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
  }

  /// Shut down the underlying HTTP client. Call before discarding the client.
  public func shutdown() async throws {
    try await httpClient.shutdown()
  }

  // MARK: - Notes

  public func pushNotes(
    _ notes: [Note],
    idOverrides: [String: String] = [:],
    lastModifiedByRemoteId: [String: String]
  ) async throws -> PushResult {
    let items = notes.map { note in
      let remoteId = idOverrides[note.id] ?? note.id
      return PushRequestItem(
        id: remoteId,
        data: note,
        lastModified: lastModifiedByRemoteId[remoteId]
          ?? ISO8601DateFormatter.noteISO8601.string(from: Date())
      )
    }
    return try await push(entity: "notes", items: items)
  }

  public func pullNotes(cursor: String?) async throws -> PullResponse<Note> {
    return try await pull(entity: "notes", cursor: cursor, excludeOwnWrites: true)
  }

  // MARK: - Folders

  public func pushFolders(
    _ folders: [NoteFolder],
    idOverrides: [String: String] = [:],
    lastModifiedByRemoteId: [String: String]
  ) async throws -> PushResult {
    let items = folders.map { folder in
      let remoteId = idOverrides[folder.id] ?? folder.id
      return PushRequestItem(
        id: remoteId,
        data: folder,
        lastModified: lastModifiedByRemoteId[remoteId]
          ?? ISO8601DateFormatter.noteISO8601.string(from: Date())
      )
    }
    return try await push(entity: "note_folders", items: items)
  }

  public func pullFolders(cursor: String?) async throws -> PullResponse<NoteFolder> {
    return try await pull(entity: "note_folders", cursor: cursor, excludeOwnWrites: true)
  }

  // MARK: - Pull All (convenience for paginated reads)

  // These read every live record regardless of origin device, so the own-writes
  // filter is disabled (a Linux-only client expects to see all entities).
  // Soft-deleted records are dropped -- these convenience reads list current
  // entities only and do not surface tombstones.
  public func pullAllNotes() async throws -> [Note] {
    try await pullAll { cursor in
      try await self.pull(entity: "notes", cursor: cursor, excludeOwnWrites: false)
    }
  }

  public func pullAllFolders() async throws -> [NoteFolder] {
    try await pullAll { cursor in
      try await self.pull(entity: "note_folders", cursor: cursor, excludeOwnWrites: false)
    }
  }

  private func pullAll<T: Codable & Sendable>(
    fetch: (String?) async throws -> PullResponse<T>
  ) async throws -> [T] {
    var all: [T] = []
    var cursor: String? = nil
    var hasMore = true
    while hasMore {
      let response = try await fetch(cursor)
      all += response.items.filter { !$0.deleted }.map { $0.data }
      cursor = response.cursor
      hasMore = response.hasMore
    }
    return all
  }

  // MARK: - Delete

  public func deleteNote(id: String, lastModified: String?) async throws {
    try await delete(entity: "notes", id: id, lastModified: lastModified)
  }

  public func deleteFolder(id: String, lastModified: String?) async throws {
    try await delete(entity: "note_folders", id: id, lastModified: lastModified)
  }

  // MARK: - Generic HTTP Methods

  /// Pushes items in batches of `maxBatchSize` so payloads of any size stay
  /// within the Worker's per-request batch limit.
  private func push<T: Codable>(entity: String, items: [PushRequestItem<T>]) async throws
    -> PushResult
  {
    guard !items.isEmpty else {
      return PushResult(synced: 0, skipped: 0)
    }
    var synced = 0
    var skipped = 0
    var offset = 0
    while offset < items.count {
      let chunk = Array(items[offset..<min(offset + Self.maxBatchSize, items.count)])
      let result = try await pushBatch(entity: entity, items: chunk)
      synced += result.synced
      skipped += result.skipped
      offset += Self.maxBatchSize
    }
    return PushResult(synced: synced, skipped: skipped)
  }

  private func pushBatch<T: Codable>(entity: String, items: [PushRequestItem<T>]) async throws
    -> PushResult
  {
    let request = PushRequest(deviceId: config.deviceId, items: items)
    let body = try JSONEncoder().encode(request)

    var httpRequest = HTTPClientRequest(url: "\(config.apiURL)/api/v1/\(entity)/push")
    httpRequest.method = .POST
    httpRequest.headers.add(name: "Authorization", value: "Bearer \(config.apiToken)")
    httpRequest.headers.add(name: "Content-Type", value: "application/json")
    httpRequest.body = .bytes(body)

    let response = try await httpClient.execute(httpRequest, timeout: .seconds(120))
    // Push responses are small acknowledgements (1 MB ceiling).
    let responseData = try await response.body.collect(upTo: 1024 * 1024)

    guard response.status == .ok else {
      let errorBody = String(buffer: responseData)
      throw NoteCLIError.unknown("Push failed (\(response.status.code)): \(errorBody)")
    }

    return try JSONDecoder().decode(PushResult.self, from: Data(buffer: responseData))
  }

  private func pull<T: Codable>(
    entity: String,
    cursor: String?,
    excludeOwnWrites: Bool
  ) async throws -> PullResponse<T> {
    // The `device` filter makes the Worker exclude this device's own writes, so a
    // syncing device never pulls back what it just pushed.
    var queryItems: [String] = []
    if excludeOwnWrites {
      queryItems.append("device=\(Self.encodeQuery(config.deviceId))")
    }
    if let cursor {
      queryItems.append("cursor=\(Self.encodeQuery(cursor))")
    }
    let queryString = queryItems.isEmpty ? "" : "?\(queryItems.joined(separator: "&"))"
    var httpRequest = HTTPClientRequest(
      url: "\(config.apiURL)/api/v1/\(entity)/pull\(queryString)"
    )
    httpRequest.method = .GET
    httpRequest.headers.add(name: "Authorization", value: "Bearer \(config.apiToken)")

    let response = try await httpClient.execute(httpRequest, timeout: .seconds(120))
    // Pull responses carry full entity payloads (10 MB ceiling).
    let responseData = try await response.body.collect(upTo: 10 * 1024 * 1024)

    guard response.status == .ok else {
      let errorBody = String(buffer: responseData)
      throw NoteCLIError.unknown("Pull failed (\(response.status.code)): \(errorBody)")
    }

    let dto = try JSONDecoder().decode(PullResponseDTO.self, from: Data(buffer: responseData))
    let items: [PullItem<T>] = try PullItemDecoder.decodeItems(from: dto.items, entity: entity)

    return PullResponse(items: items, cursor: dto.cursor, hasMore: dto.hasMore)
  }

  private func delete(entity: String, id: String, lastModified: String?) async throws {
    let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    var httpRequest = HTTPClientRequest(url: "\(config.apiURL)/api/v1/\(entity)/\(encodedId)")
    httpRequest.method = .DELETE
    httpRequest.headers.add(name: "Authorization", value: "Bearer \(config.apiToken)")
    httpRequest.headers.add(name: "Content-Type", value: "application/json")
    let bodyDict = [
      "last_modified": lastModified ?? ISO8601DateFormatter.noteISO8601.string(from: Date())
    ]
    httpRequest.body = .bytes(try JSONEncoder().encode(bodyDict))

    let response = try await httpClient.execute(httpRequest, timeout: .seconds(120))
    guard response.status == .ok else {
      let responseData = try await response.body.collect(upTo: 1024 * 1024)
      let errorBody = String(buffer: responseData)
      throw NoteCLIError.unknown("Delete failed (\(response.status.code)): \(errorBody)")
    }
  }
}
