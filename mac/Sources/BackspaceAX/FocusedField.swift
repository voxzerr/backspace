import AppKit
import ApplicationServices
import BackspaceCore
import Foundation

/// A text field that currently has focus, and everything we know about it.
///
/// This is the replacement for the old copy-the-selection-and-paste-it-back
/// dance. Reading `kAXValueAttribute` gives us the *whole* field, not just
/// what was typed since focus arrived, and writing it back never touches the
/// clipboard, never synthesises a keystroke, and cannot leak into a different
/// window if focus moves mid-operation.
public struct FocusedField {
    public let element: AXElement
    public let app: AppRef
    /// Full contents of the field.
    public let text: String
    /// Insertion point / selection, in UTF-16 units.
    public let selection: NSRange
    /// Is this a password field? `UNKNOWN` if we could not tell.
    public let isSecure: Tri
    /// Can we write to it at all?
    public let isEditable: Bool

    public var caret: Int { selection.location + selection.length }
}

/// Reads the focused text field, or explains why it could not.
public enum FocusReader {

    /// Roles that are text-editing elements. Kept as a fallback signal only —
    /// the primary test is capability, not role, because web and Electron
    /// content reports roles inconsistently.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
    ]

    /// The focused field, if the focused thing is a text field at all.
    ///
    /// Returns nil for "nothing focused" and for "focused on something that
    /// is not editable text" — a button, a list, a canvas. Both are ordinary
    /// and neither is an error.
    public static func current() -> FocusedField? {
        guard Accessibility.isTrusted else { return nil }

        guard let focused = AXElement.systemWide.element(kAXFocusedUIElementAttribute) else {
            return nil
        }
        return read(focused)
    }

    /// Build a `FocusedField` from an element we already have.
    public static func read(_ element: AXElement) -> FocusedField? {
        // Capability, not role. An element that has both a string value and a
        // selected-text range *is* an editable text element, whatever it calls
        // itself — which is how this keeps working inside Electron and web
        // views that report `AXTextArea`, `AXGroup`, or nothing useful at all.
        guard let text = element.string(kAXValueAttribute) else { return nil }
        guard let selection = element.range(kAXSelectedTextRangeAttribute) else { return nil }

        let app = element.pid.map(AppIdentity.app(forPID:)) ?? .unknown
        let editable = element.isSettable(kAXValueAttribute)
            || element.isSettable(kAXSelectedTextAttribute)

        return FocusedField(
            element: element,
            app: app,
            text: text,
            selection: selection,
            isSecure: secureness(of: element),
            isEditable: editable
        )
    }

    /// Is this element a password field?
    ///
    /// This is the precise, per-field check that the Python version could not
    /// make — it only had the global `IsSecureEventInputEnabled`, which is
    /// blind to a password box in a browser. `AXSecureTextField` is the actual
    /// subrole AppKit and WebKit assign to secure inputs.
    ///
    /// Returns `UNKNOWN`, never `NO`, when the element declines to answer.
    /// A field we could not classify is treated as a password field.
    public static func secureness(of element: AXElement) -> Tri {
        if let subrole = element.subrole {
            return Tri(subrole == kAXSecureTextFieldSubrole)
        }

        // A nil subrole is ambiguous: the element may genuinely not have one
        // (normal for a plain text field), or the read may simply have failed
        // — a busy Chrome renderer exceeding the 250ms messaging timeout looks
        // identical from here. Answering NO to the second case would mean
        // treating a password field we could not inspect as definitely not a
        // password field, which is the one mistake this whole design exists to
        // prevent. So ask whether the element *declares* the attribute, which
        // distinguishes them.
        switch element.supports(kAXSubroleAttribute) {
        case .yes:
            // It has a subrole and we could not read it. That is a failed
            // probe, not an absent attribute.
            return .unknown
        case .unknown:
            // We could not even enumerate its attributes.
            return .unknown
        case .no:
            // Genuinely no subrole. Fall back to the role — but only a known
            // text role counts as "not secure"; anything else we do not know.
            guard let role = element.role else { return .unknown }
            return textRoles.contains(role) ? .no : .unknown
        }
    }
}

/// Replaces a span of text inside another application's field.
public enum FieldWriter {

    public enum WriteError: Error, CustomStringConvertible {
        case notEditable
        case rangeOutOfBounds
        case rejected

        public var description: String {
            switch self {
            case .notEditable: return "that field is read-only"
            case .rangeOutOfBounds: return "the text moved while we were working"
            case .rejected: return "the app wouldn't accept the edit"
            }
        }
    }

    /// Replace `range` with `replacement`, leaving the caret where a person
    /// would expect it.
    ///
    /// Prefers the surgical path — select the span, then set the selected text
    /// — because rewriting `kAXValueAttribute` wholesale discards the app's
    /// own undo stack and scroll position. Falls back to the whole-value write
    /// only for fields that refuse the surgical one.
    public static func replace(
        range: NSRange,
        with replacement: String,
        in field: FocusedField
    ) throws {
        let element = field.element
        let current = field.text as NSString

        guard field.isEditable else { throw WriteError.notEditable }
        guard range.location >= 0,
              range.location + range.length <= current.length else {
            throw WriteError.rangeOutOfBounds
        }

        // Re-read immediately before writing. Between the correction being
        // computed and it being applied, the person kept typing — and writing
        // a stale range would land the replacement in the wrong place.
        guard let live = element.string(kAXValueAttribute), live == field.text else {
            throw WriteError.rangeOutOfBounds
        }

        let caretAfter = range.location + (replacement as NSString).length

        if element.isSettable(kAXSelectedTextAttribute) {
            guard element.set(kAXSelectedTextRangeAttribute, range: range) else {
                throw WriteError.rejected
            }
            guard element.set(kAXSelectedTextAttribute, string: replacement) else {
                throw WriteError.rejected
            }
        } else if element.isSettable(kAXValueAttribute) {
            let updated = current.replacingCharacters(in: range, with: replacement)
            guard element.set(kAXValueAttribute, string: updated) else {
                throw WriteError.rejected
            }
        } else {
            throw WriteError.notEditable
        }

        // Put the caret back at the end of what we just wrote. Not fatal if
        // it fails — the text is already correct, and a caret in a slightly
        // wrong place is a much smaller problem than a failed correction.
        element.set(kAXSelectedTextRangeAttribute, range: NSRange(location: caretAfter, length: 0))
    }

    /// Is anything stopping us writing this replacement into this field?
    ///
    /// Asked *before* anything is changed, never after. The hard-won lesson
    /// from the keystroke-based version: check you can insert the replacement
    /// before you delete what was there, or a refusal halfway through leaves
    /// the person's sentence destroyed.
    ///
    /// Phrased as a problem, so `Tri.blocks` reads correctly: `YES` means
    /// "yes, there is a problem — stop".
    public static func insertionBlocked(_ replacement: String, in field: FocusedField) -> Tri {
        guard field.isEditable else { return .yes }
        guard !replacement.isEmpty else { return .yes }
        return .no
    }
}
