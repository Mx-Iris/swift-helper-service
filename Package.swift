// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

func envEnable(_ key: String, default defaultValue: Bool = false) -> Bool {
    let value = Context.environment[key]
    guard let value else {
        return defaultValue
    }
    if value == "1" {
        return true
    } else if value == "0" {
        return false
    } else {
        return defaultValue
    }
}

let usingLocalDependencies = envEnable("USING_LOCAL_DEPENDENCIES")

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool = usingLocalDependencies, traits: Set<PackageDescription.Package.Dependency.Trait> = [.defaults])
    }

    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        let currentFilePath = #filePath
        let isClonedDependency = currentFilePath.contains("/checkouts/") ||
            currentFilePath.contains("/SourcePackages/") ||
            currentFilePath.contains("/.build/")

        if isClonedDependency {
            return remote
        }
        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled, let traits):
                guard isEnabled else { continue }
                let url = if isRelative {
                    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: #filePath))
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path, traits: traits)
                }
            }
        }
        return remote
    }
}

let package = Package(
    name: "swift-helper-service",
    platforms: [.macOS(.v10_15), .macCatalyst(.v13)],
    products: [
        .library(
            name: "HelperCommunication",
            targets: ["HelperCommunication"],
        ),
        .library(
            name: "HelperService",
            targets: ["HelperService"],
        ),
        .library(
            name: "HelperClient",
            targets: ["HelperClient"],
        ),
        .library(
            name: "HelperServer",
            targets: ["HelperServer"],
        ),
        .library(
            name: "HelperPeer",
            targets: ["HelperPeer"],
        ),
        .library(
            name: "InjectionService",
            targets: ["InjectionServiceInterface", "InjectionServiceImplementation"],
        ),
        .library(
            name: "InjectionServiceInterface",
            targets: ["InjectionServiceInterface"],
        ),
        .library(
            name: "InjectionServiceImplementation",
            targets: ["InjectionServiceImplementation"],
        ),
        .library(
            name: "FilesService",
            targets: ["FilesServiceInterface", "FilesServiceImplementation"],
        ),
        .library(
            name: "FilesServiceInterface",
            targets: ["FilesServiceInterface"],
        ),
        .library(
            name: "FilesServiceImplementation",
            targets: ["FilesServiceImplementation"],
        ),
        .library(
            name: "ApplicationsService",
            targets: ["ApplicationsServiceInterface", "ApplicationsServiceImplementation"],
        ),
        .library(
            name: "ApplicationsServiceInterface",
            targets: ["ApplicationsServiceInterface"],
        ),
        .library(
            name: "ApplicationsServiceImplementation",
            targets: ["ApplicationsServiceImplementation"],
        ),
        .library(
            name: "InjectedEndpointRegistryService",
            targets: ["InjectedEndpointRegistryServiceInterface", "InjectedEndpointRegistryServiceImplementation"],
        ),
        .library(
            name: "InjectedEndpointRegistryServiceInterface",
            targets: ["InjectedEndpointRegistryServiceInterface"],
        ),
        .library(
            name: "InjectedEndpointRegistryServiceImplementation",
            targets: ["InjectedEndpointRegistryServiceImplementation"],
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC",
            from: "0.5.104",
        ),
        .package(
            local: .package(
                path: "/Volumes/Repositories/Private/Personal/Library/macOS/MachInjector",
                isRelative: false,
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachInjector",
                from: "0.5.1",
            ),
        ),
        .package(
            url: "https://github.com/Mx-Iris/FrameworkToolbox",
            from: "0.9.0",
        ),
    ],
    targets: [
        .target(
            name: "HelperService",
            dependencies: [
                "HelperCommunication",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ],
        ),
        .target(
            name: "HelperCommunication",
            dependencies: [
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ],
        ),
        .target(
            name: "HelperClient",
            dependencies: [
                "HelperService",
                "HelperCommunication",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ],
        ),
        .target(
            name: "HelperServer",
            dependencies: [
                "HelperService",
                "HelperCommunication",
                "MainService",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ],
        ),
        .target(
            name: "HelperPeer",
            dependencies: [
                "HelperCommunication",
                "HelperService",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ],
        ),
        .target(
            name: "MainService",
            dependencies: [
                "HelperCommunication",
                "HelperService",
            ],
            path: "Sources/HelperServices/MainService",
        ),
        .target(
            name: "InjectionServiceInterface",
            dependencies: [
                "HelperCommunication",
            ],
            path: "Sources/HelperServices/InjectionService/Interface",
        ),
        .target(
            name: "InjectionServiceImplementation",
            dependencies: [
                "InjectionServiceInterface",
                "HelperCommunication",
                "HelperService",
                "HelperProcessProbe",
                .product(name: "MachInjector", package: "MachInjector"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ],
            path: "Sources/HelperServices/InjectionService/Implementation",
        ),
        .target(
            name: "HelperProcessProbe",
            path: "Sources/HelperProcessProbe",
        ),
        .target(
            name: "FilesServiceInterface",
            dependencies: [
                "HelperCommunication",
            ],
            path: "Sources/HelperServices/FilesService/Interface",
        ),
        .target(
            name: "FilesServiceImplementation",
            dependencies: [
                "FilesServiceInterface",
                "HelperService",
                "HelperCommunication",
            ],
            path: "Sources/HelperServices/FilesService/Implementation",
        ),
        .target(
            name: "ApplicationsServiceInterface",
            dependencies: [
                "HelperCommunication",
            ],
            path: "Sources/HelperServices/ApplicationsService/Interface",
        ),
        .target(
            name: "ApplicationsServiceImplementation",
            dependencies: [
                "ApplicationsServiceInterface",
                "HelperService",
                "HelperCommunication",
            ],
            path: "Sources/HelperServices/ApplicationsService/Implementation",
        ),
        .target(
            name: "InjectedEndpointRegistryServiceInterface",
            dependencies: [
                "HelperCommunication",
            ],
            path: "Sources/HelperServices/InjectedEndpointRegistryService/Interface",
        ),
        .target(
            name: "InjectedEndpointRegistryServiceImplementation",
            dependencies: [
                "InjectedEndpointRegistryServiceInterface",
                "HelperService",
                "HelperCommunication",
            ],
            path: "Sources/HelperServices/InjectedEndpointRegistryService/Implementation",
        ),
        .testTarget(
            name: "HelperCommunicationTests",
            dependencies: [
                "HelperCommunication",
                "HelperClient",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
            ],
        ),
        .testTarget(
            name: "InjectionServiceTests",
            dependencies: [
                "InjectionServiceInterface",
                "InjectionServiceImplementation",
            ],
        ),
        .testTarget(
            name: "MainServiceTests",
            dependencies: [
                "MainService",
                "HelperCommunication",
                .product(name: "SwiftyXPC", package: "SwiftyXPC"),
            ],
        ),
    ],
)
