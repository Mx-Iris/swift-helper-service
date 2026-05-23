#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
import SwiftyXPC
@testable import HelperClient

@Suite("XPCConnection.Error.indicatesOutdatedPeer")
struct OutdatedPeerTests {
    @Test func unexpectedMessageIsOutdated() {
        let error = SwiftyXPC.XPCConnection.Error.unexpectedMessage
        #expect(error.indicatesOutdatedPeer == true)
    }

    @Test func missingMessageNameIsTransient() {
        let error = SwiftyXPC.XPCConnection.Error.missingMessageName
        #expect(error.indicatesOutdatedPeer == false)
    }

    @Test func missingMessageBodyIsTransient() {
        let error = SwiftyXPC.XPCConnection.Error.missingMessageBody
        #expect(error.indicatesOutdatedPeer == false)
    }

    @Test func typeMismatchIsTransient() {
        let error = SwiftyXPC.XPCConnection.Error.typeMismatch(expected: .dictionary, actual: .string)
        #expect(error.indicatesOutdatedPeer == false)
    }

    @Test func callerFailedCredentialCheckIsTransient() {
        let error = SwiftyXPC.XPCConnection.Error.callerFailedCredentialCheck(0)
        #expect(error.indicatesOutdatedPeer == false)
    }
}
#endif
