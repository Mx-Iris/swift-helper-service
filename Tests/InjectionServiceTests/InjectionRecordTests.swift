#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
import InjectionServiceInterface
@testable import InjectionServiceImplementation

/// The daemon now keeps its own list of what it injected, replacing one built from payloads
/// checking in. The behaviour worth pinning is not that a record appears — that is one dictionary
/// assignment — but **what happens to it afterwards**, because the whole point of the change is
/// that nothing ever reports back:
///
/// - a record must leave when its host process exits, or the list becomes a graveyard of pids
///   that have since been reused by unrelated processes;
/// - injecting twice into one process must not leave two entries claiming different payloads.
///
/// Each test drives a real short-lived child process, because the eviction runs off a
/// `DispatchSourceProcess` watching a real pid — a fabricated one would exercise none of it. Same
/// approach as `MainServiceTests`' registry cleanup.
///
/// Records are written here through `recordInjection(...)` rather than by injecting: nothing in
/// this repository ever performs a real injection, and the lifecycle is the same either way.
@Suite("Injection records")
struct InjectionRecordTests {
    @Test("A record is kept while its host process runs")
    func recordIsKeptWhileHostRuns() async throws {
        let service = InjectionService()
        let host = try startLongLivedChildProcess()
        defer { terminateIfRunning(host) }

        await service.recordInjection(
            hostProcessIdentifier: host.processIdentifier,
            payloadPath: "/tmp/Probe.dylib",
            strategy: .dlopen
        )

        let records = await service.injectionRecords()
        #expect(records.count == 1)
        #expect(records.first?.hostProcessIdentifier == host.processIdentifier)
        #expect(records.first?.payloadPath == "/tmp/Probe.dylib")
        #expect(records.first?.strategy == .dlopen)
    }

    @Test("A record is evicted once its host process exits")
    func recordIsEvictedWhenHostExits() async throws {
        let service = InjectionService()
        let host = try startLongLivedChildProcess()
        defer { terminateIfRunning(host) }

        await service.recordInjection(
            hostProcessIdentifier: host.processIdentifier,
            payloadPath: "/tmp/Probe.dylib",
            strategy: .dlopen
        )
        #expect(await service.injectionRecords().count == 1, "the record should be there while its host runs")

        terminateIfRunning(host)
        host.waitUntilExit()

        let evicted = await waitUntil { await service.injectionRecords().isEmpty }
        #expect(evicted, "the record should be gone once its host exited")
    }

    @Test("Injecting twice into one process leaves one record, the later one")
    func secondInjectionReplacesTheFirstRecord() async throws {
        let service = InjectionService()
        let host = try startLongLivedChildProcess()
        defer { terminateIfRunning(host) }

        await service.recordInjection(
            hostProcessIdentifier: host.processIdentifier,
            payloadPath: "/tmp/First.dylib",
            strategy: .dlopen
        )
        await service.recordInjection(
            hostProcessIdentifier: host.processIdentifier,
            payloadPath: "/tmp/Second.dylib",
            strategy: .machVirtualMemoryRemap
        )

        let records = await service.injectionRecords()
        #expect(records.count == 1, "one host process should hold one record")
        #expect(records.first?.payloadPath == "/tmp/Second.dylib")
        #expect(records.first?.strategy == .machVirtualMemoryRemap)
    }

    @Test("Two hosts are recorded independently, oldest first")
    func recordsFromTwoHostsAreIndependent() async throws {
        let service = InjectionService()
        let firstHost = try startLongLivedChildProcess()
        defer { terminateIfRunning(firstHost) }
        let secondHost = try startLongLivedChildProcess()
        defer { terminateIfRunning(secondHost) }

        await service.recordInjection(
            hostProcessIdentifier: firstHost.processIdentifier,
            payloadPath: "/tmp/First.dylib",
            strategy: .dlopen
        )
        await service.recordInjection(
            hostProcessIdentifier: secondHost.processIdentifier,
            payloadPath: "/tmp/Second.dylib",
            strategy: .dlopen
        )

        let records = await service.injectionRecords()
        #expect(records.count == 2)
        #expect(records.map(\.payloadPath) == ["/tmp/First.dylib", "/tmp/Second.dylib"], "oldest first")

        terminateIfRunning(firstHost)
        firstHost.waitUntilExit()

        let onlySecondRemains = await waitUntil {
            await service.injectionRecords().map(\.hostProcessIdentifier) == [secondHost.processIdentifier]
        }
        #expect(onlySecondRemains, "one host exiting should not touch the other's record")
    }
}

/// A `FetchInjectionRecordsRequest` has to survive the XPC round trip, and an identifier that
/// changes silently is a wire break with no compile error — see WireCompatibility.md.
@Suite("Injection record wire format")
struct InjectionRecordWireFormatTests {
    @Test("The request identifier is the one clients send")
    func requestIdentifierIsStable() {
        #expect(FetchInjectionRecordsRequest.identifier == "com.JH.HelperService.InjectionService.FetchInjectionRecords")
    }

    @Test("A record survives a Codable round trip")
    func recordSurvivesRoundTrip() throws {
        let original = InjectionRecord(
            hostProcessIdentifier: 4321,
            payloadPath: "/tmp/Probe.dylib",
            injectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            strategy: .machVirtualMemoryRemap
        )

        let decoded = try JSONDecoder().decode(
            InjectionRecord.self,
            from: try JSONEncoder().encode(original)
        )

        #expect(decoded == original)
    }
}

// MARK: - Test support

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
