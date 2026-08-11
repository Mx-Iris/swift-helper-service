#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
@preconcurrency internal import SwiftyXPC

/// A service-side failure in a form that survives the XPC boundary.
///
/// SwiftyXPC moves errors across the wire as `XPCErrorRegistry.BoxedError`, which
/// carries only `domain` and `code` — plus the full error body, but *only* when the
/// error is `Error & Codable` and the receiving side has registered its domain.
/// `NSError` is not `Codable`, so everything a service put in `userInfo`, including
/// `localizedDescription`, is dropped at the encoding stage.
///
/// Handlers therefore wrap non-`Codable` errors in this type before they are thrown
/// across the boundary (see ``ServiceFailureTransport``). `CustomNSError` pins
/// `_domain` to ``errorDomain`` so the decoding side can find it in the registry,
/// while `errorCode` forwards the original code — so a caller's
/// `(error as NSError).code` is unchanged and only the domain moves.
///
/// - Important: ``errorDomain`` is part of the wire format, the same way
///   `Request.identifier` is. Changing it makes a new client talking to an old
///   daemon (or the reverse) fall back to a bare `BoxedError` — the description is
///   lost again, silently. Do not change it outside of a proposal.
public struct HelperServiceFailure: Error, Codable, Sendable, CustomNSError, LocalizedError {
    /// The pinned domain the decoding side looks up in `XPCErrorRegistry`.
    public static let errorDomain = "com.JH.HelperCommunication.ServiceFailure"

    /// The domain the original error carried. This is what a caller used to see in
    /// `(error as NSError).domain` before the wrapping was introduced.
    public let underlyingErrorDomain: String

    /// The code the original error carried, forwarded through ``errorCode`` so
    /// `(error as NSError).code` keeps reporting it.
    public let underlyingErrorCode: Int

    /// The original error's `localizedDescription`, in full.
    public let localizedFailureDescription: String

    /// The original error's `String(describing:)`, in full.
    ///
    /// A Swift `enum` error that does not implement `errorDescription` has a useless
    /// generic `localizedDescription` ("The operation couldn't be completed…"); its
    /// case name only shows up here.
    public let underlyingErrorDebugDescription: String

    /// `Request.identifier` of the message that failed. The transport layer knows it,
    /// so service implementations never have to pass it themselves.
    public let requestIdentifier: String?

    public var errorCode: Int { underlyingErrorCode }

    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: localizedFailureDescription] }

    public var errorDescription: String? { localizedFailureDescription }

    package init(wrapping error: any Error, requestIdentifier: String?) {
        let underlyingError = error as NSError
        self.underlyingErrorDomain = underlyingError.domain
        self.underlyingErrorCode = underlyingError.code
        self.localizedFailureDescription = error.localizedDescription
        self.underlyingErrorDebugDescription = String(describing: error)
        self.requestIdentifier = requestIdentifier
    }
}

extension HelperServiceFailure {
    /// Registers ``HelperServiceFailure`` with `XPCErrorRegistry` so the decoding side
    /// reconstitutes it instead of falling back to a bare `BoxedError`.
    ///
    /// Callers never have to do this — `HelperClient`, `HelperPeerClient` and
    /// `HelperPeerServer` each call it from `init`. "Forgot to register" would degrade
    /// silently back to the pre-fix behaviour, which is exactly the failure mode this
    /// library has to close on the caller's behalf.
    ///
    /// The domain string is passed explicitly rather than relying on `registerDomain`'s
    /// `String(reflecting: errorType)` default: that default is
    /// `"HelperCommunication.HelperServiceFailure"`, which would break the moment the
    /// module or type is renamed — and break by silently reverting to the old
    /// behaviour, with nothing failing to compile.
    ///
    /// Idempotent: `registerDomain` is a locked dictionary assignment, so repeat calls
    /// write the same entry.
    package static func registerForDecoding() {
        XPCErrorRegistry.shared.registerDomain(errorDomain, forErrorType: HelperServiceFailure.self)
    }
}
#endif
