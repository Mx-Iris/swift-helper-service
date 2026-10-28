#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Testing
import HelperClient
// `@_spi` as well as `@testable`: the typed `sendMessage` / `setMessageHandler` and
// `registerForDecoding()` moved from `package` to the `InjectionPeer` SPI, and `@testable` grants
// internal access without granting SPI access.
@_spi(InjectionPeer) @testable import HelperCommunication
@preconcurrency import SwiftyXPC

/// A request that exists only to give these tests something to fail on.
private struct ProbeRequest: Codable, Sendable, Request {
    typealias Response = VoidResponse
    static let identifier = "com.JH.Tests.ServiceFailureProbe"
}

/// A request no handler is ever installed for, used to reach SwiftyXPC's own
/// "peer does not know this message" path.
private struct UnhandledRequest: Codable, Sendable, Request {
    typealias Response = VoidResponse
    static let identifier = "com.JH.Tests.NeverHandled"
}

/// A `Codable` error, standing in for a caller's own error type that already
/// crosses the boundary intact and must therefore be left alone.
private enum AlreadyCodableFailure: Error, Codable {
    case somethingSpecific
}

/// Not `Codable`, and no `errorDescription` — the shape whose case name used to be
/// unrecoverable on the caller's side.
private enum BareSwiftFailure: Error {
    case registryEntryMissing
}

/// Spins up an anonymous listener and connects to its own endpoint from the same
/// process, so a handler's error can be observed exactly as a remote caller sees it.
///
/// This is the package's first test that puts a message on a real XPC connection;
/// everything before it tested `Codable` shapes in isolation, which is precisely why
/// the transport bug this file covers went unnoticed.
private func withLoopbackConnection(
    handler: @escaping @Sendable (ProbeRequest) async throws -> VoidResponse,
    body: (SwiftyXPC.XPCConnection) async throws -> Void
) async throws {
    // Constructing a client is what registers the failure domain for decoding. Doing
    // it through the public entry point rather than calling `registerForDecoding()`
    // directly keeps this test honest: if `HelperClient.init` ever stops registering,
    // these assertions fail.
    _ = HelperClient()

    let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
    listener.setMessageHandler(requestType: ProbeRequest.self) { _, request in
        try await handler(request)
    }
    listener.activate()

    let connection = try SwiftyXPC.XPCConnection(type: .remoteServiceFromEndpoint(listener.endpoint))
    connection.activate()
    defer {
        connection.cancel()
        listener.cancel()
    }

    try await body(connection)
}

