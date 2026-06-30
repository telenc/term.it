// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreeTermius",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "FreeTermius", targets: ["FreeTermius"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "FreeTermius",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "Sources/FreeTermius",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
