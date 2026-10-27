import Foundation
import ObjectiveC
import Testing
@testable import HookKit

/// Covers the failure that made this payload inert on macOS 27, and the rules that replaced it.
///
/// What happened: macOS 27 added a `glassCompositingFilter:` argument to the Dock's three icon
/// setters. The payload's descriptors named the pre-27 spellings, two of them stopped existing, and
/// because installation is all-or-nothing the two hooks whose targets were *fine* did not go in
/// either. The payload stayed loaded, reported itself attached, and changed nothing — one log line
/// was the only evidence.
///
/// Two separate rules come out of that, and they are what these tests hold up:
///
/// 1. A descriptor carries candidate spellings, and the installer resolves to whichever one the host
///    has. One batch then works on both OS versions.
/// 2. When a host offers *several* candidates — which macOS 27 does, having kept the pre-27 icon
///    setter alongside the new one — the earliest listed candidate wins. Getting that order wrong
///    reproduces the original bug in its quietest form: a hook that installs, logs success, and
///    never runs, because the host no longer calls that spelling for the tiles in question.
///
/// Each test uses its own host class. `installAtomically` really does swap implementations, and the
/// classes here are process-global, so sharing one between tests would let an earlier swap decide a
/// later assertion.
@Suite("Cross-version signatures")
struct CrossVersionSignatureTests {
    // MARK: - Host doubles

    /// Stands in for the macOS 27 Dock: both spellings present.
    @objc(HookKitTestsHostWithBothSpellings)
    final class HostWithBothSpellings: NSObject {
        @objc func setImage(_ image: Any?, preferredGlassBackgroundStyle: Int) {}
        @objc func setImage(_ image: Any?, preferredGlassBackgroundStyle: Int, glassCompositingFilter: Any?) {}
    }

    /// Stands in for the macOS 26 Dock: only the pre-27 spelling.
    @objc(HookKitTestsHostWithPre27SpellingOnly)
    final class HostWithPre27SpellingOnly: NSObject {
        @objc func setImage(_ image: Any?, preferredGlassBackgroundStyle: Int) {}
    }

    /// A host that has neither, standing in for a future OS that moves the target again.
    @objc(HookKitTestsHostWithNeitherSpelling)
    final class HostWithNeitherSpelling: NSObject {
        @objc func somethingElseEntirely() {}
    }

    /// A second target in the same batch, used to show the batch is atomic.
    @objc(HookKitTestsUnrelatedHost)
    final class UnrelatedHost: NSObject {
        @objc func tiles() -> Any? { nil }
    }

    // MARK: - The encodings under test

    private static let pre27SelectorName = "setImage:preferredGlassBackgroundStyle:"
    private static let macOS27SelectorName = "setImage:preferredGlassBackgroundStyle:glassCompositingFilter:"

    /// The same strings the payload's descriptors carry, read off a live Dock with
    /// `method_getTypeEncoding` — `v32@0:8@16q24` on macOS 26.5.2, `v40@0:8@16q24@32` on 27.2.
    ///
    /// Asserting that Swift's `@objc` thunks produce these too is the point of
    /// ``hostDoublesEncodeTheSameWayTheDockDoes()``: without it these doubles could drift from the
    /// thing they stand in for and every test below would still pass.
    private static let pre27TypeEncoding = "v32@0:8@16q24"
    private static let macOS27TypeEncoding = "v40@0:8@16q24@32"

    // MARK: - Tests

    @Test("The host doubles encode the same way the Dock does")
    func hostDoublesEncodeTheSameWayTheDockDoes() {
        let pre27Encoding = MethodHookInspector.typeEncoding(
            forClassNamed: "HookKitTestsHostWithBothSpellings",
            selector: NSSelectorFromString(Self.pre27SelectorName)
        )
        #expect(pre27Encoding != nil)
        #expect(MethodHookInspector.typeEncodingsMatch(pre27Encoding ?? "", Self.pre27TypeEncoding))

        let macOS27Encoding = MethodHookInspector.typeEncoding(
            forClassNamed: "HookKitTestsHostWithBothSpellings",
            selector: NSSelectorFromString(Self.macOS27SelectorName)
        )
        #expect(macOS27Encoding != nil)
        #expect(MethodHookInspector.typeEncodingsMatch(macOS27Encoding ?? "", Self.macOS27TypeEncoding))
    }