@Suite("Service failures crossing a real XPC boundary")
struct ServiceFailureTransportTests {
    /// The regression this fix exists for: an `NSError` description used to be dropped
    /// at the encoding stage, leaving the caller with domain + code and nothing else.
    @Test func nsErrorDescriptionSurvivesTheBoundary() async throws {
        let detailedReason = "target process refused to load /tmp/payload.dylib: code signature invalid"

        try await withLoopbackConnection { _ in
            throw NSError(
                domain: "com.JH.Tests.UpstreamDomain",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: detailedReason]
            )
        } body: { connection in
            do {
                try await connection.sendMessage(request: ProbeRequest())
                Issue.record("the handler was supposed to fail")
            } catch {
                #expect(error.localizedDescription == detailedReason)

                let receivedError = error as NSError
                #expect(receivedError.code == 42, "the original code must be forwarded unchanged")
                #expect(
                    receivedError.domain == HelperServiceFailure.errorDomain,
                    "the domain is pinned so the decoding side can find the type in the registry"
                )

                let failure = try #require(error as? HelperServiceFailure)
                #expect(failure.underlyingErrorDomain == "com.JH.Tests.UpstreamDomain")
                #expect(failure.underlyingErrorCode == 42)
                #expect(failure.requestIdentifier == ProbeRequest.identifier)
            }
        }
    }

    /// A Swift `enum` error without `errorDescription` has a useless generic
    /// `localizedDescription`; the case name only survives in the debug description.
    @Test func bareSwiftErrorKeepsItsCaseName() async throws {
        try await withLoopbackConnection { _ in
            throw BareSwiftFailure.registryEntryMissing
        } body: { connection in
            do {
                try await connection.sendMessage(request: ProbeRequest())
                Issue.record("the handler was supposed to fail")
            } catch {
                let failure = try #require(error as? HelperServiceFailure)
                #expect(failure.underlyingErrorDebugDescription == "registryEntryMissing")
            }
        }
    }

    /// Errors that are already `Error & Codable` travel intact on their own, so the
    /// transport layer must not wrap them.
    @Test func alreadyCodableErrorIsNotWrapped() async throws {
        XPCErrorRegistry.shared.registerDomain(forErrorType: AlreadyCodableFailure.self)

        try await withLoopbackConnection { _ in
            throw AlreadyCodableFailure.somethingSpecific
        } body: { connection in
            do {
                try await connection.sendMessage(request: ProbeRequest())
                Issue.record("the handler was supposed to fail")
            } catch {
                #expect(error is AlreadyCodableFailure)
                #expect(!(error is HelperServiceFailure), "a Codable error must reach the caller unwrapped")
            }
        }
    }

    /// `XPCConnection.Error` is `Codable` and pre-registered, so it must reach the
    /// caller unwrapped — that is the mechanism
    /// `HelperClient.errorIndicatesOutdatedPeer(_:)` pattern-matches on. Wrapping it
    /// would turn the error into a `HelperServiceFailure` and the discriminator would
    /// answer `false` for everything.
    @Test func swiftyXPCErrorFromAHandlerIsRelayedIntact() async throws {
        try await withLoopbackConnection { _ in
            throw SwiftyXPC.XPCConnection.Error.unexpectedMessage
        } body: { connection in
            do {
                try await connection.sendMessage(request: ProbeRequest())
                Issue.record("the handler was supposed to fail")
            } catch {
                #expect(!(error is HelperServiceFailure), "a pre-registered Codable error must not be wrapped")
                #expect(HelperClient.errorIndicatesOutdatedPeer(error))
            }
        }
    }

    /// Records a defect this file uncovered, which is **older than this fix and
    /// untouched by it**: an unknown message name never produces an
    /// `unexpectedMessage` on the *caller's* side.
    ///
    /// SwiftyXPC throws it in exactly one place (`XPCConnection.respond(to:)`), and
    /// that path hands the error to the *receiving* process's own `errorHandler` and
    /// returns without replying. The caller is left waiting and eventually sees
    /// `connectionInterrupted`.
    ///
    /// So `HelperClient.errorIndicatesOutdatedPeer(_:)` — and with it
    /// `fetchToolVersion()`'s "tool is outdated, reinstall" branch — cannot fire for
    /// the case it was written for: an old daemon that has no `FetchVersionRequest`
    /// handler reads as a transient failure. Introduced in `a49e713`, never noticed,
    /// because until this file the package had no test that put a message on a wire.
    ///
    /// Asserting today's wrong behaviour on purpose: if SwiftyXPC ever starts
    /// replying on this path, this test fails and tells us the discriminator can be
    /// relied on again.
    @Test func unhandledMessageDoesNotReachTheCallerAsUnexpectedMessage() async throws {
        try await withLoopbackConnection { _ in
            .empty
        } body: { connection in
            do {
                try await connection.sendMessage(request: UnhandledRequest())
                Issue.record("an unhandled message was supposed to fail")
            } catch {
                if case .connectionInterrupted = try #require(error as? XPCError) {
                    // The caller is told the connection dropped, not that the peer
                    // did not understand the message.
                } else {
                    Issue.record("expected connectionInterrupted, got \(String(describing: error))")
                }
                #expect(
                    !HelperClient.errorIndicatesOutdatedPeer(error),
                    "known defect: the caller cannot tell an outdated peer from a dropped connection"
                )
            }
        }
    }
}

@Suite("HelperServiceFailure")
struct HelperServiceFailureTests {
    private func makeFailure() -> HelperServiceFailure {
        HelperServiceFailure(
            wrapping: NSError(
                domain: "com.JH.Tests.UpstreamDomain",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "the reason"]
            ),
            requestIdentifier: "com.JH.Tests.Something"
        )
    }

    @Test func roundTrip() throws {
        let data = try JSONEncoder().encode(makeFailure())
        let decoded = try JSONDecoder().decode(HelperServiceFailure.self, from: data)

        #expect(decoded.underlyingErrorDomain == "com.JH.Tests.UpstreamDomain")
        #expect(decoded.underlyingErrorCode == 7)
        #expect(decoded.localizedFailureDescription == "the reason")
        #expect(decoded.requestIdentifier == "com.JH.Tests.Something")
    }

    /// `CustomNSError` pins the domain while forwarding the original code — the
    /// property the whole design rests on, since it keeps the breaking change down to
    /// the domain alone.
    @Test func pinsDomainButForwardsCode() {
        let failure = makeFailure()

        #expect(failure._domain == "com.JH.HelperCommunication.ServiceFailure")
        #expect(failure.errorCode == 7)
        #expect((failure as NSError).code == 7)
        #expect(failure.localizedDescription == "the reason")
    }

    /// The domain string is part of the wire format: both ends look each other up by
    /// it, so a rename would silently degrade to the pre-fix behaviour.
    @Test func domainIsTheAgreedWireValue() {
        #expect(HelperServiceFailure.errorDomain == "com.JH.HelperCommunication.ServiceFailure")
    }

    /// `XPCErrorRegistry` exposes no way to read a registration back, so the assertion
    /// that registering actually takes effect lives in the round-trip tests above —
    /// they only decode a `HelperServiceFailure` because the domain is registered.
    /// This covers the remaining half: repeat calls are harmless.
    @Test func registrationIsIdempotent() {
        HelperServiceFailure.registerForDecoding()
        HelperServiceFailure.registerForDecoding()
    }
}
#endif
