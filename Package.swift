// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-helper-service",
    platforms: [.macOS(.v11), .macCatalyst(.v14)],
    products: [
        .library(
            name: "HelperService",
            targets: ["HelperService"]
        ),
        .library(
            name: "HelperCommunication",
            targets: ["HelperCommunication"]
        ),
        .library(
            name: "HelperClient",
            targets: ["HelperClient"]
        ),
        .library(
            name: "HelperServer",
            targets: ["HelperServer"]
        ),
        .library(
            name: "MainService",
            targets: ["MainService"]
        ),
        .library(
            name: "InjectionService",
            targets: ["InjectionService"]
        ),
        .library(
            name: "FilesService",
            targets: ["FilesService"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.7.0"),
        .package(url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC", branch: "main"),
        .package(url: "https://github.com/MxIris-Reverse-Engineering/MachInjector", branch: "main"),
    ],
    targets: [
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
                "HelperService",
                "HelperCommunication",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
            ]
        ),
        .target(
            name: "HelperServer",
            dependencies: [
                "HelperService",
                "HelperCommunication",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
            ]
        ),
        .target(
            name: "MainService",
            dependencies: [
                "HelperCommunication",
                "HelperService",
            ]
        ),
        .target(
            name: "InjectionService",
            dependencies: [
                "HelperCommunication",
                "HelperService",
                .product(name: "MachInjector", package: "MachInjector"),
            ]
        ),
        .target(
            name: "FilesService",
            dependencies: [
                "HelperService",
                "HelperCommunication",
            ]
        ),
    ]
)
