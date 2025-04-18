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
            name: "HelperClient",
            targets: ["HelperClient"]
        ),
        .library(
            name: "HelperServer",
            targets: ["HelperServer"]
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
        .package(url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC", branch: "main"),
        .package(url: "https://github.com/MxIris-Reverse-Engineering/MachInjector", branch: "main"),
    ],
    targets: [
        .target(
            name: "HelperService",
            dependencies: [
                "HelperCommunication",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
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
                "MainService",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
            ]
        ),
        .target(
            name: "MainService",
            dependencies: [
                "HelperCommunication",
                "HelperService",
            ],
            path: "Sources/HelperServices/MainService"
        ),
        .target(
            name: "InjectionService",
            dependencies: [
                "HelperCommunication",
                "HelperService",
                .product(name: "MachInjector", package: "MachInjector"),
            ],
            path: "Sources/HelperServices/InjectionService"
        ),
        .target(
            name: "FilesService",
            dependencies: [
                "HelperService",
                "HelperCommunication",
            ],
            path: "Sources/HelperServices/FilesService"
        ),
    ]
)
