#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
@testable import HelperCommunication

@Suite("Codable round-trip and identifier conventions")
struct CodableTests {
    @Test func voidResponseRoundTrip() throws {
        let data = try JSONEncoder().encode(VoidResponse.empty)
        let decoded = try JSONDecoder().decode(VoidResponse.self, from: data)
        // VoidResponse is value-equivalent (no fields); successful decode is sufficient.
        _ = decoded
    }

    @Test func pingRequestRoundTrip() throws {
        let data = try JSONEncoder().encode(PingRequest())
        let decoded = try JSONDecoder().decode(PingRequest.self, from: data)
        _ = decoded
        #expect(PingRequest.identifier == "com.JH.HelperCommunication.Ping")
    }

    @Test func fetchVersionRequestRoundTrip() throws {
        let data = try JSONEncoder().encode(FetchVersionRequest())
        let decoded = try JSONDecoder().decode(FetchVersionRequest.self, from: data)
        _ = decoded
        #expect(FetchVersionRequest.identifier == "com.JH.HelperCommunication.FetchVersion")
    }

    @Test func fetchVersionResponseRoundTrip() throws {
        let original = FetchVersionRequest.Response(version: "1.2.3-rc.1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FetchVersionRequest.Response.self, from: data)
        #expect(decoded.version == "1.2.3-rc.1")
    }

    @Test func builtInIdentifiersUseHelperCommunicationNamespace() {
        let identifiers: [String] = [
            PingRequest.identifier,
            FetchVersionRequest.identifier,
        ]
        for identifier in identifiers {
            #expect(identifier.hasPrefix("com.JH.HelperCommunication."), "identifier '\(identifier)' must be under the com.JH.HelperCommunication.* namespace")
        }
    }
}
#endif
