// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// Build-time kill switch for local notifications:
///   AGENTSANDREPOS_NOTIFICATIONS=0 swift build -c release
/// compiles the coordinator down to a no-op and drops the deliverers, the
/// dashboard prompt banner, and the Settings section. Core (planner, scorer,
/// config keys) stays compiled and tested either way.
let notificationsDisabled =
    ProcessInfo.processInfo.environment["AGENTSANDREPOS_NOTIFICATIONS"] == "0"

let package = Package(
    name: "agentsandrepos",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AgentsAndReposCore"),
        .executableTarget(
            name: "agentsandrepos",
            dependencies: ["AgentsAndReposCore"],
            swiftSettings: notificationsDisabled ? [.define("NOTIFICATIONS_DISABLED")] : [],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "AgentsAndReposCoreTests",
            dependencies: ["AgentsAndReposCore"]
        ),
    ]
)
