import Foundation
import FoundationToolbox

/// Logs the first time a hook's replacement actually runs.
///
/// Installing successfully is not evidence that a hook is on a live path. A host can keep an old
/// spelling of a method alongside a new one and quietly move its own call sites to the new one —
/// macOS 27 did exactly that to the Dock's icon setters — and then a hook on the old spelling
/// validates, logs that it went in, and never runs once. Nothing errors, nothing crashes, and the
/// payload reports itself healthy while doing nothing at all.
///
/// That is the most expensive kind of failure to diagnose and the cheapest kind to instrument, so
/// every hook on a path whose spelling has moved before carries one of these. Comparing "installed"
/// against "ran" in the log is then a direct answer to "is this hook on the path the host actually
/// uses", with no debugger and no disassembly.
@Loggable(subsystem: "com.JH.HookKit", category: "HookActivity")
public final class HookActivityReporter: @unchecked Sendable {
    private let hookDescription: String

    /// Guarded by ``lock``.
    private var hasReported = false

    /// `os_unfair_lock` rather than `Synchronization.Atomic`, which is where this started: `Atomic`
    /// is macOS 15 and this package's floor is 10.15, and a reporter unavailable on everything
    /// below 15 is a reporter most payloads cannot carry.
    ///
    /// The cost is real but small. The atomic version's fast path was a relaxed load and a branch;
    /// this one takes an uncontended lock on every call — a couple of atomic operations, tens of
    /// nanoseconds — because there is no sound way to read the flag without it. That is affordable
    /// on a rendering path; it would not be inside a tight loop, and a hook in one should count
    /// elsewhere rather than reach for this.
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    public init(hookDescription: String) {
        self.hookDescription = hookDescription
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Call at the top of a replacement block.
    public func noteCall() {
        os_unfair_lock_lock(lock)
        let isFirstCall = !hasReported
        hasReported = true
        os_unfair_lock_unlock(lock)

        guard isFirstCall else { return }
        #log(.default, "Hook \(self.hookDescription, privacy: .public) ran for the first time")
    }

    /// Whether the replacement has run at least once.
    ///
    /// Exposed so a payload can answer "is this hook live?" over its channel to the host, rather
    /// than the question only being answerable by reading the log on the machine it happened on.
    public var hasRun: Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return hasReported
    }
}
