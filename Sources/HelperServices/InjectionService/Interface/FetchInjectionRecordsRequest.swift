#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

/// Asks the daemon which processes it has injected into.
///
/// See ``InjectionRecord`` for what the answer does and does not claim — in short, the daemon
/// wrote a payload into each of these processes, and whether any of them is still listening is not
/// something the daemon can know.
///
/// Entries disappear when the host process exits. They do **not** disappear when a payload stops
/// answering, because nothing tells the daemon about that.
///
/// There is no matching write request on purpose. The only thing that may add a record is the
/// injection itself: the daemon performed it, so it already knows the pid and the payload without
/// being told. Letting callers register entries is what made the previous design need a rule about
/// whether a registrant's self-reported pid could be trusted.
public struct FetchInjectionRecordsRequest: Codable, Request {
    public typealias Response = [InjectionRecord]

    public static let identifier: String = "com.JH.HelperService.InjectionService.FetchInjectionRecords"

    public init() {}
}

#endif
