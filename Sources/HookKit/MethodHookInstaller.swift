import Foundation
import ObjectiveC
import FoundationToolbox

/// Why one candidate spelling of a hook's target could not be used.
public enum MethodHookVariantRejection: Sendable, CustomStringConvertible {
    case methodNotFound(selectorName: String)
    case typeEncodingMissing(selectorName: String)
    case typeEncodingMismatch(selectorName: String, expectedTypeEncoding: String, hostTypeEncoding: String)

    public var description: String {
        switch self {
        case .methodNotFound(let selectorName):
            return "\(selectorName) is not declared here"
        case .typeEncodingMissing(let selectorName):
            return "\(selectorName) has no type encoding"
        case .typeEncodingMismatch(let selectorName, let expectedTypeEncoding, let hostTypeEncoding):
            return "\(selectorName) expected \(expectedTypeEncoding), host has \(hostTypeEncoding)"
        }
    }
}

/// Why a batch of hooks was rejected.
public enum MethodHookInstallationFailure: Error, CustomStringConvertible {
    case classNotFound(className: String)

    /// None of a descriptor's candidate spellings matched this host.
    ///
    /// The rejection list is the whole diagnosis, and it is worth reading rather than skimming. For
    /// every candidate that exists but no longer matches it prints the encoding the host actually
    /// has — which is exactly the value a corrected descriptor needs. That turns "an OS update
    /// broke this payload" into "here is the new signature" for the price of one log line, instead
    /// of a debugger session attached to someone else's process.
    case noUsableVariant(className: String, rejections: [MethodHookVariantRejection])

    public var description: String {
        switch self {
        case .classNotFound(let className):
            return "class \(className) not found in this process"
        case .noUsableVariant(let className, let rejections):
            let rejectionDetail = rejections.map(\.description).joined(separator: "; ")
            return "no usable signature on \(className) — \(rejectionDetail)"
        }
    }
}

/// Installs ``MethodHookDescriptor`` batches into the current process.
///
/// The installer is deliberately all-or-nothing. Every descriptor is resolved and signature-checked
/// first; only when the whole batch validates does it swap a single implementation. A payload that
/// half-installs is worse than one that does not install at all, because the host then runs a mix of
/// hooked and unhooked behaviour that no one designed or tested.
@Loggable(subsystem: "com.JH.HookKit", category: "MethodHookInstaller")
public enum MethodHookInstaller {

    /// A candidate that passed validation, carrying the resolved handle so the swap phase needs no
    /// lookups.
    private struct ValidatedHook {
        let descriptor: MethodHookDescriptor
        let variant: MethodHookVariant
        let method: Method
    }

    /// Validates every descriptor, then swaps every implementation.
    ///
    /// - Throws: ``MethodHookInstallationFailure`` for the first descriptor that fails validation.
    ///   Nothing has been modified when this throws.
    public static func installAtomically(_ descriptors: [MethodHookDescriptor]) throws {
        let validatedHooks = try descriptors.map(validate)

        for validatedHook in validatedHooks {
            let originalImplementation = method_getImplementation(validatedHook.method)
            let replacementImplementation = validatedHook.variant.makeReplacement(originalImplementation)
            method_setImplementation(validatedHook.method, replacementImplementation)
            let hookDescription = validatedHook.descriptor.description(resolvedTo: validatedHook.variant)
            #log(.info, "Installed hook \(hookDescription, privacy: .public)")
        }
    }

    /// Validates a batch without installing anything.
    ///
    /// Useful for a self-check on payload startup that reports host compatibility before any
    /// behaviour changes — for example to decide between hooking and staying dormant.
    public static func validateOnly(_ descriptors: [MethodHookDescriptor]) -> Result<Void, MethodHookInstallationFailure> {
        do {
            _ = try descriptors.map(validate)
            return .success(())
        } catch let failure as MethodHookInstallationFailure {
            return .failure(failure)
        } catch {
            preconditionFailure("validate(_:) only throws MethodHookInstallationFailure")
        }
    }

