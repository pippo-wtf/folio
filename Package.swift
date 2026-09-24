// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Folio", platforms: [.macOS(.v14)], products: [.executable(name: "Folio", targets: ["MarkdownReader"])], targets: [
    .target(name: "ReaderCore"),
    .executableTarget(name: "MarkdownReader", dependencies: ["ReaderCore"], resources: [.copy("Resources")]),
    .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"])
])
