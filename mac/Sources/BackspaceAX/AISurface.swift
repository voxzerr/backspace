import AppKit
import ApplicationServices
import BackspaceCore
import Foundation

/// Is the person typing into an AI, right now?
///
/// Two ways to tell, and both are needed. Native and Electron AI clients are
/// identified by bundle ID. But most AI use happens in a browser tab, where
/// the bundle ID only says "Chrome" — so for browsers we read the focused web
/// area's `AXURL` and match the host.
///
/// Reading the URL is a real privacy decision, so it is scoped tightly: only
/// when the frontmost app is a known browser, only the host is inspected, and
/// the host is never stored or logged. The alternative — matching on window
/// titles — is worse on every axis: unstable, and it carries the page title,
/// which is far more revealing than the domain.
public enum AISurface {

    /// Native and Electron AI clients.
    private static let appPrefixes: [(prefix: String, name: String)] = [
        ("com.openai.chat", "ChatGPT"),
        ("com.anthropic.claudefordesktop", "Claude"),
        ("com.anthropic.claude", "Claude"),
        ("ai.perplexity.mac", "Perplexity"),
        ("com.google.gemini", "Gemini"),
        ("com.todesktop", "Cursor"),          // Cursor and its cohort
        ("com.exafunction.windsurf", "Windsurf"),
        ("dev.zed.zed", "Zed"),
        ("com.github.copilot", "Copilot"),
        ("com.raycast.macos", "Raycast"),
    ]

    /// Hosts that are an AI chat surface.
    private static let hosts: [(suffix: String, name: String)] = [
        ("chatgpt.com", "ChatGPT"),
        ("chat.openai.com", "ChatGPT"),
        ("claude.ai", "Claude"),
        ("gemini.google.com", "Gemini"),
        ("perplexity.ai", "Perplexity"),
        ("copilot.microsoft.com", "Copilot"),
        ("poe.com", "Poe"),
        ("x.com/i/grok", "Grok"),
        ("grok.com", "Grok"),
        ("v0.dev", "v0"),
        ("lovable.dev", "Lovable"),
        ("bolt.new", "Bolt"),
    ]

    private static let browserPrefixes: [String] = [
        "com.apple.safari",
        "com.google.chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.browser",
        "company.thebrowser",   // Arc, Dia
        "ai.perplexity.comet",
    ]

    /// The AI surface in front, if any.
    public struct Detection: Sendable, Equatable {
        /// Product name, for the UI ("ChatGPT", "Claude").
        public let name: String
        /// How we knew. Useful in the capability report; never logged per-use.
        public let viaURL: Bool
    }

    /// Identify from the app alone. Pure, so it is testable without a session.
    public static func fromApp(_ app: AppRef) -> Detection? {
        guard app.known else { return nil }
        for entry in appPrefixes where app.bundleID.hasPrefix(entry.prefix) {
            return Detection(name: entry.name, viaURL: false)
        }
        return nil
    }

    /// Identify from a URL. Pure — the caller supplies the URL.
    public static func fromURL(_ url: String) -> Detection? {
        let lower = url.lowercased()
        for entry in hosts where lower.contains(entry.suffix) {
            return Detection(name: entry.name, viaURL: true)
        }
        return nil
    }

    public static func isBrowser(_ app: AppRef) -> Bool {
        guard app.known else { return false }
        return browserPrefixes.contains { app.bundleID.hasPrefix($0) }
    }

    /// The live check: app first, then the URL only if the app is a browser.
    public static func current(app: AppRef, focused: AXElement?) -> Detection? {
        if let byApp = fromApp(app) { return byApp }
        guard isBrowser(app), let focused else { return nil }
        guard let url = webURL(near: focused) else { return nil }
        return fromURL(url)
    }

    /// Walk up from the focused element to the web area that owns it and read
    /// its `AXURL`.
    ///
    /// Bounded to a handful of hops: the chain from a text box to its web area
    /// is short, and an unbounded walk in another process's tree is how you
    /// hang the main thread on a busy tab.
    private static func webURL(near element: AXElement, maxHops: Int = 6) -> String? {
        var current: AXElement? = element
        var hops = 0
        while let node = current, hops < maxHops {
            if let url = node.string(kAXURLAttribute) { return url }
            current = node.element(kAXParentAttribute)
            hops += 1
        }
        return nil
    }
}
