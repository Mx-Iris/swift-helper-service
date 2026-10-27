#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Testing
@testable import HelperCommunication

@Suite("HelperToolVersion")
struct HelperToolVersionTests {
    @Test("Parses major.minor.patch, defaulting the omitted components to zero")
    func parsesWellFormedVersions() {
        #expect(HelperToolVersion(parsing: "1.2.3") == HelperToolVersion(major: 1, minor: 2, patch: 3))
        #expect(HelperToolVersion(parsing: "1.2") == HelperToolVersion(major: 1, minor: 2, patch: 0))
        #expect(HelperToolVersion(parsing: "1") == HelperToolVersion(major: 1, minor: 0, patch: 0))
        #expect(HelperToolVersion(parsing: "0.0.0") == HelperToolVersion(major: 0, minor: 0, patch: 0))
    }

    @Test(
        "Refuses anything that is not major.minor.patch rather than guessing",
        arguments: ["", "1.2.3.4", "1.2.x", "v1.2.3", "1..3", "1.-2.3", "latest", " 1.2.3"]
    )
    func refusesMalformedVersions(text: String) {
        #expect(HelperToolVersion(parsing: text) == nil)
    }

    /// The reason this type exists. Comparing the reported strings directly puts 0.10.0 *before*
    /// 0.9.0, so a client would accept a tool older than the one it requires — and only find out
    /// at whichever later call needs the newer behaviour.
    @Test("Orders by numeric component, where string ordering would get it wrong")
    func ordersNumericallyNotLexicographically() throws {
        let nine = try #require(HelperToolVersion(parsing: "0.9.0"))
        let ten = try #require(HelperToolVersion(parsing: "0.10.0"))

        #expect(nine < ten)
        #expect("0.10.0" < "0.9.0", "the string comparison this type exists to replace")
    }

    @Test("Orders across all three components")
    func ordersAcrossComponents() {
        let ascending = [
            HelperToolVersion(major: 0, minor: 0, patch: 1),
            HelperToolVersion(major: 0, minor: 2, patch: 0),
            HelperToolVersion(major: 0, minor: 2, patch: 1),
            HelperToolVersion(major: 1, minor: 0, patch: 0),
            HelperToolVersion(major: 1, minor: 0, patch: 2),
            HelperToolVersion(major: 2, minor: 0, patch: 0),
        ]
        #expect(ascending.sorted() == ascending)
    }

    @Test("Round-trips through its description")
    func roundTripsThroughDescription() throws {
        let version = HelperToolVersion(major: 3, minor: 14, patch: 15)
        #expect(version.description == "3.14.15")
        #expect(HelperToolVersion(parsing: version.description) == version)
    }

    @Test("Survives the Codable round trip")
    func roundTripsThroughCodable() throws {
        let version = HelperToolVersion(major: 1, minor: 2, patch: 3)
        let decoded = try JSONDecoder().decode(HelperToolVersion.self, from: JSONEncoder().encode(version))
        #expect(decoded == version)
    }
}
#endif
