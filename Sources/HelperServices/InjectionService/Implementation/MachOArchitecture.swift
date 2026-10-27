#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation

/// One architecture slice: a `cputype` and the meaningful part of its `cpusubtype`.
///
/// The capability bits in the high byte of `cpusubtype` are masked off. They carry things like
/// `CPU_SUBTYPE_PTRAUTH_ABI`, which differ between an executable and a library built for the same
/// architecture, and comparing them would reject pairs that load perfectly well.
struct MachOArchitecture: Hashable, CustomStringConvertible {
    let cpuType: cpu_type_t
    let cpuSubtype: cpu_subtype_t

    init(cpuType: cpu_type_t, rawCPUSubtype: cpu_subtype_t) {
        self.cpuType = cpuType
        self.cpuSubtype = rawCPUSubtype & ~Self.capabilityBitsMask
    }

    /// `CPU_SUBTYPE_MASK` is `0xff000000`, an unsigned literal that does not reach Swift as a
    /// `cpu_subtype_t` (which is signed).
    private static let capabilityBitsMask = cpu_subtype_t(bitPattern: 0xff00_0000)

    static let arm64 = MachOArchitecture(cpuType: CPU_TYPE_ARM64, rawCPUSubtype: CPU_SUBTYPE_ARM64_ALL)
    static let arm64e = MachOArchitecture(cpuType: CPU_TYPE_ARM64, rawCPUSubtype: CPU_SUBTYPE_ARM64E)
    static let x86_64 = MachOArchitecture(cpuType: CPU_TYPE_X86_64, rawCPUSubtype: CPU_SUBTYPE_X86_64_ALL)

    var description: String {
        switch self {
        case .arm64e: "arm64e"
        case .arm64: "arm64"
        case .x86_64: "x86_64"
        default: "cputype \(cpuType)/subtype \(cpuSubtype)"
        }
    }
}

