// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MurmurCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "MurmurCore",
            targets: ["MurmurCore"]
        )
    ],
    targets: [
        .target(
            name: "MurmurCore",
            dependencies: [],
            path: "Sources/MurmurCore"
        ),
        .testTarget(
            name: "MurmurCoreTests",
            dependencies: ["MurmurCore"],
            path: "Tests/MurmurCoreTests"
        )
    ]
)

package.swiftLanguageModes = [.v5]
