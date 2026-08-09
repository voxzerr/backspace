import AppKit
import BackspaceAI
import BackspaceAX
import BackspaceCore
import Foundation
import UserNotifications

/// The menu bar item, and the wiring between it and the coordinator.
///
/// `@MainActor` on the whole class rather than on individual methods: every
/// member touches AppKit or the `@MainActor` coordinator, so isolating the
/// type is both the honest description and the one that does not need
/// revisiting each time a method is added.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let coordinator = Coordinator()
    private var permissionPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenuBarItem()
        wireCoordinator()

        // Reconcile the saved settings against what this machine can do, and
        // say so if something had to be switched off. Silently disagreeing
        // with a checkbox the user ticked is worse than not offering it.
        var settings = Settings.current
        if let reason = settings.reconcile(with: Accessibility.capabilities()) {
            Settings.current = settings
            notify("As-you-type is off", body: reason)
        }

        if Accessibility.isTrusted {
            coordinator.start()
        } else {
            Accessibility.requestPermission()
            waitForPermission()
        }
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPoll?.invalidate()
        coordinator.stop()
    }

    // MARK: - Menu bar

    private func buildMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⌫"
        item.button?.toolTip = "Backspace"
        item.menu = NSMenu()
        statusItem = item
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let capabilities = Accessibility.capabilities()
        let settings = Settings.current

        if !capabilities.accessibilityTrusted {
            menu.addItem(disabled("Needs Accessibility permission"))
            menu.addItem(
                action("Open System Settings…", #selector(openAccessibilitySettings))
            )
            menu.addItem(.separator())
        }

        menu.addItem(disabled("Mode"))
        for mode in Mode.allCases {
            let item = action(
                "  \(mode.label) — \(mode.explanation)",
                #selector(selectMode(_:))
            )
            item.representedObject = mode.rawValue
            item.state = settings.mode == mode ? .on : .off
            // `clean` and `polish` need a model; leave them visibly present
            // but inert rather than hiding them, so the feature is
            // discoverable and the reason it is off is obvious.
            item.isEnabled = !mode.needsModel || AIConfiguration.hasAPIKey
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let toggle = action("Fix as I type", #selector(toggleAsYouType))
        toggle.state = settings.asYouTypeEnabled ? .on : .off
        toggle.isEnabled = capabilities.asYouType
        menu.addItem(toggle)
        if let why = capabilities.whyNoAsYouType {
            menu.addItem(disabled("  \(why)"))
        }

        menu.addItem(.separator())
        menu.addItem(action("Fix Selection", #selector(fixSelection)))

        let expand = action("Expand Prompt", #selector(expandPrompt))
        expand.isEnabled = AIConfiguration.hasAPIKey
        menu.addItem(expand)
        if !AIConfiguration.hasAPIKey {
            menu.addItem(disabled("  Needs an Anthropic API key"))
        }

        menu.addItem(.separator())
        menu.addItem(action("Capability Report…", #selector(showDoctor)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Backspace", #selector(quit)))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = Mode(rawValue: raw) else { return }
        var settings = Settings.current
        settings.mode = mode
        settings.save()
        Settings.current = settings
        refreshMenu()
    }

    @objc private func toggleAsYouType() {
        var settings = Settings.current
        settings.asYouTypeEnabled.toggle()
        settings.save()
        Settings.current = settings
        if settings.asYouTypeEnabled { coordinator.start() }
        refreshMenu()
    }

    @objc private func fixSelection() {
        coordinator.correctSelection()
    }

    @objc private func expandPrompt() {
        guard let key = AIConfiguration.apiKey else {
            notify("Backspace", body: "Add your Anthropic API key to expand prompts.")
            return
        }
        Task { @MainActor in
            let client = ClaudeClient(configuration: .init(apiKey: key))
            await coordinator.expandPrompt(using: PromptExpander(client: client))
        }
    }

    @objc private func openAccessibilitySettings() {
        Accessibility.openSettingsPane()
    }

    @objc private func showDoctor() {
        let alert = NSAlert()
        alert.messageText = "Backspace capability report"
        alert.informativeText = Accessibility.capabilities().describe()
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Permission

    /// macOS shows its permission prompt at most once per app per install, and
    /// grants it out of band in System Settings — there is no callback. Polling
    /// is the only way to notice, and it is cheap.
    private func waitForPermission() {
        permissionPoll?.invalidate()
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard Accessibility.isTrusted else { return }
            timer.invalidate()
            Task { @MainActor in
                self?.coordinator.start()
                self?.refreshMenu()
                self?.notify("Backspace is ready", body: "Accessibility permission granted.")
            }
        }
    }

    // MARK: - Feedback

    private func wireCoordinator() {
        coordinator.onCorrection = { [weak self] result in
            guard Settings.current.showNotifications, result.changed else { return }
            self?.notify("Backspace", body: result.summary)
        }
        coordinator.onRefusal = { reason in
            // Refusals are frequent and mostly uninteresting (you are typing in
            // a terminal, you selected code). They belong in the log, not in a
            // banner that interrupts the thing the person is doing.
            FileHandle.standardError.write(Data("backspace: skipped — \(reason)\n".utf8))
        }
    }

    private func notify(_ title: String, body: String) {
        // `UNUserNotificationCenter.current()` traps outright when the process
        // has no bundle — which is exactly how the binary runs under
        // `swift run` and in CI. Fall back to stderr rather than crashing the
        // app on a code path whose entire purpose is telling the user things.
        guard Bundle.main.bundleIdentifier != nil else {
            FileHandle.standardError.write(Data("backspace: \(title) — \(body)\n".utf8))
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if Settings.current.playSound { content.sound = .default }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// Where the Anthropic API key lives.
///
/// The Keychain, never a plist. A key in `UserDefaults` is world-readable to
/// anything running as the user, backed up in plaintext, and shows up in
/// diagnostics — all of which is exactly wrong for a credential that can spend
/// the user's money.
enum AIConfiguration {
    private static let service = "com.backspace.anthropic-api-key"
    private static let account = "default"

    static var hasAPIKey: Bool { apiKey != nil }

    static var apiKey: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setAPIKey(_ key: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return true }

        var insert = base
        insert[kSecValueData as String] = Data(key.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}