    /// The regression itself, in the form that is easy to get wrong twice.
    ///
    /// macOS 27 kept both spellings, so "does the host have this method" is true for both and cannot
    /// decide between them. Only the declared order can. If a later refactor sorts candidates by
    /// anything else — newest last, alphabetical, whatever the host happens to enumerate first —
    /// this fails, and that is the whole reason it exists.
    @Test("A host with both spellings resolves to the first candidate listed")
    func hostWithBothSpellingsResolvesToTheFirstCandidate() {
        let descriptor = MethodHookDescriptor(
            className: "HookKitTestsHostWithBothSpellings",
            variants: [
                MethodHookVariant(
                    selector: NSSelectorFromString(Self.macOS27SelectorName),
                    expectedTypeEncoding: Self.macOS27TypeEncoding,
                    makeReplacement: { _ in Self.inertImplementationTakingCompositingFilter }
                ),
                MethodHookVariant(
                    selector: NSSelectorFromString(Self.pre27SelectorName),
                    expectedTypeEncoding: Self.pre27TypeEncoding,
                    makeReplacement: { _ in Self.inertImplementationWithoutCompositingFilter }
                ),
            ]
        )

        let originalPre27Implementation = Self.implementation(
            ofClassNamed: "HookKitTestsHostWithBothSpellings",
            selectorNamed: Self.pre27SelectorName
        )

        #expect(throws: Never.self) { try MethodHookInstaller.installAtomically([descriptor]) }

        // The listed-first candidate is the one that got swapped…
        let macOS27ImplementationAfterwards = Self.implementation(
            ofClassNamed: "HookKitTestsHostWithBothSpellings",
            selectorNamed: Self.macOS27SelectorName
        )
        #expect(macOS27ImplementationAfterwards == Self.inertImplementationTakingCompositingFilter)

        // …and the other spelling was left strictly alone, rather than both being hooked.
        let pre27ImplementationAfterwards = Self.implementation(
            ofClassNamed: "HookKitTestsHostWithBothSpellings",
            selectorNamed: Self.pre27SelectorName
        )
        #expect(pre27ImplementationAfterwards == originalPre27Implementation)
    }

    @Test("A host with only the pre-27 spelling falls back to it")
    func hostWithOnlyPre27SpellingFallsBack() {
        let descriptor = MethodHookDescriptor(
            className: "HookKitTestsHostWithPre27SpellingOnly",
            variants: [
                MethodHookVariant(
                    selector: NSSelectorFromString(Self.macOS27SelectorName),
                    expectedTypeEncoding: Self.macOS27TypeEncoding,
                    makeReplacement: { _ in Self.inertImplementationTakingCompositingFilter }
                ),
                MethodHookVariant(
                    selector: NSSelectorFromString(Self.pre27SelectorName),
                    expectedTypeEncoding: Self.pre27TypeEncoding,
                    makeReplacement: { _ in Self.inertImplementationWithoutCompositingFilter }
                ),
            ]
        )

        #expect(throws: Never.self) { try MethodHookInstaller.installAtomically([descriptor]) }

        let implementationAfterwards = Self.implementation(
            ofClassNamed: "HookKitTestsHostWithPre27SpellingOnly",
            selectorNamed: Self.pre27SelectorName
        )
        #expect(implementationAfterwards == Self.inertImplementationWithoutCompositingFilter)
    }

    /// What the payload should do on an OS that moved the target somewhere it was not taught about:
    /// nothing at all, and say which spellings it tried.
    @Test("A host with neither spelling is left untouched, and every candidate is reported")
    func hostWithNeitherSpellingIsReported() {
        let descriptor = MethodHookDescriptor(
            className: "HookKitTestsHostWithNeitherSpelling",
            variants: [
                MethodHookVariant(
                    selector: NSSelectorFromString(Self.macOS27SelectorName),
                    expectedTypeEncoding: Self.macOS27TypeEncoding,
                    makeReplacement: { _ in Self.inertImplementationTakingCompositingFilter }
                ),
                MethodHookVariant(
                    selector: NSSelectorFromString(Self.pre27SelectorName),
                    expectedTypeEncoding: Self.pre27TypeEncoding,
                    makeReplacement: { _ in Self.inertImplementationWithoutCompositingFilter }
                ),
            ]
        )

        let result = MethodHookInstaller.validateOnly([descriptor])
        guard case .failure(let failure) = result else {
            Issue.record("a host with neither spelling should not validate")
            return
        }
        guard case .noUsableVariant(let className, let rejections) = failure else {
            Issue.record("expected noUsableVariant, got \(failure)")
            return
        }

        #expect(className == "HookKitTestsHostWithNeitherSpelling")
        // Both candidates reported, not just the first one to fail: on a cross-version descriptor
        // exactly one candidate is *expected* to be absent, so a single rejection is not a diagnosis.
        #expect(rejections.count == 2)
        #expect(failure.description.contains(Self.macOS27SelectorName))
        #expect(failure.description.contains(Self.pre27SelectorName))
    }

