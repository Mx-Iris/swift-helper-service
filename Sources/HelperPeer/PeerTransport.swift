#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
internal import HelperProcessProbe

/// How a host and the payload injected into its target reach each other.
///
/// ## Why there are two
///
/// The XPC route works by both sides registering an anonymous endpoint with the privileged
/// tool and collecting the other's — see [BrokeredPeer.md](../../Documentations/Architecture/BrokeredPeer.md).
/// That requires the payload to look up the tool's Mach service, and in a sandboxed target it
/// cannot: App Sandbox runs a `(deny default)` profile whose `mach-lookup` allowlist will never
/// contain a third-party service, and seatbelt-profiled system daemons are closed the same way
/// while carrying no entitlement that would give it away.
///
/// So for those targets the pair falls back to a loopback socket — and the roles invert. See
/// ``PeerTransport/loopbackSocket(port:)``.
public enum PeerTransport: Sendable, Equatable {
    /// Both sides exchange anonymous endpoints through the tool's registry, then talk directly.
    case brokeredXPC

    /// A loopback TCP socket on `port`, **with the host listening and the payload connecting
    /// out**.
    ///
    /// The inversion is forced, not stylistic: a sandboxed process may open an outbound
    /// connection to localhost, but nothing can discover a port it bound, because the two sides
    /// share no channel to announce it on — not the tool (that is the hop that is blocked) and
    /// not the file system (a sandboxed app and its host have no directory in common). Having
    /// the host listen turns "announce a port" into "agree on one", which
    /// ``PeerPortDerivation`` does without either side speaking.
    case loopbackSocket(port: UInt16)
}

/// Decides which transport to use for a given process.
///
/// Both sides call this and must agree. The host asks about its target's pid before injecting;
/// the payload asks about `getpid()` once it is inside. Same question, same answer, no
/// negotiation — which matters because in the case where they would need to negotiate, they
/// have no way to.
public enum PeerTransportSelection {
    /// Whether `processIdentifier`'s sandbox would deny looking up `machServiceName`.
    ///
    /// Probed rather than inferred from entitlements, because the two sandbox flavours that
    /// block this do not look alike from the outside.
    ///
    /// An unsandboxed process answers `false`. **A probe error also answers `false`**, keeping
    /// the XPC default: that path reports its own failures clearly, whereas wrongly choosing the
    /// socket would have both sides waiting on a connection neither is making.
    public static func isMachLookupBlocked(forProcess processIdentifier: pid_t, machServiceName: String) -> Bool {
        // `sandbox_check` answers "denied" for a pid the kernel cannot find, rather than
        // reporting an error. Taken at face value that routes every dead or unknown target onto
        // the socket path, where both sides wait on a connection neither is making — the XPC
        // path at least fails and says why. So establish the process exists first.
        //
        // ESRCH specifically: a live process owned by another user answers EPERM, and that is
        // not a reason to skip the probe.
        if kill(processIdentifier, 0) == -1, errno == ESRCH { return false }

        let result = machServiceName.withCString { namePointer in
            HelperProcessProbeSandboxCheckMachLookup(processIdentifier, namePointer)
        }
        return result > 0
    }

    /// The transport to use for a payload in `processIdentifier`.
    ///
    /// - Parameters:
    ///   - processIdentifier: The target process. The host passes its target's pid; the payload
    ///     passes `getpid()`.
    ///   - machServiceName: The privileged tool's Mach service name.
    ///   - channelIdentifier: Names this host-payload pair, and is what the socket port is
    ///     derived from. **It must include the target pid** — see ``PeerPortDerivation``.
    public static func transport(
        forProcess processIdentifier: pid_t,
        machServiceName: String,
        channelIdentifier: String
    ) -> PeerTransport {
        guard isMachLookupBlocked(forProcess: processIdentifier, machServiceName: machServiceName) else {
            return .brokeredXPC
        }
        return .loopbackSocket(port: PeerPortDerivation.port(for: channelIdentifier))
    }
}

/// Turns a channel identifier into a loopback port, the same way on both sides.
///
/// ## Why derive instead of allocate
///
/// Binding port 0 and letting the kernel choose is the better answer everywhere it is available,
/// and it is not available here: the side that would bind is the sandboxed payload, and it has
/// no way to tell the host what it got. The tool is the hop the sandbox blocked, and a
/// sandboxed app shares no filesystem location with its host. Deriving the port from something
/// both sides already know removes the need to communicate it.
public enum PeerPortDerivation {
    /// The dynamic/private range, which no registered service occupies.
    static let lowestPort: UInt16 = 49152
    static let highestPort: UInt16 = 65535

    /// A deterministic port in the dynamic range.
    ///
    /// djb2 — picked because it is trivial to reimplement identically in another language or
    /// another process, which matters more here than distribution quality. `Hasher` would be
    /// wrong for this: it is seeded per-process, so the two sides would compute different ports.
    ///
    /// **The identifier must include the target pid.** Two payloads in two processes derived
    /// from one identifier would collide on a single port, and the second listener would fail to
    /// bind.
    ///
    /// Collisions with unrelated software are possible and not preventable from here — the range
    /// is shared with every ephemeral socket on the machine. The listening side detects a failed
    /// bind and reports it; it does not silently try another port, because the other side would
    /// have no way to follow.
    public static func port(for channelIdentifier: String) -> UInt16 {
        var hash: UInt64 = 5381
        for byte in channelIdentifier.utf8 {
            // hash * 33 + byte, with the multiply split so it cannot overflow-trap.
            hash = (hash &<< 5 &+ hash) &+ UInt64(byte)
        }
        let span = UInt64(highestPort - lowestPort)
        return lowestPort + UInt16(hash % span)
    }

    /// The conventional identifier for one host-payload pair.
    ///
    /// Spelled out here so both sides build it the same way rather than each formatting their
    /// own; the pid is what keeps two simultaneous injections off the same port.
    public static func channelIdentifier(serviceName: String, targetProcessIdentifier: pid_t) -> String {
        "\(serviceName).peer.\(targetProcessIdentifier)"
    }
}
#endif
