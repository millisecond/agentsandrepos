// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// Local notifications are compiled in only for the distributed build:
///   AGENTSANDREPOS_NOTIFICATIONS=1 swift build -c release
/// (packaging/make-app.sh sets this). UNUserNotificationCenter only works
/// from a real, signed .app bundle, so a plain source build gets the no-op
/// coordinator and drops the deliverers, the dashboard prompt banner, and the
/// Settings section. Core (planner, scorer, config keys) stays compiled and
/// tested either way.
let notificationsEnabled =
    ProcessInfo.processInfo.environment["AGENTSANDREPOS_NOTIFICATIONS"] == "1"

let package = Package(
    name: "agentsandrepos",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AgentsAndReposCore"),
        .executableTarget(
            name: "agentsandrepos",
            dependencies: ["AgentsAndReposCore"],
            swiftSettings: notificationsEnabled ? [] : [.define("NOTIFICATIONS_DISABLED")],
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
