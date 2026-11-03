// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ShravaCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "ShravaCore",
            targets: ["ShravaCore"]
        )
    ],
    targets: [
        .target(
            name: "ShravaCore",
            dependencies: [],
            path: "Sources/ShravaCore"
        ),
        .testTarget(
            name: "ShravaCoreTests",
            dependencies: ["ShravaCore"],
            path: "Tests/ShravaCoreTests"
        )
    ]
)

package.swiftLanguageModes = [.v5]
