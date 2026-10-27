#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Testing
@preconcurrency import SwiftyXPC
import HelperCommunication
import MainService

/// The registry used to only ever grow: a sub-server or peer that exited left its `XPCEndpoint`
/// behind, and the next client to ask for it got a handle it could never connect to. These tests
/// pin the eviction, and pin that a registrant which does not report a pid keeps the old
/// behaviour rather than being evicted on someone else's exit.
///
/// Each test registers against a real short-lived child process, because the eviction is driven by
/// a `DispatchSourceProcess` watching a real pid — a fake one would exercise none of it.
@Suite("Endpoint registry cleanup")
struct EndpointRegistryCleanupTests {
    @Test("An entry is evicted once the process that registered it exits")
    func entryIsEvictedWhenItsRegistrantExits() async throws {
        let service = MainService(version: "1.0.0")
        let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        let info = HelperServerInfo(name: "com.JH.Test.Tool", identifier: "com.JH.Test.SubServer")

        let child = try startLongLivedChildProcess()
        defer { terminateIfRunning(child) }

        try await service.registerEndpoint(
            request: RegisterEndpointRequest(
                info: info,
                endpoint: listener.endpoint,
                registrantProcessIdentifier: child.processIdentifier
            )
        )
        #expect(await registryContains(info, in: service), "the entry should be there while its registrant runs")

        terminateIfRunning(child)
        child.waitUntilExit()

        let evicted = await waitUntil { await !registryContains(info, in: service) }
        #expect(evicted, "the entry should be gone once its registrant exited")
    }

    @Test("An entry registered without a pid survives another process exiting")
    func entryWithoutRegistrantPidIsNotEvicted() async throws {
        let service = MainService(version: "1.0.0")
        let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        let anonymousInfo = HelperServerInfo(name: "com.JH.Test.Tool", identifier: "com.JH.Test.Anonymous")
        let monitoredInfo = HelperServerInfo(name: "com.JH.Test.Tool", identifier: "com.JH.Test.Monitored")

        let child = try startLongLivedChildProcess()
        defer { terminateIfRunning(child) }

        try await service.registerEndpoint(
            request: RegisterEndpointRequest(
                info: anonymousInfo,
                endpoint: listener.endpoint,
                registrantProcessIdentifier: nil
            )
        )
        try await service.registerEndpoint(
            request: RegisterEndpointRequest(
                info: monitoredInfo,
                endpoint: listener.endpoint,
                registrantProcessIdentifier: child.processIdentifier
            )
        )

        terminateIfRunning(child)
        child.waitUntilExit()

        let monitoredWasEvicted = await waitUntil { await !registryContains(monitoredInfo, in: service) }
        #expect(monitoredWasEvicted, "the monitored entry should be gone")
        #expect(await registryContains(anonymousInfo, in: service), "an entry with no reported pid must not be collateral damage")
    }

    @Test("Re-registering from a new process detaches the entry from the old one's monitor")
    func reRegisteringRebindsTheEntryToTheNewProcess() async throws {
        let service = MainService(version: "1.0.0")
        let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        let info = HelperServerInfo(name: "com.JH.Test.Tool", identifier: "com.JH.Test.Restarting")

        let firstChild = try startLongLivedChildProcess()
        defer { terminateIfRunning(firstChild) }
        try await service.registerEndpoint(
            request: RegisterEndpointRequest(
                info: info,
                endpoint: listener.endpoint,
                registrantProcessIdentifier: firstChild.processIdentifier
            )
        )

        // The sub-server crashed and came back under a new pid, re-registering the same identifier.
        let secondChild = try startLongLivedChildProcess()
        defer { terminateIfRunning(secondChild) }
        try await service.registerEndpoint(
            request: RegisterEndpointRequest(
                info: info,
                endpoint: listener.endpoint,
                registrantProcessIdentifier: secondChild.processIdentifier
            )
        )

        terminateIfRunning(firstChild)
        firstChild.waitUntilExit()

        // Give the (now detached) monitor for the dead process every chance to fire.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await registryContains(info, in: service), "the dead process's exit must not evict the live registration that replaced it")

        terminateIfRunning(secondChild)
        secondChild.waitUntilExit()
        let evicted = await waitUntil { await !registryContains(info, in: service) }
        #expect(evicted, "the entry should follow the process that currently owns it")
    }
}

// MARK: - Helpers

private func startLongLivedChildProcess() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["300"]
    try process.run()
    return process
}

private func terminateIfRunning(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
}

private func registryContains(_ info: HelperServerInfo, in service: MainService) async -> Bool {
    do {
        _ = try await service.fetchEndpoint(request: FetchEndpointRequest(info: info))
        return true
    } catch {
        return false
    }
}

/// Polls `condition` until it holds or the budget runs out. The eviction travels from a
/// `DispatchSourceProcess` through a `Task` hop into the actor, so it is not observable the
/// instant the child exits.
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
#endif
