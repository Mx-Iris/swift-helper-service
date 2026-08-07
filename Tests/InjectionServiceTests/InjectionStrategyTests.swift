#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
@testable import InjectionServiceImplementation

// MARK: - Test Support

/// A live process with a chosen code-signing posture, used as an injection target.
///
/// The interesting target is "unsandboxed, but enforcing AMFI library
/// validation" — the shape every Apple application has, and the shape that a
/// sandbox-only probe routes onto an injection path that can never work. No
/// system binary carries that combination (platform daemons are the reverse:
/// sandbox-restricted but without `CS_REQUIRE_LV`), so the tests mint one by
/// re-signing a copy of `/bin/sleep`. Ad-hoc re-signing also drops the platform
/// status, which is what makes the library-validation deny reachable at all.
private final class SignedTestProcess {
    let processIdentifier: pid_t

    private let runningProcess: Process
    private let containerDirectoryURL: URL

    /// - Parameter enforcesLibraryValidation: whether to sign with the `library`
    ///   option, which sets `CS_REQUIRE_LV` on the resulting process.
    init(enforcesLibraryValidation: Bool) throws {
        containerDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InjectionStrategyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerDirectoryURL, withIntermediateDirectories: true)

        let executableURL = containerDirectoryURL.appendingPathComponent("sleep", isDirectory: false)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executableURL)

        let signingOptions = enforcesLibraryValidation ? "library,runtime" : "runtime"
        try Self.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", "--options", signingOptions, executableURL.path])

        runningProcess = Process()
        runningProcess.executableURL = executableURL
        runningProcess.arguments = ["120"]
        try runningProcess.run()
        processIdentifier = runningProcess.processIdentifier
    }

    deinit {
        runningProcess.terminate()
        runningProcess.waitUntilExit()
        try? FileManager.default.removeItem(at: containerDirectoryURL)
    }

    private static func run(_ launchPath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(launchPath) \(arguments.joined(separator: " ")) failed")
    }
}

private let codeSigningToolIsAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign")

/// Stands in for an installed payload. Only its path is ever used — the probes
/// ask the kernel about the path, they do not read it.
private let payloadPath = "/Library/Frameworks/RuntimeViewerServer.framework/Versions/A/RuntimeViewerServer"

// MARK: - InjectionStrategy Tests

@Suite("InjectionStrategy", .enabled(if: codeSigningToolIsAvailable))
struct InjectionStrategyTests {
    /// Regression: routing used to consult the sandbox alone, so a target that
    /// is unsandboxed yet enforces library validation — Music, Finder, Safari,
    /// every Apple app — was sent down the dlopen path. AMFI then refused the
    /// developer-signed payload inside the target and nothing was loaded, while
    /// the injector reported success.
    @Test("A target enforcing library validation routes to remap even when the sandbox permits everything")
    func libraryValidationTargetRoutesToRemap() throws {
        let target = try SignedTestProcess(enforcesLibraryValidation: true)

        #expect(InjectionStrategy.isLibraryValidationEnforced(pid: target.processIdentifier))
        // The condition that used to decide alone: it says "permitted", which is
        // exactly why library validation has to be consulted separately.
        #expect(!InjectionStrategy.isFileMapExecutableBlocked(pid: target.processIdentifier, path: payloadPath))

        #expect(InjectionStrategy.forTarget(pid: target.processIdentifier, payloadPath: payloadPath) == .machVirtualMemoryRemap)
    }

    /// The control: identical process, identical sandbox posture, signed without
    /// the `library` option. Proves the routing above keys off library
    /// validation rather than always answering remap.
    @Test("A target without library validation stays on the dlopen path")
    func plainTargetStaysOnDlopenPath() throws {
        let target = try SignedTestProcess(enforcesLibraryValidation: false)

        #expect(!InjectionStrategy.isLibraryValidationEnforced(pid: target.processIdentifier))
        #expect(!InjectionStrategy.isFileMapExecutableBlocked(pid: target.processIdentifier, path: payloadPath))

        #expect(InjectionStrategy.forTarget(pid: target.processIdentifier, payloadPath: payloadPath) == .dlopen)
    }

    /// `csops` reports an error for a pid nobody owns, so the library-validation
    /// probe fails closed onto the simpler, better-tested path instead of onto
    /// the remap machinery.
    ///
    /// The strategy as a whole still answers remap for such a pid, because
    /// `sandbox_check` reports "denied" rather than an error when it cannot find
    /// the process. That is inconsequential — both paths fail at `task_for_pid`
    /// on a target that is gone — and is asserted here so the asymmetry between
    /// the two probes stays visible rather than being rediscovered.
    @Test("An unprobeable target reads as not enforcing library validation")
    func unprobeableTargetReadsAsNotEnforcingLibraryValidation() {
        let unusedProcessIdentifier: pid_t = .max

        #expect(!InjectionStrategy.isLibraryValidationEnforced(pid: unusedProcessIdentifier))
        #expect(InjectionStrategy.forTarget(pid: unusedProcessIdentifier, payloadPath: payloadPath) == .machVirtualMemoryRemap)
    }
}
#endif
