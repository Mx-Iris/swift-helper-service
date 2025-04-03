// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-helper-service",
    platforms: [.macOS(.v10_15), .macCatalyst(.v13)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "HelperService",
            targets: ["HelperService"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.7.0"),
        .package(url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC", branch: "main"),
        .package(url: "https://github.com/MxIris-Reverse-Engineering/MachInjector", branch: "main"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "HelperService",
            dependencies: [
                "HelperCommunication",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .target(
            name: "HelperCommunication",
            dependencies: [
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
            ]
        ),
        .target(
            name: "HelperClient",
            dependencies: [
                "HelperCommunication",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
            ]
        ),
    ]
)
