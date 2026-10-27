import Foundation
import ObjectiveC

/// One candidate spelling of the method a hook targets: the selector, the type encoding it was
/// written against, and how to build a replacement for it.
///
/// A hook needs more than one candidate when the host spells the same operation differently across
/// operating system versions. macOS 27 added a `glassCompositingFilter:` argument to every icon
/// setter on the Dock's `Tile`, so a payload that has to work on both 26 and 27 declares both
/// signatures and lets the installer pick whichever one this host actually has.
///
/// Each candidate carries its own replacement builder rather than sharing one: a replacement
/// block's parameter list has to match the signature it is installed over, and two signatures with
/// different arities cannot share a block.
public struct MethodHookVariant: Sendable {
    /// Selector of the method to replace.
    public let selector: Selector

    /// The method type encoding this variant was written against, as produced by
    /// `method_getTypeEncoding`.
    ///
    /// The installer compares this against the live encoding and refuses to install on any
    /// mismatch. This is the single most valuable safety check in the whole pipeline: a method
    /// whose parameter list changed under us would otherwise be called through a replacement built
    /// for the old signature, which corrupts registers and crashes the host.
    ///
    /// Obtain the value by reading it out of a live host with
    /// ``MethodHookInspector/typeEncoding(forClassNamed:selector:isInstanceMethod:)``, or from the
    /// encodings ``MethodHookInstallationFailure`` prints when a system update moves the target.
    /// Never hand-derive it from a decompiled signature.
    public let expectedTypeEncoding: String

    /// Builds the replacement implementation, given the original one.
    ///
    /// Implement this by returning `imp_implementationWithBlock` over a block whose signature
    /// matches ``expectedTypeEncoding`` — first block parameter is the receiver, the selector is
    /// *not* passed. Capture `originalImplementation` to forward to the host's behaviour; cast it
    /// to a `@convention(c)` function type matching the same encoding.
    public let makeReplacement: @Sendable (_ originalImplementation: IMP) -> IMP

    public init(
        selector: Selector,
        expectedTypeEncoding: String,
        makeReplacement: @escaping @Sendable (_ originalImplementation: IMP) -> IMP
    ) {
        self.selector = selector
        self.expectedTypeEncoding = expectedTypeEncoding
        self.makeReplacement = makeReplacement
    }
}

extension MethodHookVariant: CustomStringConvertible {
    public var description: String { NSStringFromSelector(selector) }
}

/// Describes one Objective-C method implementation swap that a payload wants to install.
///
/// A descriptor is declarative on purpose: it names the target by string and selector rather
/// than by a compile-time symbol, because payloads hook classes that live in the host process
/// and are unavailable at build time. `MethodHookInstaller` validates every candidate before
/// touching any method, so a descriptor that no longer matches the host — a renamed class, a
/// changed signature after an operating system update — is rejected instead of corrupting the
/// host process.
public struct MethodHookDescriptor: Sendable {
    /// Name of the Objective-C class that declares the method, resolved with `objc_getClass`.
    public let className: String

    /// Whether the method is an instance method (`true`) or a class method (`false`).
    public let isInstanceMethod: Bool

    /// Candidate spellings of the target, in preference order.
    ///
    /// The installer takes the first one this host both declares and still matches. Order is
    /// therefore a statement of preference, not of correctness: a host can offer two candidates at
    /// once — macOS 27 kept the pre-27 icon setter alongside the new one — and then the earlier
    /// entry wins and the later ones are never consulted.
    ///
    /// So order by which spelling the host is known to *call*, not by which is newest. A hook
    /// installed on a spelling the host no longer calls for the tiles in question validates
    /// cleanly, logs success, and never runs: the quietest failure in this whole design, and the
    /// reason ``MethodHookDescriptor`` carries candidates rather than the payload picking one at
    /// build time.
    public let variants: [MethodHookVariant]

    /// A hook whose target is spelled the same way on every supported host.
    public init(
        className: String,
        selector: Selector,
        isInstanceMethod: Bool = true,
        expectedTypeEncoding: String,
        makeReplacement: @escaping @Sendable (_ originalImplementation: IMP) -> IMP
    ) {
        self.init(
            className: className,
            isInstanceMethod: isInstanceMethod,
            variants: [
                MethodHookVariant(
                    selector: selector,
                    expectedTypeEncoding: expectedTypeEncoding,
                    makeReplacement: makeReplacement
                ),
            ]
        )
    }

    /// A hook whose target is spelled differently depending on the host's operating system version.
    ///
    /// - Parameter variants: Candidate spellings in preference order. Must not be empty.
    public init(
        className: String,
        isInstanceMethod: Bool = true,
        variants: [MethodHookVariant]
    ) {
        precondition(!variants.isEmpty, "a hook descriptor needs at least one candidate spelling")
        self.className = className
        self.isInstanceMethod = isInstanceMethod
        self.variants = variants
    }
}

extension MethodHookDescriptor: CustomStringConvertible {
    public var description: String {
        let methodTypeMarker = isInstanceMethod ? "-" : "+"
        let candidateNames = variants.map(\.description).joined(separator: " or ")
        return "\(methodTypeMarker)[\(className) \(candidateNames)]"
    }

    /// How to name this hook once the installer has settled on one candidate.
    ///
    /// ``description`` lists every candidate, which is what a declaration should say but not what a
    /// log line about an installed hook should: that one wants the single spelling that actually
    /// went in, because on a host offering several it is the only interesting part.
    public func description(resolvedTo variant: MethodHookVariant) -> String {
        let methodTypeMarker = isInstanceMethod ? "-" : "+"
        return "\(methodTypeMarker)[\(className) \(variant.description)]"
    }
}
