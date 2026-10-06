// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "CollaborationTransport", platforms: [.macOS(.v14)],
  products: [
    .library(name: "TransportProbe", targets: ["TransportProbe"]),
    .executable(name: "folio-transport-probe", targets: ["folio-transport-probe"]),
  ],
  targets: [
    .target(name: "TransportProbe"),
    .executableTarget(name: "folio-transport-probe", dependencies: ["TransportProbe"]),
    .testTarget(name: "TransportProbeTests", dependencies: ["TransportProbe"]),
  ])