/// Reads which architecture slices a Mach-O file carries.
///
/// ## Why the daemon needs this
///
/// An arm64e process does not accept an arm64-only library. The failure gives nothing away: the
/// `dlopen` is refused with a message about the file not being loadable, or — on the remap path —
/// the payload goes in and the target dies. Checking first turns the single most common
/// packaging mistake into one sentence that says what to rebuild.
enum MachOArchitectureReader {
    /// Slices present in a Mach-O file, or `nil` when it cannot be parsed.
    ///
    /// `nil` means "cannot tell" — a missing file, something that is not Mach-O, a truncated one.
    /// Callers must not read it as a match or a mismatch.
    static func architecturesOfFile(atPath path: String) -> Set<MachOArchitecture>? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else {
            return nil
        }
        return data.withUnsafeBytes { buffer -> Set<MachOArchitecture>? in
            guard let magic: UInt32 = buffer.loadIfWithinBounds(byteOffset: 0, as: UInt32.self) else {
                return nil
            }
            switch magic {
            case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
                return architecturesOfFatFile(buffer, is64Bit: magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64)
            default:
                return architectureOfThinFile(buffer, atOffset: 0).map { [$0] }
            }
        }
    }

    /// Slices of the executable backing a running process.
    static func architecturesOfProcess(_ processIdentifier: pid_t) -> Set<MachOArchitecture>? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        return architecturesOfFile(atPath: String(cString: pathBuffer))
    }

    /// Which slice a process is actually executing, inferred from what its executable carries.
    ///
    /// **This is an inference, not an observation.** Reading it directly would mean going through
    /// the target's task port to its `dyld_all_image_infos` and parsing the mapped header, which
    /// is a great deal of machinery for a question the file already answers on this machine: on
    /// Apple silicon the kernel grades arm64e above arm64, so an executable carrying arm64e runs
    /// arm64e.
    ///
    /// Where the inference does not hold, it returns `nil` rather than guessing:
    ///
    /// - A **translated** (Rosetta) process runs x86_64 even though its file may carry arm64. The
    ///   caller is told to skip the check; neither injection path supports such a target anyway.
    /// - A file with no arm64-family slice at all.
    static func executingArchitectureOfProcess(_ processIdentifier: pid_t) -> MachOArchitecture? {
        guard !isTranslated(processIdentifier) else { return nil }
        guard let architectures = architecturesOfProcess(processIdentifier) else { return nil }
        return preferredExecutingArchitecture(from: architectures)
    }

    /// Which of these slices the kernel would run, on Apple silicon and without translation.
    ///
    /// Separate from the file reading so the grading can be tested on its own: the hosts this
    /// runs on do not happen to carry a binary with every interesting combination of slices.
    static func preferredExecutingArchitecture(from architectures: Set<MachOArchitecture>) -> MachOArchitecture? {
        // arm64e is graded strictly above arm64 — an arm64e-capable host picks it whenever it is
        // there. x86_64 is deliberately not considered: reaching it means translation, which the
        // caller has already excluded.
        if architectures.contains(.arm64e) { return .arm64e }
        if architectures.contains(.arm64) { return .arm64 }
        return nil
    }

    /// Whether the process runs under Rosetta.
    ///
    /// `P_TRANSLATED` in `kinfo_proc`'s `p_flag`. A translated process executes the x86_64 slice
    /// whatever else the file holds, so every arm64-based inference about it is wrong.
    static func isTranslated(_ processIdentifier: pid_t) -> Bool {
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        var processInformation = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&managementInformationBase, UInt32(managementInformationBase.count), &processInformation, &size, nil, 0)
        guard result == 0, size > 0 else { return false }
        return (processInformation.kp_proc.p_flag & P_TRANSLATED) != 0
    }

    // MARK: - Fat files

    private static func architecturesOfFatFile(_ buffer: UnsafeRawBufferPointer, is64Bit: Bool) -> Set<MachOArchitecture>? {
        // Fat headers are always big-endian, whatever the host is.
        guard let architectureCount: UInt32 = buffer.loadIfWithinBounds(byteOffset: 4, as: UInt32.self) else {
            return nil
        }
        let count = Int(architectureCount.bigEndian)
        guard count > 0, count < 64 else { return nil }

        let entrySize = is64Bit ? MemoryLayout<fat_arch_64>.size : MemoryLayout<fat_arch>.size
        var architectures: Set<MachOArchitecture> = []

        for index in 0 ..< count {
            let entryOffset = MemoryLayout<fat_header>.size + index * entrySize
            guard let rawCPUType: UInt32 = buffer.loadIfWithinBounds(byteOffset: entryOffset, as: UInt32.self),
                  let rawCPUSubtype: UInt32 = buffer.loadIfWithinBounds(
                      byteOffset: entryOffset + MemoryLayout<UInt32>.size, as: UInt32.self
                  )
            else { return architectures.isEmpty ? nil : architectures }

            architectures.insert(
                MachOArchitecture(
                    cpuType: cpu_type_t(bitPattern: rawCPUType.bigEndian),
                    rawCPUSubtype: cpu_subtype_t(bitPattern: rawCPUSubtype.bigEndian)
                )
            )
        }
        return architectures.isEmpty ? nil : architectures
    }

    // MARK: - Thin files

    private static func architectureOfThinFile(_ buffer: UnsafeRawBufferPointer, atOffset fileOffset: Int) -> MachOArchitecture? {
        guard fileOffset >= 0,
              let magic: UInt32 = buffer.loadIfWithinBounds(byteOffset: fileOffset, as: UInt32.self)
        else { return nil }

        let needsSwap: Bool
        switch magic {
        case MH_MAGIC_64, MH_MAGIC: needsSwap = false
        case MH_CIGAM_64, MH_CIGAM: needsSwap = true
        default: return nil
        }

        func normalize(_ value: UInt32) -> UInt32 { needsSwap ? value.byteSwapped : value }

        // cputype and cpusubtype are the second and third UInt32 of mach_header.
        guard let rawCPUType: UInt32 = buffer.loadIfWithinBounds(
                  byteOffset: fileOffset + MemoryLayout<UInt32>.size, as: UInt32.self
              ),
              let rawCPUSubtype: UInt32 = buffer.loadIfWithinBounds(
                  byteOffset: fileOffset + MemoryLayout<UInt32>.size * 2, as: UInt32.self
              )
        else { return nil }

        return MachOArchitecture(
            cpuType: cpu_type_t(bitPattern: normalize(rawCPUType)),
            rawCPUSubtype: cpu_subtype_t(bitPattern: normalize(rawCPUSubtype))
        )
    }
}

// MARK: -

extension UnsafeRawBufferPointer {
    /// `loadUnaligned` that answers `nil` instead of trapping when the read would run past the
    /// end of the buffer. The daemon parses files chosen by its client; a truncated or hostile
    /// Mach-O has to produce "cannot tell", not a crashed daemon.
    fileprivate func loadIfWithinBounds<Value>(byteOffset: Int, as type: Value.Type) -> Value? {
        guard byteOffset >= 0, byteOffset + MemoryLayout<Value>.size <= count else { return nil }
        return loadUnaligned(fromByteOffset: byteOffset, as: type)
    }
}
#endif
