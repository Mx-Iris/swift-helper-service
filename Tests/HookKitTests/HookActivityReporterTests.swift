import Foundation
import Testing
@testable import HookKit

/// The distinction the reporter exists to make: *installed* and *ran* are different facts, and a
/// hook can have the first without ever getting the second.
@Suite("Hook activity reporter")
struct HookActivityReporterTests {
    @Test("A hook that has not run says so")
    func startsUnrun() {
        #expect(HookActivityReporter(hookDescription: "-[Example method]").hasRun == false)
    }

    @Test("One call flips it, and further calls change nothing")
    func firstCallFlipsIt() {
        let reporter = HookActivityReporter(hookDescription: "-[Example method]")
        reporter.noteCall()
        #expect(reporter.hasRun)
        reporter.noteCall()
        reporter.noteCall()
        #expect(reporter.hasRun)
    }

    /// A replacement block runs on whatever thread the host calls it from, and the Dock calls its
    /// icon setters off the main thread. An unsynchronised flag here would be a data race on a
    /// path the payload does not control.
    @Test("Concurrent calls settle on one answer")
    func concurrentCallsAreSafe() async {
        let reporter = HookActivityReporter(hookDescription: "-[Example method]")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 200 {
                group.addTask { reporter.noteCall() }
            }
        }

        #expect(reporter.hasRun)
    }
}