    /// Resolves a descriptor to the first candidate this host both declares and still matches.
    ///
    /// Candidates are tried in the order the descriptor lists them, and the first match wins
    /// without the rest being examined. Rejections are collected rather than thrown one at a time
    /// so that a descriptor no host can satisfy reports every candidate's fate at once — one
    /// candidate's "not declared here" on its own is not a diagnosis, because on a cross-version
    /// descriptor exactly one candidate is *expected* to be absent.
    private static func validate(_ descriptor: MethodHookDescriptor) throws -> ValidatedHook {
        guard let resolvedClass = objc_getClass(descriptor.className) as? AnyClass else {
            throw MethodHookInstallationFailure.classNotFound(className: descriptor.className)
        }

        var rejections: [MethodHookVariantRejection] = []

        for variant in descriptor.variants {
            let selectorName = NSStringFromSelector(variant.selector)

            let method: Method? = descriptor.isInstanceMethod
                ? class_getInstanceMethod(resolvedClass, variant.selector)
                : class_getClassMethod(resolvedClass, variant.selector)

            guard let resolvedMethod = method else {
                rejections.append(.methodNotFound(selectorName: selectorName))
                continue
            }

            guard let liveTypeEncodingCString = method_getTypeEncoding(resolvedMethod) else {
                rejections.append(.typeEncodingMissing(selectorName: selectorName))
                continue
            }

            let liveTypeEncoding = String(cString: liveTypeEncodingCString)
            guard MethodHookInspector.typeEncodingsMatch(variant.expectedTypeEncoding, liveTypeEncoding) else {
                rejections.append(
                    .typeEncodingMismatch(
                        selectorName: selectorName,
                        expectedTypeEncoding: variant.expectedTypeEncoding,
                        hostTypeEncoding: liveTypeEncoding
                    )
                )
                continue
            }

            return ValidatedHook(descriptor: descriptor, variant: variant, method: resolvedMethod)
        }

        throw MethodHookInstallationFailure.noUsableVariant(
            className: descriptor.className,
            rejections: rejections
        )
    }
}

/// Reads live type encodings out of the host process.
///
/// Call this from a scratch payload — or from a Swift snippet inside the target under a debugger —
/// to obtain the exact string to paste into a variant's `expectedTypeEncoding`, instead of
/// hand-deriving encodings from a decompiler's signature.
public enum MethodHookInspector {
    public static func typeEncoding(
        forClassNamed className: String,
        selector: Selector,
        isInstanceMethod: Bool = true
    ) -> String? {
        guard let resolvedClass = objc_getClass(className) as? AnyClass else { return nil }
        let method = isInstanceMethod
            ? class_getInstanceMethod(resolvedClass, selector)
            : class_getClassMethod(resolvedClass, selector)
        guard let resolvedMethod = method, let encoding = method_getTypeEncoding(resolvedMethod) else { return nil }
        return String(cString: encoding)
    }

    /// Whether the host has this method with the signature the caller is about to assume.
    ///
    /// Calling a host method needs the same signature check that hooking one does. Getting the
    /// signature wrong when *calling* is if anything worse: the arguments are marshalled straight
    /// into the host's registers, and the crash lands in someone else's process with nothing
    /// pointing back here. Check first, and skip the call when the host does not match.
    public static func hasMethod(
        className: String,
        selector: Selector,
        matchingTypeEncoding expectedTypeEncoding: String,
        isInstanceMethod: Bool = true
    ) -> Bool {
        guard let liveTypeEncoding = typeEncoding(
            forClassNamed: className,
            selector: selector,
            isInstanceMethod: isInstanceMethod
        ) else { return false }
        return typeEncodingsMatch(expectedTypeEncoding, liveTypeEncoding)
    }

    /// Compares two type encodings ignoring the frame-offset digits the runtime appends.
    ///
    /// Encodings come in two flavours for the same signature: bare (`v@:@`) and offset-annotated
    /// (`v24@0:8@16`). The offsets are derived from the types, so stripping the digits and comparing
    /// what is left compares exactly the part that matters, and lets an expectation written from one
    /// flavour match a host that reports the other.
    public static func typeEncodingsMatch(_ leftEncoding: String, _ rightEncoding: String) -> Bool {
        stripFrameOffsets(from: leftEncoding) == stripFrameOffsets(from: rightEncoding)
    }

    private static func stripFrameOffsets(from encoding: String) -> String {
        String(encoding.filter { !$0.isNumber })
    }
}
