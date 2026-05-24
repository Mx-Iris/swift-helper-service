#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import ServiceManagement

@available(macOS 13.0, macCatalyst 16.0, *)
public actor SMAppServiceDaemonInstaller {
    private let daemon: SMAppService

    private nonisolated let continuation: AsyncStream<SMAppService.Status>.Continuation

    public nonisolated let statusStream: AsyncStream<SMAppService.Status>

    public init(plistName: String) {
        self.daemon = SMAppService.daemon(plistName: plistName)

        var capturedContinuation: AsyncStream<SMAppService.Status>.Continuation!
        self.statusStream = AsyncStream<SMAppService.Status> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
        capturedContinuation.yield(daemon.status)
    }

    public var currentStatus: SMAppService.Status {
        daemon.status
    }

    public func register() async throws {
        try daemon.register()
        continuation.yield(daemon.status)
    }

    public func unregister() async throws {
        try await daemon.unregister()
        continuation.yield(daemon.status)
    }

    /// Pushes the current status to subscribers. Useful when an external event (NSWorkspace
    /// notification, settings round-trip, etc.) may have changed the status out-of-band.
    public func refresh() {
        continuation.yield(daemon.status)
    }

    public nonisolated func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    deinit {
        continuation.finish()
    }
}

@available(macOS 13.0, macCatalyst 16.0, *)
extension HelperClient {
    /// Factory for an `SMAppServiceDaemonInstaller` that installs the tool via the modern
    /// `SMAppService.daemon(plistName:)` API. The legacy `installTool(name:)` SMJobBless path is
    /// kept as a separate method for clients that still target older systems.
    public nonisolated func daemonInstaller(plistName: String) -> SMAppServiceDaemonInstaller {
        SMAppServiceDaemonInstaller(plistName: plistName)
    }
}
#endif
