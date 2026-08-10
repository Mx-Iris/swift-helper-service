#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
import InjectionServiceInterface
@testable import InjectionServiceImplementation

// MARK: - Test Support

/// A live process with a chosen code-signing posture, used as an injection target.
///
/// The interesting target is "unsandboxed, but carrying `CS_REQUIRE_LV`" — the
/// shape every Apple application has. No system binary carries that combination
/// (platform daemons are the reverse: sandbox-restricted but without
/// `CS_REQUIRE_LV`), so the tests mint one by re-signing a copy of `/bin/sleep`.
private final class SignedTestProcess {
    let processIdentifier: pid_t

    private let runningProcess: Process
    private let containerDirectoryURL: URL

    /// - Parameter requestsLibraryValidation: whether to sign with the `library`
    ///   option, which sets `CS_REQUIRE_LV` on the resulting process.
    init(requestsLibraryValidation: Bool) throws {
        containerDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InjectionStrategyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerDirectoryURL, withIntermediateDirectories: true)

        let executableURL = containerDirectoryURL.appendingPathComponent("sleep", isDirectory: false)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executableURL)

        let signingOptions = requestsLibraryValidation ? "library,runtime" : "runtime"
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
    /// Regression: routing used to read `CS_REQUIRE_LV` and send every target
    /// carrying it — Music, Finder, Safari, every Apple app — straight to the
    /// remap path, on the theory that AMFI would refuse a `dlopen` anyway. The
    /// flag being set does not mean library validation is enforced: measured on
    /// macOS 26.5.2 with SIP disabled, a process signed `library,runtime`
    /// happily `dlopen`ed unsigned, ad-hoc-signed, and foreign-Team-ID dylibs.
    /// Meanwhile remap is the path that can crash the target, so predicting it
    /// wrongly is the expensive mistake. The daemon now tries `dlopen` and
    /// falls back only on an actual refusal.
    @Test("A target that merely requests library validation is still tried with dlopen first")
    func libraryValidationTargetIsTriedWithDlopenFirst() throws {
        let target = try SignedTestProcess(requestsLibraryValidation: true)

        // The flag really is set — this is not a case of the probe failing to
        // see it. It just no longer decides the path.
        #expect(InjectionStrategy.isLibraryValidationEnforced(pid: target.processIdentifier))
        #expect(!InjectionStrategy.isFileMapExecutableBlocked(pid: target.processIdentifier, path: payloadPath))

        #expect(InjectionStrategy.initialAttempt(forTarget: target.processIdentifier, payloadPath: payloadPath) == .dlopen)
    }

    /// The control: identical process, signed without the `library` option.
    /// Together with the test above it pins down that neither posture routes to
    /// remap on its own — only the sandbox does.
    @Test("A target without library validation is tried with dlopen first")
    func plainTargetIsTriedWithDlopenFirst() throws {
        let target = try SignedTestProcess(requestsLibraryValidation: false)

        #expect(!InjectionStrategy.isLibraryValidationEnforced(pid: target.processIdentifier))
        #expect(!InjectionStrategy.isFileMapExecutableBlocked(pid: target.processIdentifier, path: payloadPath))

        #expect(InjectionStrategy.initialAttempt(forTarget: target.processIdentifier, payloadPath: payloadPath) == .dlopen)
    }

    /// `csops` reports an error for a pid nobody owns, so the library-validation
    /// probe reads as `false` there.
    ///
    /// The strategy as a whole answers remap for such a pid, because
    /// `sandbox_check` reports "denied" rather than an error when it cannot find
    /// the process. That is inconsequential — both paths fail at `task_for_pid`
    /// on a target that is gone — and is asserted here so the asymmetry between
    /// the two probes stays visible rather than being rediscovered.
    @Test("An unprobeable target reads as not requesting library validation")
    func unprobeableTargetReadsAsNotRequestingLibraryValidation() {
        let unusedProcessIdentifier: pid_t = .max

        #expect(!InjectionStrategy.isLibraryValidationEnforced(pid: unusedProcessIdentifier))
        #expect(InjectionStrategy.initialAttempt(forTarget: unusedProcessIdentifier, payloadPath: payloadPath) == .machVirtualMemoryRemap)
    }
}

// MARK: - Wire Format Tests

@Suite("InjectApplicationRequest wire format")
struct InjectApplicationRequestTests {
    /// The raw values travel between a client and a daemon that are versioned
    /// separately, so they are spelled out in the source rather than derived
    /// from declaration order. Pin them here: reordering the cases must not be
    /// able to silently change what an older peer decodes.
    @Test func injectionStrategyRawValuesAreStable() {
        #expect(InjectionStrategy.dlopen.rawValue == "dlopen")
        #expect(InjectionStrategy.machVirtualMemoryRemap.rawValue == "machVirtualMemoryRemap")
    }

    @Test func requestRoundTripsWithoutPreferredStrategy() throws {
        let original = InjectApplicationRequest(pid: 1234, dylibURL: URL(fileURLWithPath: "/tmp/payload.dylib"))
        let decoded = try JSONDecoder().decode(
            InjectApplicationRequest.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded.pid == 1234)
        #expect(decoded.dylibURL.path == "/tmp/payload.dylib")
        #expect(decoded.remapEntrySymbol == nil)
        // `nil` is what lets the daemon pick, and what enables the fallback.
        #expect(decoded.preferredStrategy == nil)
    }

    @Test func requestRoundTripsWithPreferredStrategy() throws {
        let original = InjectApplicationRequest(
            pid: 4321,
            dylibURL: URL(fileURLWithPath: "/tmp/payload.dylib"),
            remapEntrySymbol: "payload_entry",
            preferredStrategy: .machVirtualMemoryRemap
        )
        let decoded = try JSONDecoder().decode(
            InjectApplicationRequest.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded.remapEntrySymbol == "payload_entry")
        #expect(decoded.preferredStrategy == .machVirtualMemoryRemap)
    }

    /// A client built before `preferredStrategy` existed sends a payload without
    /// the key. Decoding must yield `nil` — i.e. "daemon decides" — rather than
    /// failing the request outright.
    @Test func requestFromAPeerPredatingPreferredStrategyDecodes() throws {
        let legacyPayload = Data(#"{"pid":99,"dylibURL":"file:///tmp/payload.dylib"}"#.utf8)
        let decoded = try JSONDecoder().decode(InjectApplicationRequest.self, from: legacyPayload)

        #expect(decoded.pid == 99)
        #expect(decoded.preferredStrategy == nil)
        #expect(decoded.remapEntrySymbol == nil)
    }

    @Test func identifierUsesInjectionServiceNamespace() {
        #expect(InjectApplicationRequest.identifier == "com.JH.HelperService.InjectionService.InjectApplication")
    }
}
#endif
