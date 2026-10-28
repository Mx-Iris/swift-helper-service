#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
// `public` rather than `package`: the `InjectionPeer` SPI members below are public declarations
// (SPI only gates who may name them), and a public declaration cannot have a package type in its
// signature. Ordinary callers are unaffected — storing, passing and serializing
// `HelperPeerEndpoint` never mentions `XPCEndpoint`, so they still need not import SwiftyXPC.
@preconcurrency public import SwiftyXPC

/// Opaque, lib-public wrapper around `SwiftyXPC.XPCEndpoint`.
///
/// Use this in business `Request` payloads (e.g. an injected-app endpoint registry) when you
/// need to embed a peer's listener endpoint without forcing the caller to import SwiftyXPC.
///
/// ## Wire-format compatibility
///
/// The `Codable` implementation forwards to a `singleValueContainer` and lets
/// `XPCEncoder`/`XPCDecoder` hit their built-in `XPCEndpoint` specialization (which writes/reads
/// the native `xpc_endpoint_t` rather than going through `XPCEndpoint.encode(to:)`, which is
/// intentionally a throwing stub on SwiftyXPC's side). The on-the-wire layout is therefore
/// **bit-identical to a bare `SwiftyXPC.XPCEndpoint` in the same Codable position** — wrapping
/// or unwrapping does not change what the daemon / peer sees.
///
/// The `underlying` storage and the SwiftyXPC-typed initializer are reachable only through the
/// `InjectionPeer` SPI, so ordinary callers can store, pass and serialize `HelperPeerEndpoint`
/// values but cannot reach the wrapped `XPCEndpoint`.
///
/// They were `package` until the peer channel moved to swift-injection-peer, which needs to
/// construct and unwrap these while living in a different package. `@_spi` rather than plain
/// `public` keeps the original intent — an interface for the implementation, not a promise to
/// everybody — and makes the one library that may use it name itself at the import site.
public struct HelperPeerEndpoint: Codable, Sendable {
    @_spi(InjectionPeer) public let underlying: SwiftyXPC.XPCEndpoint

    @_spi(InjectionPeer) public init(_ underlying: SwiftyXPC.XPCEndpoint) {
        self.underlying = underlying
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.underlying = try container.decode(SwiftyXPC.XPCEndpoint.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(underlying)
    }
}
#endif
