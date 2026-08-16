import ApplicationServices
import BackspaceCore
import Foundation

/// A safe, total wrapper over `AXUIElement`.
///
/// The Accessibility API is a C API that communicates with *other processes*.
/// Two consequences shape everything here:
///
/// 1. **Every call can fail, and failure is normal.** The other app may have
///    quit, redrawn, or simply declined to answer. So every accessor returns
///    an optional and nothing throws — a `nil` here means "could not answer",
///    which the caller turns into `Tri.unknown`, which blocks.
///
/// 2. **Every call can block.** A wedged app will hang the caller until the
///    default messaging timeout expires, and the default is long enough to
///    freeze a menu bar app solid. We set our own, short, timeout instead.
public struct AXElement {
    let raw: AXUIElement

    /// How long to wait for another process to answer before giving up.
    ///
    /// Deliberately short. We are on the main thread reacting to keystrokes;
    /// a correction that arrives late is worthless, and a UI that stutters
    /// because Slack is busy is worse than no correction at all.
    public static let messagingTimeout: Float = 0.25

    init(_ raw: AXUIElement) {
        self.raw = raw
        AXUIElementSetMessagingTimeout(raw, Self.messagingTimeout)
    }

    /// The system-wide element: the entry point for "what has focus right now".
    public static var systemWide: AXElement { AXElement(AXUIElementCreateSystemWide()) }

    /// An element representing a running application.
    public static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    // MARK: - Reading

    private func copyValue(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    public func string(_ attribute: String) -> String? {
        copyValue(attribute) as? String
    }

    public func number(_ attribute: String) -> Int? {
        (copyValue(attribute) as? NSNumber)?.intValue
    }

    public func bool(_ attribute: String) -> Bool? {
        (copyValue(attribute) as? NSNumber)?.boolValue
    }

    public func element(_ attribute: String) -> AXElement? {
        guard let value = copyValue(attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    /// A `CFRange`-typed attribute, e.g. `kAXSelectedTextRangeAttribute`.
    ///
    /// The offsets are UTF-16 units, which is why everything downstream of
    /// here stays in `NSRange` rather than converting to Swift string indices.
    public func range(_ attribute: String) -> NSRange? {
        guard let value = copyValue(attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Does this element even claim to support an attribute?
    ///
    /// Cheaper and more honest than reading it and interpreting a failure:
    /// an attribute that is absent is a different thing from one that is
    /// present but temporarily unreadable.
    /// Does this element declare an attribute?
    ///
    /// Three answers, not two, and the third is the whole point. `nil` from a
    /// read means either "the attribute is genuinely absent" or "the other
    /// process did not answer in time", and those must not be conflated — one
    /// is information, the other is the absence of it. Callers use this to
    /// tell a field that *has no* subrole from a field whose subrole we
    /// *could not read*.
    public func supports(_ attribute: String) -> Tri {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(raw, &names) == .success,
              let list = names as? [String] else { return .unknown }
        return Tri(list.contains(attribute))
    }

    /// Is this attribute writable? Asked *before* we try to change anything,
    /// so a read-only field produces a clean refusal rather than a failed edit.
    public func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(raw, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    // MARK: - Writing

    @discardableResult
    public func set(_ attribute: String, to value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(raw, attribute as CFString, value) == .success
    }

    @discardableResult
    public func set(_ attribute: String, string value: String) -> Bool {
        set(attribute, to: value as CFString)
    }

    @discardableResult
    public func set(_ attribute: String, range value: NSRange) -> Bool {
        var cfRange = CFRange(location: value.location, length: value.length)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return set(attribute, to: axValue)
    }

    // MARK: - Geometry

    /// Screen bounds of a character range.
    ///
    /// This is what makes an inline suggestion possible: it is the only way to
    /// learn where, in screen coordinates, a given run of text is being drawn
    /// inside another application's window.
    ///
    /// Returns nil for elements that do not implement the parameterized
    /// attribute, which is most of them outside real text views.
    public func bounds(forRange range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            raw,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter,
            &result
        )
        guard status == .success,
              let value = result,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    // MARK: - Identity

    public var pid: pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(raw, &pid) == .success else { return nil }
        return pid
    }

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
}

extension AXElement: Equatable {
    public static func == (lhs: AXElement, rhs: AXElement) -> Bool {
        CFEqual(lhs.raw, rhs.raw)
    }
}
