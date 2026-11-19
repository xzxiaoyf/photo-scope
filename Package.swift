// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotoScope",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PhotoScope", targets: ["PhotoScope"])
    ],
    targets: [
        .executableTarget(
            name: "PhotoScope",
            path: "Sources/PhotoScope"
        )
    ]
)
