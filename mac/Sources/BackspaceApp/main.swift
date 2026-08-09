import AppKit
import BackspaceAX
import BackspaceCore
import Foundation

// Entry point.
//
// Two shapes, chosen by argv:
//
//   backspace --doctor    what can this machine actually do?
//   backspace --fix TEXT  correct text on stdout, touching no platform API
//
// Both exist so the app stays debuggable over SSH, inside CI, and on a machine
// where the Accessibility permission was never granted. They are also the only
// paths a headless CI runner can execute end to end, which is what lets CI
// prove anything at all about this binary.
//
// Anything else: a menu bar app with no dock icon.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print("Backspace 1.0 (macOS)")
    exit(0)
}

if arguments.contains("--doctor") {
    print(Accessibility.capabilities().describe())
    exit(0)
}

if let fixIndex = arguments.firstIndex(of: "--fix") {
    let inline = arguments[(fixIndex + 1)...].joined(separator: " ")
    let input: String
    if inline.isEmpty {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        input = String(data: data, encoding: .utf8) ?? ""
    } else {
        input = inline
    }
    let corrector = Corrector(
        spell: SystemSpellProvider(),
        allowlist: Settings.current.allowlist
    )
    print(corrector.fix(input).text)
    exit(0)
}

/// Bring up the menu bar app.
///
/// Isolated to the main actor because every line of it is: `NSApplication`,
/// the delegate, and the coordinator underneath are all `@MainActor`.
@MainActor
private func launchMenuBarApp() {
    // `NSApplication.delegate` is an unowned reference, so something else has
    // to keep the delegate alive. This stack frame does: `run()` blocks for
    // the lifetime of the process and never returns.
    let delegate = AppDelegate()
    let application = NSApplication.shared
    application.delegate = delegate
    // Accessory: menu bar only, no dock icon. The app must never take focus
    // from whatever the person is typing in — that is the entire premise.
    application.setActivationPolicy(.accessory)
    application.run()
}

// Top-level code already runs on the main thread; this states it in a way the
// compiler can check, rather than relying on where the entry point happens to
// be scheduled.
MainActor.assumeIsolated { launchMenuBarApp() }
