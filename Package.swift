// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "termit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "termit", targets: ["termit"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "termit",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "Sources/termit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
