#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
@preconcurrency public import SwiftyXPC

extension SwiftyXPC.XPCConnection.Error {
    /// Returns `true` only when the thrown error indicates the peer does not recognize the requested
    /// message type — i.e. the peer binary predates a Request that the current binary expects to be
    /// handled. Every other case (connection refused / interrupted / invalid / transient XPC
    /// hiccups) returns `false` and should be treated as transient by the caller.
    public var indicatesOutdatedPeer: Bool {
        if case .unexpectedMessage = self {
            return true
        }
        return false
    }
}
#endif
