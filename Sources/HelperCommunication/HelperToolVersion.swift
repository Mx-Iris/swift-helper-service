#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation

/// A `major.minor.patch` version, as carried by ``FetchVersionRequest``.
///
/// ## Why this exists
///
/// `FetchVersionRequest` answers with a free-form `String`, and a client that wants to know
/// "is the installed tool new enough for me" has to interpret it. Comparing those strings
/// lexicographically is wrong in a way that only shows up late: `"0.10.0" < "0.9.0"` is `true`.
///
/// The wire format stays a `String` — it is frozen, and nothing here changes it. This type is the
/// agreed *interpretation* of that string, so every caller reads it the same way.
///
/// ## Why not reach for the error instead
///
/// `HelperClient.errorIndicatesOutdatedPeer(_:)` looks like the direct answer and is not: it
/// cannot return `true`. A tool that does not recognise a message never replies, so the caller
/// sees `connectionInterrupted` — indistinguishable from a dropped connection. **Asking is the
/// only reliable way to find out**, which is what ``HelperClient/requireToolVersion(atLeast:)``
/// does.
public struct HelperToolVersion: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int

    public let minor: Int

    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `major.minor.patch`. A missing minor or patch reads as zero, so `"1"` and `"1.0.0"`
    /// are the same version; anything else — a non-numeric component, a fourth component, an
    /// empty string — returns `nil` rather than guessing.
    public init?(parsing text: String) {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(components.count) else { return nil }

        var numbers: [Int] = []
        for component in components {
            guard let number = Int(component), number >= 0 else { return nil }
            numbers.append(number)
        }

        self.major = numbers[0]
        self.minor = numbers.count > 1 ? numbers[1] : 0
        self.patch = numbers.count > 2 ? numbers[2] : 0
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: HelperToolVersion, rhs: HelperToolVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Why a client decided the installed tool will not do.
public enum HelperToolVersionMismatch: LocalizedError, Sendable, Hashable {
    /// The tool answered, and it is older than the caller requires.
    case toolIsOlderThanRequired(installed: HelperToolVersion, required: HelperToolVersion)

    /// The tool answered with something that is not `major.minor.patch`.
    ///
    /// Treated as a mismatch rather than ignored: a tool whose version cannot be read cannot be
    /// shown to satisfy a requirement, and silently proceeding is how an incompatible pair ends
    /// up failing later at a call site that has nothing to do with versions.
    case toolVersionIsUnreadable(reported: String, required: HelperToolVersion)

    public var errorDescription: String? {
        switch self {
        case let .toolIsOlderThanRequired(installed, required):
            "The installed helper tool is version \(installed); this client requires \(required) or newer."
        case let .toolVersionIsUnreadable(reported, required):
            "The installed helper tool reported the version \"\(reported)\", which is not major.minor.patch; this client requires \(required) or newer."
        }
    }
}
#endif
