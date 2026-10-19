// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ControleRemoto",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ControleRemoto",
            path: "Sources/ControleRemoto",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]
        )
    ]
)
