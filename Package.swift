// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Phosphor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Phosphor", targets: ["Phosphor"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Phosphor",
            path: "Sources/Phosphor",
            resources: [
                .copy("../../Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
