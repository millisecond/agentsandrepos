// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "agentsandrepos",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AgentsAndReposCore"),
        .executableTarget(
            name: "agentsandrepos",
            dependencies: ["AgentsAndReposCore"],
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
