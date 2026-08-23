#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation

/// Reads the `LC_BUILD_VERSION` platform out of a Mach-O file or a running
/// process.
///
/// The value is deliberately left as the raw `LC_BUILD_VERSION` number rather
/// than mapped onto an enumeration of named platforms. Everything the daemon
/// decides with it is a comparison — *is the payload built for the same
/// platform as its target*, *is the target built for the same platform as this
/// daemon* — and a comparison stays correct for a platform that did not exist
/// when this was written. Naming them would also duplicate, in a second
/// process, a judgement the host app already makes when it chooses which
/// payload slice to install; that is how two halves drift apart.
///
/// Why this cannot be answered from the architecture instead: on Apple silicon
/// a macOS process and an iOS Simulator process have the same `cputype`
/// (arm64). They differ only here. A fat binary cannot hold both for the same
/// reason, which is why the payload ships as separate per-platform bundles.
enum MachOPlatform {
    /// The platform of the process with this pid, or `nil` when its executable
    /// cannot be located or parsed.
    static func ofProcess(_ processIdentifier: pid_t) -> UInt32? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        return ofFile(atPath: String(cString: pathBuffer))
    }

    /// The platform recorded in a Mach-O file.
    ///
    /// For a fat file every slice is inspected and the first recognized
    /// platform wins. Slices of one file do not disagree in practice: a fat
    /// binary holds several architectures of a single build.
    ///
    /// `nil` means "cannot tell" — a missing file, something that is not
    /// Mach-O, a truncated one. Callers must not read that as a match.
    static func ofFile(atPath path: String) -> UInt32? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else {
            return nil
        }
        return data.withUnsafeBytes { buffer -> UInt32? in
            guard let magic: UInt32 = buffer.loadIfWithinBounds(byteOffset: 0, as: UInt32.self) else {
                return nil
            }
            switch magic {
            case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
                return platformOfFatFile(buffer, is64Bit: magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64)
            default:
                return platformOfThinFile(buffer, atOffset: 0)
            }
        }
    }

    // MARK: - Fat files

    private static func platformOfFatFile(_ buffer: UnsafeRawBufferPointer, is64Bit: Bool) -> UInt32? {
        // Fat headers are always big-endian, whatever the host is.
        guard let architectureCount: UInt32 = buffer.loadIfWithinBounds(byteOffset: 4, as: UInt32.self) else {
            return nil
        }
        let count = Int(architectureCount.bigEndian)
        // A corrupt count must not turn into a huge loop. Every entry is
        // bounds-checked below regardless, but cap the iteration up front.
        guard count > 0, count < 64 else { return nil }

        let entrySize = is64Bit ? MemoryLayout<fat_arch_64>.size : MemoryLayout<fat_arch>.size
        // `offset` is the third field of both fat_arch and fat_arch_64, after
        // cputype and cpusubtype; it widens to 64 bits in the _64 variant.
        let offsetFieldOffset = MemoryLayout<UInt32>.size * 2

        for index in 0 ..< count {
            let entryOffset = MemoryLayout<fat_header>.size + index * entrySize
            let sliceOffset: Int
            if is64Bit {
                guard let rawOffset: UInt64 = buffer.loadIfWithinBounds(
                    byteOffset: entryOffset + offsetFieldOffset, as: UInt64.self
                ) else { return nil }
                sliceOffset = Int(rawOffset.bigEndian)
            } else {
                guard let rawOffset: UInt32 = buffer.loadIfWithinBounds(
                    byteOffset: entryOffset + offsetFieldOffset, as: UInt32.self
                ) else { return nil }
                sliceOffset = Int(rawOffset.bigEndian)
            }
            if let platform = platformOfThinFile(buffer, atOffset: sliceOffset) {
                return platform
            }
        }
        return nil
    }

    // MARK: - Thin files

    private static func platformOfThinFile(_ buffer: UnsafeRawBufferPointer, atOffset fileOffset: Int) -> UInt32? {
        guard fileOffset >= 0,
              let magic: UInt32 = buffer.loadIfWithinBounds(byteOffset: fileOffset, as: UInt32.self)
        else { return nil }

        let is64Bit: Bool
        let needsSwap: Bool
        switch magic {
        case MH_MAGIC_64: is64Bit = true;  needsSwap = false
        case MH_CIGAM_64: is64Bit = true;  needsSwap = true
        case MH_MAGIC:    is64Bit = false; needsSwap = false
        case MH_CIGAM:    is64Bit = false; needsSwap = true
        default: return nil
        }

        func normalize(_ value: UInt32) -> UInt32 { needsSwap ? value.byteSwapped : value }

        // ncmds is the fifth UInt32 of mach_header.
        guard let commandCount: UInt32 = buffer.loadIfWithinBounds(
            byteOffset: fileOffset + MemoryLayout<UInt32>.size * 4, as: UInt32.self
        ) else { return nil }

        let headerSize = is64Bit ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
        var commandOffset = fileOffset + headerSize
        var fallbackPlatform: UInt32?

        for _ in 0 ..< normalize(commandCount) {
            guard let command: UInt32 = buffer.loadIfWithinBounds(byteOffset: commandOffset, as: UInt32.self),
                  let commandSize: UInt32 = buffer.loadIfWithinBounds(
                      byteOffset: commandOffset + MemoryLayout<UInt32>.size, as: UInt32.self
                  )
            else { return fallbackPlatform }

            let size = Int(normalize(commandSize))
            // A zero size would spin forever on a malformed file.
            guard size >= MemoryLayout<load_command>.size else { return fallbackPlatform }

            switch normalize(command) {
            case UInt32(LC_BUILD_VERSION):
                return buffer.loadIfWithinBounds(
                    byteOffset: commandOffset + MemoryLayout<UInt32>.size * 2, as: UInt32.self
                ).map(normalize)

            // Binaries predating LC_BUILD_VERSION carry only a minimum-OS
            // command. Kept as a fallback rather than an immediate answer
            // because a binary can carry both, and LC_BUILD_VERSION is the
            // authoritative one when it does.
            case UInt32(LC_VERSION_MIN_MACOSX):
                fallbackPlatform = platformMacOS
            case UInt32(LC_VERSION_MIN_IPHONEOS):
                fallbackPlatform = platformiOSSimulator
            case UInt32(LC_VERSION_MIN_TVOS):
                fallbackPlatform = platformtvOSSimulator
            case UInt32(LC_VERSION_MIN_WATCHOS):
                fallbackPlatform = platformwatchOSSimulator
            default:
                break
            }
            commandOffset += size
        }
        return fallbackPlatform
    }

    // MARK: - The handful of values that have to be named

    // Only the ones a pre-LC_BUILD_VERSION binary has to be mapped onto. They
    // are spelled out because <mach-o/loader.h> exposes them as macros, which
    // do not reach Swift. A device binary cannot execute on a Mac at all, so an
    // iOS/tvOS/watchOS minimum-OS command on a local process means the
    // simulator by elimination.
    static let platformMacOS: UInt32 = 1
    static let platformiOSSimulator: UInt32 = 7
    static let platformtvOSSimulator: UInt32 = 8
    static let platformwatchOSSimulator: UInt32 = 9
}

// MARK: -

extension UnsafeRawBufferPointer {
    /// `loadUnaligned` that answers `nil` instead of trapping when the read
    /// would run past the end of the buffer.
    ///
    /// The daemon parses files chosen by its client. A truncated or hostile
    /// Mach-O has to produce "cannot tell", not a crashed daemon.
    fileprivate func loadIfWithinBounds<Value>(byteOffset: Int, as type: Value.Type) -> Value? {
        guard byteOffset >= 0, byteOffset + MemoryLayout<Value>.size <= count else { return nil }
        return loadUnaligned(fromByteOffset: byteOffset, as: type)
    }
}
#endif
