#if os(macOS)
import Foundation
import Testing
@testable import HelperPeer

/// The property everything here rests on: **two processes that never speak must compute the same
/// port**. One of them is sandboxed and cannot be told anything — not through the tool, which is
/// the hop its sandbox blocked, and not through a file, since it shares no directory with its
/// host. Derivation replaces the conversation, so the derivation has to be exactly reproducible.
@Suite("Peer transport selection")
struct PeerTransportTests {
    @Test("The same identifier always derives the same port")
    func derivationIsDeterministic() {
        let identifier = "com.JH.injectiond.peer.4242"
        let first = PeerPortDerivation.port(for: identifier)
        for _ in 0 ..< 100 {
            #expect(PeerPortDerivation.port(for: identifier) == first)
        }
    }

    /// Not a style point. `Hasher` is seeded per process, so a host and a payload using it would
    /// derive different ports and sit waiting for each other — which is exactly the failure this
    /// whole mechanism exists to avoid, and it would only show up across a process boundary.
    @Test("Derivation does not depend on anything per-process")
    func derivationIsNotSeeded() {
        // A hand-computed djb2 over the same bytes, written out independently of the
        // implementation. If someone swaps in Hasher or changes the algorithm, this fails.
        func referenceDjb2(_ text: String) -> UInt64 {
            var hash: UInt64 = 5381
            for byte in text.utf8 { hash = (hash &<< 5 &+ hash) &+ UInt64(byte) }
            return hash
        }
        let identifier = "com.example.service.peer.1234"
        let span = UInt64(PeerPortDerivation.highestPort - PeerPortDerivation.lowestPort)
        let expected = PeerPortDerivation.lowestPort + UInt16(referenceDjb2(identifier) % span)

        #expect(PeerPortDerivation.port(for: identifier) == expected)
    }

    @Test("Derived ports land in the dynamic range", arguments: [
        "", "a", "com.JH.injectiond.peer.1", "com.JH.injectiond.peer.99999",
        String(repeating: "x", count: 4096), "日本語のサービス名.peer.42",
    ])
    func derivedPortsAreInTheDynamicRange(identifier: String) {
        let port = PeerPortDerivation.port(for: identifier)
        #expect(port >= PeerPortDerivation.lowestPort)
        #expect(port <= PeerPortDerivation.highestPort)
    }

    /// Two payloads injected at once must not land on one port — the second listener would fail
    /// to bind, and the failure would look like the first injection having broken something.
    @Test("Different target pids derive different ports")
    func differentPidsDeriveDifferentPorts() {
        let ports = (1 ... 500).map { pid in
            PeerPortDerivation.port(
                for: PeerPortDerivation.channelIdentifier(
                    serviceName: "com.JH.injectiond",
                    targetProcessIdentifier: pid_t(pid)
                )
            )
        }
        let distinct = Set(ports)
        // The range holds 16383 ports, so 500 identifiers collide sometimes — birthday-wise a
        // handful is expected. What would be broken is clustering.
        #expect(distinct.count > 480, "got \(distinct.count) distinct ports out of 500")
    }

    @Test("The channel identifier carries the pid")
    func channelIdentifierCarriesThePid() {
        let identifier = PeerPortDerivation.channelIdentifier(
            serviceName: "com.JH.injectiond",
            targetProcessIdentifier: 4242
        )
        #expect(identifier.contains("4242"))
        #expect(identifier.contains("com.JH.injectiond"))
    }

    // MARK: - Probing

    @Test("This unsandboxed test process is not blocked, so it selects XPC")
    func unsandboxedProcessSelectsXPC() {
        // The test runner is not sandboxed, so the probe must answer "not blocked". If this ever
        // fails, the probe is reporting denial for something it cannot see rather than for a
        // real one — which would push every target onto the socket path.
        #expect(
            PeerTransportSelection.isMachLookupBlocked(
                forProcess: getpid(),
                machServiceName: "com.JH.NonexistentServiceForProbing"
            ) == false
        )

        let transport = PeerTransportSelection.transport(
            forProcess: getpid(),
            machServiceName: "com.JH.NonexistentServiceForProbing",
            channelIdentifier: "com.JH.test.peer.\(getpid())"
        )
        #expect(transport == .brokeredXPC)
    }

    @Test("A pid that does not exist falls back to XPC rather than the socket")
    func unknownProcessFallsBackToXPC() {
        // sandbox_check reports denial for a pid it cannot find. Treating that as "blocked"
        // would route a dead or unknown target onto the socket path, where both sides wait
        // forever instead of getting the clear failure the XPC path produces.
        let transport = PeerTransportSelection.transport(
            forProcess: pid_t(Int32.max),
            machServiceName: "com.JH.NonexistentServiceForProbing",
            channelIdentifier: "com.JH.test.peer.0"
        )
        #expect(transport == .brokeredXPC)
    }
}
#endif
