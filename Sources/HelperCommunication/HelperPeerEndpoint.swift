#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
@preconcurrency package import SwiftyXPC

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
/// The `underlying` storage and the SwiftyXPC-typed initializer are `package`-visible so only
/// lib-internal code can introspect/construct the wrapper. External callers can store, pass,
/// and serialize `HelperPeerEndpoint` values but cannot reach the wrapped `XPCEndpoint`.
public struct HelperPeerEndpoint: Codable, Sendable {
    package let underlying: SwiftyXPC.XPCEndpoint

    package init(_ underlying: SwiftyXPC.XPCEndpoint) {
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
