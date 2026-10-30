// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CredentialHarbor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CredentialHarbor", targets: ["CredentialHarbor"]), .executable(name: "harbor", targets: ["harbor"])],
    targets: [
        .target(name: "HarborCore"),
        .executableTarget(name: "CredentialHarbor", dependencies: ["HarborCore"]),
        .executableTarget(name: "harbor", dependencies: ["HarborCore"]),
        .executableTarget(name: "HarborChecks", dependencies: ["HarborCore"], path: "Tests/HarborCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
