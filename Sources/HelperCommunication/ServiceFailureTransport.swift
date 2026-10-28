#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import FoundationToolbox

/// The single place where a service-side error is prepared for the wire.
///
/// Every message handler the package installs routes through ``wrappingFailures(requestIdentifier:operation:)``,
/// which does two things a service implementation would otherwise have to remember
/// on its own: keep the failure's description intact across XPC (see
/// ``HelperServiceFailure``), and leave a record on the daemon side. Before this
/// existed, a failed injection left no trace at either end — the caller got
/// `domain + code`, and the daemon logged nothing at all.
///
/// The subsystem is spelled out because a daemon has no bundle to infer one from:
/// `@Loggable`'s default would fall back to the bare type name.
/// Reachable through the `InjectionPeer` SPI because swift-injection-peer's peer channels install
/// their own message handlers and must route through the same single place — otherwise their
/// failures lose the description on the way out and leave no daemon-side record, which is exactly
/// what this type exists to prevent.
@Loggable(subsystem: "com.JH.HelperCommunication", category: "ServiceFailure")
@_spi(InjectionPeer) public enum ServiceFailureTransport {
    /// Runs a message handler, logging and wrapping any failure that would otherwise
    /// lose its description on the way out.
    ///
    /// Errors that are already `Error & Codable` are rethrown untouched: SwiftyXPC can
    /// carry those in full by itself, and they include its own `XPCConnection.Error`,
    /// which `HelperClient.errorIndicatesOutdatedPeer(_:)` pattern-matches on. Wrapping
    /// those would break the outdated-peer discriminator.
    @_spi(InjectionPeer) public static func wrappingFailures<Result>(
        requestIdentifier: String?,
        operation: () async throws -> Result
    ) async throws -> Result {
        do {
            return try await operation()
        } catch {
            if let codableError = error as? (any Error & Codable) {
                throw codableError
            }

            let failure = HelperServiceFailure(wrapping: error, requestIdentifier: requestIdentifier)
            #log(
                .error,
                """
                Handler for \(failure.requestIdentifier ?? "<unnamed message>", privacy: .public) failed: \
                \(failure.underlyingErrorDebugDescription, privacy: .public) \
                (domain: \(failure.underlyingErrorDomain, privacy: .public), \
                code: \(failure.underlyingErrorCode, privacy: .public)) \
                — \(failure.localizedFailureDescription, privacy: .public)
                """
            )
            throw failure
        }
    }
}
#endif
