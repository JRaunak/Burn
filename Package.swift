// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Burn",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Burn",
            path: "Sources/Burn",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "BurnTests", dependencies: ["Burn"], path: "Tests/BurnTests"),
    ]
)
