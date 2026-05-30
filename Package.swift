// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Claffeinate",
    platforms: [
        .macOS(.v13) // MenuBarExtra requires macOS 13+
    ],
    targets: [
        // Single executable target. No third-party dependencies — standard
        // libraries only (Swift / SwiftUI / AppKit / IOKit).
        .executableTarget(
            name: "Claffeinate",
            path: "Sources/Claffeinate"
        )
    ]
)
