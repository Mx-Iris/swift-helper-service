#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
@testable import InjectionServiceImplementation

/// Contract suite for `MachOPlatform`, the reader behind the daemon's platform
/// guard and its refusal to fall back to remap for a cross-platform target.
///
/// History: the daemon delivered whatever payload it was handed and, when the
/// target refused it, projected the same payload in with `mach_vm_remap`. For
/// an iOS Simulator target that means feeding the injector's own symbol
/// addresses to a process loaded by `dyld_sim` against a different shared
/// cache; the target dies. Nothing about the architecture reveals the mismatch
/// — on Apple silicon both sides are arm64 — so `LC_BUILD_VERSION` is the only
/// signal, and these tests pin how it is read.
@Suite("MachOPlatform")
struct MachOPlatformTests {
    // MARK: - Live processes

    @Test("This process reads as the platform it was built for")
    func thisProcessReadsItsOwnPlatform() {
        // The daemon reads its own platform as the reference for "does the
        // target run somewhere else", so this must never come back nil.
        #expect(MachOPlatform.ofProcess(getpid()) == MachOPlatform.platformMacOS)
    }

    @Test("A pid nobody owns yields no answer rather than a wrong one")
    func unknownProcessIsUnknown() {
        // pid 0 is the kernel's, which proc_pidpath cannot describe. The guard
        // treats nil as "cannot tell" and lets the injection through, so an
        // answer invented here would silently become a decision.
        #expect(MachOPlatform.ofProcess(0) == nil)
    }

    // MARK: - Synthetic Mach-O files

    @Test("A thin file reports its own LC_BUILD_VERSION")
    func thinFileReportsBuildVersion() throws {
        let path = try MachOFixture.write(MachOFixture.thin(platform: MachOPlatform.platformiOSSimulator))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(MachOPlatform.ofFile(atPath: path) == MachOPlatform.platformiOSSimulator)
    }

    @Test("A fat file reports the platform of its slices")
    func fatFileReportsSlicePlatform() throws {
        // The shipped macOS payload is fat (x86_64 + arm64 + arm64e) and must
        // still read as macOS.
        let path = try MachOFixture.write(MachOFixture.fat(sliceCount: 3, platform: MachOPlatform.platformMacOS))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(MachOPlatform.ofFile(atPath: path) == MachOPlatform.platformMacOS)
    }

    @Test("A byte-swapped header is read, not mistaken for garbage")
    func swappedHeaderIsRead() throws {
        let path = try MachOFixture.write(MachOFixture.thin(platform: MachOPlatform.platformMacOS, swapped: true))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(MachOPlatform.ofFile(atPath: path) == MachOPlatform.platformMacOS)
    }

    @Test("A pre-LC_BUILD_VERSION binary falls back to its minimum-OS command")
    func minimumOSCommandIsFallback() throws {
        let path = try MachOFixture.write(MachOFixture.thin(minimumOSCommand: UInt32(LC_VERSION_MIN_MACOSX)))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(MachOPlatform.ofFile(atPath: path) == MachOPlatform.platformMacOS)
    }

    @Test("LC_BUILD_VERSION wins over a minimum-OS command in the same file")
    func buildVersionBeatsMinimumOSCommand() throws {
        // Binaries built for a wide deployment range carry both. Reading the
        // older one first would call a simulator payload macOS and let the
        // guard pass a mismatch through.
        let path = try MachOFixture.write(
            MachOFixture.thin(platform: MachOPlatform.platformiOSSimulator, minimumOSCommand: UInt32(LC_VERSION_MIN_MACOSX))
        )
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(MachOPlatform.ofFile(atPath: path) == MachOPlatform.platformiOSSimulator)
    }

    // MARK: - Malformed input

