import Foundation

public enum SyncPushHelpers {
  /// Resolves the remote IDs currently present locally. Items without an explicit
  /// mapping use their local Apple Notes ID as the remote ID.
  public static func currentRemoteIds<E>(
    items: [E],
    getId: (E) -> String,
    localToRemote: [String: String]
  ) -> Set<String> {
    Set(items.map { localToRemote[getId($0)] ?? getId($0) })
  }
}
