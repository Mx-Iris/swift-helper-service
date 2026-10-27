#if os(macOS)
import Foundation
import Testing
@testable import InjectionServiceImplementation

/// The architecture guard exists to catch the most common packaging mistake — an arm64-only
/// payload aimed at an arm64e process — so these cover the reading, not the refusal. The refusal
/// itself needs a live target and a real injection, which nothing in this repository does.
///
/// Fixtures are files already on the machine. Building Mach-O files in a test would mean testing
/// the builder.
@Suite("Mach-O architecture reading")
struct MachOArchitectureTests {
    @Test("Capability bits in the high byte are masked off")
    func capabilityBitsAreMasked() {
        // CPU_SUBTYPE_PTRAUTH_ABI and friends live in the high byte, and differ between an
        // executable and a library of the same architecture. Comparing them unmasked would
        // reject pairs that load perfectly well together.
        let withCapabilities = MachOArchitecture(
            cpuType: CPU_TYPE_ARM64,
            rawCPUSubtype: CPU_SUBTYPE_ARM64E | cpu_subtype_t(bitPattern: 0x8000_0000)
        )
        #expect(withCapabilities == .arm64e)
        #expect(withCapabilities.cpuSubtype == CPU_SUBTYPE_ARM64E)
    }

    @Test("arm64 and arm64e are different architectures")
    func arm64AndArm64eDoNotCompareEqual() {
        // The whole guard rests on this: same cputype, different subtype, and dyld will not
        // substitute one for the other.
        #expect(MachOArchitecture.arm64 != MachOArchitecture.arm64e)
        #expect(MachOArchitecture.arm64.cpuType == MachOArchitecture.arm64e.cpuType)
    }

    @Test("Reads the slices of a real fat binary")
    func readsSlicesOfAFatBinary() throws {
        // /bin/ls rather than a system dylib: the dylibs live in the dyld shared cache and have
        // no on-disk file at all, which is a useful reminder that "it is a system library" does
        // not mean "there is a Mach-O there to read".
        let architectures = try #require(
            MachOArchitectureReader.architecturesOfFile(atPath: "/bin/ls"),
            "/bin/ls should be parseable"
        )
        #expect(architectures.count > 1, "expected a fat binary, got \(architectures.map(\.description).sorted())")
        #expect(architectures.contains(.arm64e), "got \(architectures.map(\.description).sorted())")
    }

    @Test("A library in the shared cache has no file to read, and that reads as nil")
    func sharedCacheLibraryAnswersNil() {
        // Not a defect — it is why the guard lets unreadable inputs pass rather than refusing
        // them. Plenty of perfectly valid things cannot be parsed from disk.
        #expect(MachOArchitectureReader.architecturesOfFile(atPath: "/usr/lib/libobjc.A.dylib") == nil)
    }

    @Test("Answers nil rather than crashing on things that are not Mach-O")
    func unparseableInputsAnswerNil() throws {
        #expect(MachOArchitectureReader.architecturesOfFile(atPath: "/does/not/exist") == nil)
        #expect(MachOArchitectureReader.architecturesOfFile(atPath: "/etc/hosts") == nil)
        #expect(MachOArchitectureReader.architecturesOfFile(atPath: "/usr/lib") == nil)

        // A file whose first bytes look like a fat header but which stops immediately. The
        // daemon parses files its client chose, so a truncated one has to produce "cannot tell"
        // rather than a trap.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MachOArchitectureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let truncated = directory.appending(path: "truncated")
        var header = FAT_MAGIC.bigEndian
        try Data(bytes: &header, count: MemoryLayout<UInt32>.size).write(to: truncated)
        #expect(MachOArchitectureReader.architecturesOfFile(atPath: truncated.path) == nil)
    }

    @Test("Reads the slices of the running test process")
    func readsSlicesOfThisProcess() throws {
        let architectures = try #require(MachOArchitectureReader.architecturesOfProcess(getpid()))
        #expect(!architectures.isEmpty)
    }

    @Test("This process is not translated, and its executing architecture is an arm64 one")
    func executingArchitectureOfThisProcess() throws {
        #expect(MachOArchitectureReader.isTranslated(getpid()) == false, "the tests are not run under Rosetta")

        let executing = try #require(
            MachOArchitectureReader.executingArchitectureOfProcess(getpid()),
            "an arm64-family process should report an executing architecture"
        )
        #expect(executing == .arm64 || executing == .arm64e)
    }

    /// The inference the whole guard rests on. Tested on the grading function directly, because
    /// no binary on this machine happens to carry every combination worth checking.
    @Test("arm64e wins over arm64 whenever both are present")
    func arm64eIsGradedAboveArm64() {
        #expect(MachOArchitectureReader.preferredExecutingArchitecture(from: [.arm64, .arm64e]) == .arm64e)
        #expect(MachOArchitectureReader.preferredExecutingArchitecture(from: [.arm64e]) == .arm64e)
        #expect(MachOArchitectureReader.preferredExecutingArchitecture(from: [.arm64]) == .arm64)
        #expect(MachOArchitectureReader.preferredExecutingArchitecture(from: [.x86_64, .arm64e]) == .arm64e)
    }

    @Test("With no arm64-family slice there is nothing to infer")
    func noArm64FamilySliceYieldsNil() {
        // x86_64-only means translation, which the caller excludes before asking — answering
        // "x86_64" here would let the architecture guard compare against a slice the target is
        // not running.
        #expect(MachOArchitectureReader.preferredExecutingArchitecture(from: [.x86_64]) == nil)
        #expect(MachOArchitectureReader.preferredExecutingArchitecture(from: []) == nil)
    }
}
#endif