    /// A signature that changed rather than disappeared has to report the encoding the host actually
    /// has — that string is the fix, and the log line is where the next person gets it.
    @Test("A changed signature reports the host's own encoding")
    func changedSignatureReportsTheHostEncoding() {
        let deliberatelyWrongEncoding = "v32@0:8@16@24"
        let descriptor = MethodHookDescriptor(
            className: "HookKitTestsHostWithPre27SpellingOnly",
            selector: NSSelectorFromString(Self.pre27SelectorName),
            expectedTypeEncoding: deliberatelyWrongEncoding,
            makeReplacement: { _ in Self.inertImplementationWithoutCompositingFilter }
        )

        let result = MethodHookInstaller.validateOnly([descriptor])
        guard case .failure(let failure) = result else {
            Issue.record("a mismatched encoding should not validate")
            return
        }

        #expect(failure.description.contains(Self.pre27TypeEncoding))
        #expect(failure.description.contains(deliberatelyWrongEncoding))
    }

    /// The mechanism that turned two broken descriptors into four uninstalled hooks.
    ///
    /// Atomicity is deliberate and stays — a half-hooked host is worse than an untouched one — so
    /// this test does not argue with it. It pins it down, because the cost of that choice is exactly
    /// what made one changed signature take out the whole payload, and anything that quietly
    /// installed "the ones that worked" would be a different design with different failure modes.
    @Test("One unusable descriptor leaves the rest of the batch uninstalled")
    func oneUnusableDescriptorBlocksTheWholeBatch() {
        let unusableDescriptor = MethodHookDescriptor(
            className: "HookKitTestsHostWithNeitherSpelling",
            selector: NSSelectorFromString(Self.pre27SelectorName),
            expectedTypeEncoding: Self.pre27TypeEncoding,
            makeReplacement: { _ in Self.inertImplementationWithoutCompositingFilter }
        )
        let perfectlyGoodDescriptor = MethodHookDescriptor(
            className: "HookKitTestsUnrelatedHost",
            selector: NSSelectorFromString("tiles"),
            expectedTypeEncoding: "@16@0:8",
            makeReplacement: { _ in Self.inertObjectGetterImplementation }
        )

        let implementationBefore = Self.implementation(
            ofClassNamed: "HookKitTestsUnrelatedHost",
            selectorNamed: "tiles"
        )

        #expect(throws: MethodHookInstallationFailure.self) {
            try MethodHookInstaller.installAtomically([unusableDescriptor, perfectlyGoodDescriptor])
        }

        let implementationAfter = Self.implementation(
            ofClassNamed: "HookKitTestsUnrelatedHost",
            selectorNamed: "tiles"
        )
        #expect(implementationAfter == implementationBefore)
    }

    @Test("A class the host does not have is reported as such")
    func missingClassIsReported() {
        let descriptor = MethodHookDescriptor(
            className: "HookKitTestsClassThatDoesNotExist",
            selector: NSSelectorFromString(Self.pre27SelectorName),
            expectedTypeEncoding: Self.pre27TypeEncoding,
            makeReplacement: { _ in Self.inertImplementationWithoutCompositingFilter }
        )

        let result = MethodHookInstaller.validateOnly([descriptor])
        guard case .failure(let failure) = result, case .classNotFound(let className) = failure else {
            Issue.record("expected classNotFound, got \(result)")
            return
        }
        #expect(className == "HookKitTestsClassThatDoesNotExist")
    }

    // MARK: - Replacement implementations

    // Built once and reused, so a test can assert that the implementation now installed is the one
    // it asked for rather than merely "something different from before".
    //
    // `nonisolated(unsafe)` because `IMP` is an `OpaquePointer` and so not `Sendable`. These three
    // are written once during initialization and only ever read afterwards, which is the case the
    // annotation is for.

    private nonisolated(unsafe) static let inertImplementationTakingCompositingFilter: IMP = {
        let block: @convention(block) (AnyObject, AnyObject?, Int, AnyObject?) -> Void = { _, _, _, _ in }
        return imp_implementationWithBlock(block)
    }()

    private nonisolated(unsafe) static let inertImplementationWithoutCompositingFilter: IMP = {
        let block: @convention(block) (AnyObject, AnyObject?, Int) -> Void = { _, _, _ in }
        return imp_implementationWithBlock(block)
    }()

    private nonisolated(unsafe) static let inertObjectGetterImplementation: IMP = {
        let block: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
        return imp_implementationWithBlock(block)
    }()

    private static func implementation(ofClassNamed className: String, selectorNamed selectorName: String) -> IMP? {
        guard let resolvedClass = objc_getClass(className) as? AnyClass,
              let method = class_getInstanceMethod(resolvedClass, NSSelectorFromString(selectorName))
        else { return nil }
        return method_getImplementation(method)
    }
}
