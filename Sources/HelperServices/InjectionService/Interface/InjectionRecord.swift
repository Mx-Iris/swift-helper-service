#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation

/// One injection this daemon performed.
///
/// **This records that the daemon put a payload into that process — not that the payload is still
/// alive, and not that any channel to it is open.** Nothing reports back to the daemon after an
/// injection returns: it deliberately does not broker the channel back, because
/// `xpc_connection_set_peer_code_signing_requirement` checks the connecting process and an
/// injected payload has no process identity of its own. A caller that needs liveness has to ask
/// its own payload over its own channel.
///
/// That distinction is the whole reason this type exists. The list it replaced was built from
/// payloads checking in, so an entry *did* mean "something answered from in there". Entries here
/// mean only "the daemon wrote a payload into that process", and a user interface presenting them
/// has to say so.
///
/// Held in memory only; restarting or reinstalling the daemon clears it. That is the honest
/// behaviour rather than a shortcut — such a restart has already severed every payload's channel,
/// so persisted entries would all be stale on the first read.
public struct InjectionRecord: Codable, Sendable, Hashable {
    /// The process the payload went into.
    public let hostProcessIdentifier: pid_t

    /// The payload's path as the daemon saw it at injection time.
    public let payloadPath: String

    public let injectedAt: Date

    /// Which path actually carried the injection — **not** what the caller asked for. A request
    /// that let the daemon decide, and whose `dlopen` the target refused, records
    /// ``InjectionStrategy/machVirtualMemoryRemap`` here.
    public let strategy: InjectionStrategy

    public init(
        hostProcessIdentifier: pid_t,
        payloadPath: String,
        injectedAt: Date,
        strategy: InjectionStrategy
    ) {
        self.hostProcessIdentifier = hostProcessIdentifier
        self.payloadPath = payloadPath
        self.injectedAt = injectedAt
        self.strategy = strategy
    }
}

#endif
