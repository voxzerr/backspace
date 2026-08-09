import AppKit
import ApplicationServices
import BackspaceCore
import Foundation

/// Who owns the window you are typing into.
///
/// Apps are identified by **bundle identifier**, never by window title. The
/// title is unstable for matching and carries document names and URLs there is
/// no reason for a typing tool to hold onto, let alone persist.
public enum AppIdentity {

    /// The frontmost application, or `.unknown` if we could not tell.
    public static var frontmost: AppRef {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        return ref(for: app)
    }

    public static func app(forPID pid: pid_t) -> AppRef {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return .unknown }
        return ref(for: app)
    }

    private static func ref(for app: NSRunningApplication) -> AppRef {
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else {
            // A process with no bundle identifier — a raw binary, a helper —
            // is precisely the case where guessing is dangerous. Unknown it is.
            return .unknown
        }
        return AppRef(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }

    /// Apps excluded by default, before the user changes anything.
    ///
    /// Everything on this list is somewhere a mis-fired correction would be
    /// expensive: a password manager, a terminal where text is commands, a
    /// VM or remote session where our idea of "the focused field" is wrong by
    /// construction.
    public static let defaultBlocklist: [String] = [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword",
        "com.1password.1password",
        "com.apple.keychainaccess",
        "com.lastpass.lastpassmacdesktop",
        "com.bitwarden.desktop",
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "co.zeit.hyper",
        "com.vmware.fusion",
        "com.parallels.desktop.console",
        "com.microsoft.rdc.macos",
        "com.teamviewer.teamviewer",
    ]

    /// Wake up the accessibility tree inside a Chromium or Electron app.
    ///
    /// Chromium-based apps do not expose their accessibility tree by default,
    /// for performance — which is exactly why most Mac writing tools work
    /// beautifully in TextEdit and not at all in Slack, Notion, or VS Code.
    /// Setting `AXManualAccessibility` on the *application* element turns it
    /// on for assistive clients.
    ///
    /// Note we deliberately do **not** set `AXEnhancedUserInterface`, which is
    /// the older attribute for the same idea. It is reserved by VoiceOver and
    /// has window-resizing side effects in AppKit apps — Electron added the
    /// `AXManualAccessibility` attribute specifically to avoid them.
    ///
    /// Best effort. An app that ignores it is simply an app we cannot help.
    @discardableResult
    public static func enableAccessibilityTree(forPID pid: pid_t) -> Bool {
        AXElement.application(pid: pid).set("AXManualAccessibility", to: kCFBooleanTrue)
    }

    /// Bundle-ID prefixes for runtimes that need the wake-up call above.
    private static let chromiumFamily: [String] = [
        "com.google.chrome",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "company.thebrowser.browser",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.vscode",
        "com.todesktop",          // Cursor and friends
        "notion.id",
        "com.hnc.discord",
        "com.figma.desktop",
        "com.spotify.client",
        "com.postmanlabs.mac",
        "com.linear",
    ]

    public static func needsAccessibilityWakeUp(_ app: AppRef) -> Bool {
        guard app.known else { return false }
        return chromiumFamily.contains { app.bundleID.hasPrefix($0) }
    }
}
