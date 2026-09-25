// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Folio", targets: ["MarkdownReader"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "ReaderCore"),
        .executableTarget(
            name: "MarkdownReader",
            dependencies: ["ReaderCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
        .testTarget(name: "MarkdownReaderTests", dependencies: ["MarkdownReader"])
    ]
)