    @Test("A truncated file yields no answer rather than a crash")
    func truncatedFileIsUnknown() throws {
        // The daemon parses a path its client chose. A malformed file has to
        // produce "cannot tell", never a crashed daemon.
        var bytes = MachOFixture.thin(platform: MachOPlatform.platformiOSSimulator)
        bytes.removeLast(bytes.count / 2)
        let path = try MachOFixture.write(bytes)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(MachOPlatform.ofFile(atPath: path) == nil)
    }

    @Test("A load command claiming zero size does not spin forever")
    func zeroSizedLoadCommandTerminates() throws {
        let path = try MachOFixture.write(
            MachOFixture.thin(platform: MachOPlatform.platformiOSSimulator, corruptCommandSize: 0)
        )
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(MachOPlatform.ofFile(atPath: path) == nil)
    }

    @Test("A file that is not Mach-O at all yields no answer")
    func nonMachOFileIsUnknown() throws {
        let path = try MachOFixture.write([UInt8]("not a mach-o file, just some text".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(MachOPlatform.ofFile(atPath: path) == nil)
    }

    @Test("A missing file yields no answer")
    func missingFileIsUnknown() {
        #expect(MachOPlatform.ofFile(atPath: "/nonexistent/InjectionServiceProbe/payload") == nil)
    }

    // MARK: - The comparison the guard actually makes

    @Test("A macOS payload and a simulator target do not match")
    func macOSPayloadDoesNotMatchSimulatorTarget() throws {
        // The exact pairing that killed simulator processes: same architecture,
        // different platform, and only this comparison can tell.
        let macOSPayload = try MachOFixture.write(MachOFixture.fat(sliceCount: 3, platform: MachOPlatform.platformMacOS))
        let simulatorPayload = try MachOFixture.write(MachOFixture.thin(platform: MachOPlatform.platformiOSSimulator))
        defer {
            try? FileManager.default.removeItem(atPath: macOSPayload)
            try? FileManager.default.removeItem(atPath: simulatorPayload)
        }
        #expect(MachOPlatform.ofFile(atPath: macOSPayload) != MachOPlatform.ofFile(atPath: simulatorPayload))
    }

    @Test("A real simulator runtime binary reads as iOS Simulator")
    func realSimulatorBinaryIsDetected() throws {
        // Skipped rather than failed when no iOS runtime is installed: the
        // synthetic cases pin the parsing, and this one exists to catch the day
        // Apple changes what a simruntime binary looks like.
        guard let path = MachOFixture.installediOSSimulatorRuntimeBinaryPath() else { return }
        #expect(MachOPlatform.ofFile(atPath: path) == MachOPlatform.platformiOSSimulator)
    }
}

// MARK: - Fixtures

/// Builds the smallest Mach-O files that still exercise the reader: a header,
/// the load commands under test, and nothing else. Real binaries would make the
/// malformed cases impossible to express.
private enum MachOFixture {
    static func write(_ bytes: [UInt8]) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOPlatformTests-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url.path
    }

    /// A 64-bit Mach-O carrying up to two load commands.
    ///
    /// `corruptCommandSize` overrides the first command's `cmdsize`, which is
    /// how a malformed file makes a naive parser loop.
    static func thin(
        platform: UInt32? = nil,
        minimumOSCommand: UInt32? = nil,
        swapped: Bool = false,
        corruptCommandSize: UInt32? = nil
    ) -> [UInt8] {
        var commands: [UInt8] = []
        var commandCount: UInt32 = 0

        // Order matters: the minimum-OS command comes first, so a parser that
        // returned on the first thing it recognized would answer with the
        // fallback instead of LC_BUILD_VERSION.
        if let minimumOSCommand {
            commands += word(minimumOSCommand, swapped: swapped)
            commands += word(16, swapped: swapped)
            commands += word(0x000A_0F00, swapped: swapped)
            commands += word(0x000A_0F00, swapped: swapped)
            commandCount += 1
        }

        if let platform {
            // build_version_command: cmd, cmdsize, platform, minos, sdk, ntools
            commands += word(UInt32(LC_BUILD_VERSION), swapped: swapped)
            commands += word(corruptCommandSize ?? 24, swapped: swapped)
            commands += word(platform, swapped: swapped)
            commands += word(0x000F_0000, swapped: swapped)
            commands += word(0x001A_0500, swapped: swapped)
            commands += word(0, swapped: swapped)
            commandCount += 1
        }

        var bytes: [UInt8] = []
        // MH_CIGAM_64 already *is* MH_MAGIC_64's bytes read back on the other
        // endianness, so it goes in as-is; swapping it again would spell
        // MH_MAGIC_64 and the file would read as native after all.
        bytes += word(swapped ? MH_CIGAM_64 : MH_MAGIC_64, swapped: false)
        bytes += word(UInt32(bitPattern: CPU_TYPE_ARM64), swapped: swapped)
        bytes += word(0, swapped: swapped)                        // cpusubtype
        bytes += word(UInt32(MH_DYLIB), swapped: swapped)         // filetype
        bytes += word(commandCount, swapped: swapped)             // ncmds
        bytes += word(UInt32(commands.count), swapped: swapped)   // sizeofcmds
        bytes += word(0, swapped: swapped)                        // flags
        bytes += word(0, swapped: swapped)                        // reserved
        return bytes + commands
    }

    /// A fat file whose slices all carry the same platform, matching how a real
    /// multi-architecture build of one target looks.
    static func fat(sliceCount: Int, platform: UInt32) -> [UInt8] {
        let slice = thin(platform: platform)
        let headerSize = 8 + sliceCount * 20
        let alignment = 0x4000
        var sliceOffsets: [Int] = []
        var offset = (headerSize + alignment - 1) / alignment * alignment
        for _ in 0 ..< sliceCount {
            sliceOffsets.append(offset)
            offset += (slice.count + alignment - 1) / alignment * alignment
        }

        var bytes: [UInt8] = []
        bytes += bigEndianWord(FAT_MAGIC)
        bytes += bigEndianWord(UInt32(sliceCount))
        for (index, sliceOffset) in sliceOffsets.enumerated() {
            bytes += bigEndianWord(UInt32(bitPattern: index == 0 ? CPU_TYPE_X86_64 : CPU_TYPE_ARM64))
            bytes += bigEndianWord(UInt32(index))          // cpusubtype
            bytes += bigEndianWord(UInt32(sliceOffset))    // offset
            bytes += bigEndianWord(UInt32(slice.count))    // size
            bytes += bigEndianWord(14)                     // align (2^14 = 0x4000)
        }

        var file = bytes
        for sliceOffset in sliceOffsets {
            file += [UInt8](repeating: 0, count: sliceOffset - file.count)
            file += slice
        }
        return file
    }

    /// An arbitrary Mach-O from any installed iOS simulator runtime, or `nil`
    /// when none is installed.
    static func installediOSSimulatorRuntimeBinaryPath() -> String? {
        let runtimeVolumes = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes")
        let fileManager = FileManager.default
        guard let volumes = try? fileManager.contentsOfDirectory(atPath: runtimeVolumes.path) else {
            return nil
        }
        for volume in volumes where volume.hasPrefix("iOS_") {
            let profiles = runtimeVolumes
                .appendingPathComponent(volume)
                .appendingPathComponent("Library/Developer/CoreSimulator/Profiles/Runtimes")
            guard let runtimes = try? fileManager.contentsOfDirectory(atPath: profiles.path) else { continue }
            for runtime in runtimes where runtime.hasSuffix(".simruntime") {
                let candidate = profiles
                    .appendingPathComponent(runtime)
                    .appendingPathComponent("Contents/Resources/RuntimeRoot/usr/lib/dyld_sim")
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate.path
                }
            }
        }
        return nil
    }

    // MARK: - Byte helpers

    private static func word(_ value: UInt32, swapped: Bool) -> [UInt8] {
        withUnsafeBytes(of: swapped ? value.byteSwapped : value) { Array($0) }
    }

    private static func bigEndianWord(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}
#endif
