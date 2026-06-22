// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "note",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "note", targets: ["note"]),
    .library(name: "NoteModels", targets: ["NoteModels"]),
    .library(name: "NoteSync", targets: ["NoteSync"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(url: "https://github.com/swift-server/async-http-client", from: "1.21.0"),
    .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    .package(
      url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.3",
      traits: ["SQLiteSwiftCSQLite"]),
  ],
  targets: [
    .target(
      name: "NoteModels",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ],
      path: "Sources/NoteModels"
    ),
    .target(
      name: "NoteSync",
      dependencies: [
        "NoteModels",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "SQLite", package: "SQLite.swift"),
      ],
      path: "Sources/NoteSync"
    ),
    .target(
      name: "NoteCommands",
      dependencies: [
        "NoteModels",
        "NoteSync",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/NoteCommands"
    ),
    .executableTarget(
      name: "note",
      dependencies: [
        "NoteModels",
        "NoteSync",
        "NoteCommands",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/note",
      swiftSettings: [
        .unsafeFlags(["-parse-as-library"])
      ]
    ),
    .testTarget(
      name: "NoteModelsTests",
      dependencies: ["NoteModels"],
      path: "Tests/NoteModelsTests"
    ),
    .testTarget(
      name: "NoteSyncTests",
      dependencies: ["NoteSync"],
      path: "Tests/NoteSyncTests"
    ),
    .testTarget(
      name: "noteTests",
      dependencies: ["note"],
      path: "Tests/noteTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
