#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation

public enum PeerConnectionState: Sendable {
    case connecting
    case connected
    case disconnected(any Error)
    case cancelled
}
#endif
