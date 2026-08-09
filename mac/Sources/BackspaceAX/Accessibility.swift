import AppKit
import ApplicationServices
import BackspaceCore
import Carbon
import Foundation

/// Permission, capability, and the honest report of both.
///
/// Two things about the macOS Accessibility grant cost people an afternoon,
/// and both are handled here rather than discovered later:
///
/// - The grant belongs to the **binary that asks**, not to the source file.
///   Upgrading or relocating the app loses it silently.
/// - **Denial is invisible at the call site.** `AXUIElementSetAttributeValue`
///   returns a plausible-looking error and the observer simply never fires.
///   So we probe up front and report a clean `false`, rather than shipping a
///   feature that appears to work and never does.
public enum Accessibility {

    /// Is the Accessibility permission granted right now?
    ///
    /// Cheap enough to call on every correction, and worth doing: the user can
    /// revoke it in System Settings while the app is running, and the first
    /// symptom otherwise is corrections silently stopping.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Ask for the permission, showing the system prompt.
    ///
    /// The prompt appears at most once per app per install; after that macOS
    /// silently returns the current state, which is why the settings UI has to
    /// offer a direct link to the Settings pane as well.
    @discardableResult
    public static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Open System Settings on the pane the user needs.
    public static func openSettingsPane() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Is system-wide secure input active?
    ///
    /// `IsSecureEventInputEnabled` is **global, not per-field**. It catches the
    /// login window, `sudo` in Terminal, and native password fields. It does
    /// *not* catch a password box in a browser, which is most password boxes.
    ///
    /// That is exactly why this is one signal of three: the per-element
    /// `AXSecureTextField` check is the precise one, this is the backstop, and
    /// the app blocklist covers what neither can see.
    public static var secureInputActive: Tri {
        Tri(IsSecureEventInputEnabled())
    }

    /// What this machine can actually do, right now.
    public static func capabilities() -> Capabilities {
        let trusted = isTrusted
        var notes: [String] = []

        if !trusted {
            notes.append(
                "Accessibility permission not granted, so Backspace can't read or "
                + "correct text in other apps. Grant it in System Settings → "
                + "Privacy & Security → Accessibility, then restart Backspace."
            )
        }

        return Capabilities(
            accessibilityTrusted: trusted,
            canReadFocusedText: trusted,
            canWriteFocusedText: trusted,
            canDetectSecureFields: trusted,
            canIdentifyFrontmostApp: true,
            canObserveChanges: trusted,
            notes: notes
        )
    }

    /// A frank account of what works on this machine.
    ///
    /// Mirrors the Python `--doctor` report, and exists for the same reason:
    /// when something does not work later, this is the same data the app used
    /// to decide what to offer, so the answer is never a guess.
    public struct Capabilities: Sendable {
        public let accessibilityTrusted: Bool
        public let canReadFocusedText: Bool
        public let canWriteFocusedText: Bool
        public let canDetectSecureFields: Bool
        public let canIdentifyFrontmostApp: Bool
        public let canObserveChanges: Bool
        public let notes: [String]

        /// Can we correct a selection on a hotkey?
        public var hotkeyPath: Bool { canReadFocusedText && canWriteFocusedText }

        /// Can we correct sentences as they are typed?
        ///
        /// Requires the secure-field probe specifically. Without it every
        /// correction would be running blind past a password box, and the
        /// feature is refused rather than degraded.
        public var asYouType: Bool { hotkeyPath && canObserveChanges && canDetectSecureFields }

        public var whyNoAsYouType: String? {
            guard !asYouType else { return nil }
            if !accessibilityTrusted {
                return "Backspace needs Accessibility permission to watch what you type."
            }
            if !canDetectSecureFields {
                return "Backspace can't tell password fields apart on this system, "
                    + "so it won't watch your typing."
            }
            return "As-you-type isn't available on this system."
        }

        public func describe() -> String {
            var lines = ["Backspace — macOS Accessibility", ""]
            let rows: [(String, Bool)] = [
                ("accessibility permission", accessibilityTrusted),
                ("read focused text", canReadFocusedText),
                ("write focused text", canWriteFocusedText),
                ("detect password fields", canDetectSecureFields),
                ("identify frontmost app", canIdentifyFrontmostApp),
                ("observe text changes", canObserveChanges),
            ]
            for (label, value) in rows {
                lines.append("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0))\(value ? "yes" : "no")")
            }
            lines.append("")
            lines.append("  hotkey correction         \(hotkeyPath ? "available" : "unavailable")")
            lines.append("  as-you-type               \(asYouType ? "available" : "unavailable")")
            if let why = whyNoAsYouType { lines.append("      \(why)") }
            if !notes.isEmpty {
                lines.append("")
                lines.append("  notes:")
                for note in notes { lines.append("    - \(note)") }
            }
            return lines.joined(separator: "\n")
        }
    }
}
