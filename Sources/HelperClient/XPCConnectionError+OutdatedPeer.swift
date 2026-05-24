#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
@preconcurrency internal import SwiftyXPC

extension HelperClient {
    /// Returns `true` only when the thrown error indicates the peer does not recognize the requested
    /// message type — i.e. the peer binary predates a Request that the current binary expects to be
    /// handled. Every other case (connection refused / interrupted / invalid / transient XPC
    /// hiccups) returns `false` and should be treated as transient by the caller.
    ///
    /// Wraps the SwiftyXPC-specific `XPCConnection.Error.unexpectedMessage` check so callers don't
    /// need to import or pattern-match against `SwiftyXPC.XPCConnection.Error` directly.
    public static func errorIndicatesOutdatedPeer(_ error: any Swift.Error) -> Bool {
        guard let xpcError = error as? SwiftyXPC.XPCConnection.Error else { return false }
        if case .unexpectedMessage = xpcError {
            return true
        }
        return false
    }
}
#endif
