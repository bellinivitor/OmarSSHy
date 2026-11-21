// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OmarSSHy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OmarSSHy", targets: ["OmarSSHy"])],
    traits: [],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3")
    ],
    targets: [
        .target(name: "OmarSSHyCore"),
        .executableTarget(
            name: "OmarSSHy",
            dependencies: ["OmarSSHyCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "OmarSSHyCoreTests", dependencies: ["OmarSSHyCore"])
    ],
    swiftLanguageModes: [.v6]
)
