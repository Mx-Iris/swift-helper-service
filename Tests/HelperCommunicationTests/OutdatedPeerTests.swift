#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
import SwiftyXPC
@testable import HelperClient

@Suite("HelperClient.errorIndicatesOutdatedPeer")
struct OutdatedPeerTests {
    @Test func unexpectedMessageIsOutdated() {
        let error = SwiftyXPC.XPCConnection.Error.unexpectedMessage
        #expect(HelperClient.errorIndicatesOutdatedPeer(error) == true)
    }

    @Test func missingMessageNameIsTransient() {
        let error = SwiftyXPC.XPCConnection.Error.missingMessageName
        #expect(HelperClient.errorIndicatesOutdatedPeer(error) == false)
    }

    @Test func missingMessageBodyIsTransient() {
        let error = SwiftyXPC.XPCConnection.Error.missingMessageBody
        #expect(HelperClient.errorIndicatesOutdatedPeer(error) == false)
    }

    @Test func typeMismatchIsTransient() {
        let error = SwiftyXPC.XPCConnection.Error.typeMismatch(expected: .dictionary, actual: .string)
        #expect(HelperClient.errorIndicatesOutdatedPeer(error) == false)
    }

    @Test func callerFailedCredentialCheckIsTransient() {
        let error = SwiftyXPC.XPCConnection.Error.callerFailedCredentialCheck(0)
        #expect(HelperClient.errorIndicatesOutdatedPeer(error) == false)
    }

    /// Anything that is not a SwiftyXPC connection error cannot say the peer is
    /// outdated. The discriminator takes `any Error`, so this is reachable.
    @Test func unrelatedErrorIsTransient() {
        let error = NSError(domain: "com.JH.Tests", code: 1)
        #expect(HelperClient.errorIndicatesOutdatedPeer(error) == false)
    }
}
#endif
