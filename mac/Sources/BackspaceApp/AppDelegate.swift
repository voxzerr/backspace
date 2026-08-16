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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private let coordinator = Coordinator()
    private var permissionPoll: Timer?
    private let settingsWindow = SettingsWindowController()
    private var fixHotkey: GlobalHotkey?
    private var expandHotkey: GlobalHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenuBarItem()
        wireCoordinator()
        registerHotkeys()
        requestNotificationPermission()

        settingsWindow.store.onChange = { [weak self] in
            self?.coordinator.reloadSettings()
            self?.refreshMenu()
        }

        // Reconcile the saved settings against what this machine can do, and
        // say so if something had to be switched off. Silently disagreeing
        // with a checkbox the user ticked is worse than not offering it.
        var settings = Settings.current
        if let reason = settings.reconcile(with: Accessibility.capabilities()) {
            Settings.current = settings
            notify("As-you-type is off", body: reason)
        }

        // Only start watching if the person actually asked for it. Starting
        // regardless would leave a live AXObserver reading the full contents
        // of every focused field on every keystroke — including blocklisted
        // apps — and throwing it away at the settings check. FocusTracker's
        // own contract is that a watcher which installs and then filters is
        // still a watcher.
        if Accessibility.isTrusted {
            if Settings.current.asYouTypeEnabled { coordinator.start() }
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
        let menu = NSMenu()
        // AppKit re-enables any item whose target responds to its action,
        // which is every item we build. Without this, every deliberate
        // `isEnabled = false` below is silently undone at display time and
        // the user can click a feature this machine cannot deliver.
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
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
            // `clean` and `polish` need a model *and* a key. Visibly present
            // but inert rather than hidden, so the feature is discoverable and
            // the reason it is off is obvious — and now genuinely inert,
            // because `autoenablesItems` is off.
            item.isEnabled = !mode.needsModel
                || (AIConfiguration.hasAPIKey && capabilities.canCorrectSelection)
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

        let fix = action("Fix Selection", #selector(fixSelection))
        // Only show the chord if it actually bound — another app may already
        // own it, and a menu advertising a shortcut that does nothing is worse
        // than one that shows none.
        if let bound = fixHotkey { fix.title += "   \(bound.combination.label)" }
        fix.isEnabled = capabilities.canCorrectSelection
        menu.addItem(fix)

        let expand = action("Expand Prompt", #selector(expandPrompt))
        if let bound = expandHotkey { expand.title += "   \(bound.combination.label)" }
        expand.isEnabled = capabilities.canCorrectSelection && AIConfiguration.hasAPIKey
        menu.addItem(expand)
        if !AIConfiguration.hasAPIKey {
            menu.addItem(disabled("  Add an API key in Settings to enable"))
        }

        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings)))
        menu.addItem(action("Capability Report…", #selector(showDoctor)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Backspace", #selector(quit)))
    }

    /// Rebuild every time the menu opens.
    ///
    /// Permissions are granted and revoked in System Settings, and API keys
    /// arrive out of band — none of which sends us a notification. Rebuilding
    /// on open is what stops the menu advertising a capability that was taken
    /// away twenty minutes ago.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
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

        if settings.asYouTypeEnabled {
            // Honour the answer. `start()` returns false without installing
            // anything when the machine cannot support this safely, and a
            // ticked checkbox over a dead feature is worse than an unticked one.
            guard coordinator.start() else {
                notify(
                    "As-you-type is unavailable",
                    body: Accessibility.capabilities().whyNoAsYouType ?? "Not supported here."
                )
                refreshMenu()
                return
            }
        } else {
            coordinator.stop()
        }

        settings.save()
        Settings.current = settings
        refreshMenu()
    }

    @objc private func fixSelection() {
        // `clean` and `polish` route through the model pass; `fix` stays
        // entirely offline and never touches the network.
        guard Settings.current.mode.needsModel, let key = AIConfiguration.apiKey else {
            coordinator.correctSelection()
            return
        }
        Task { @MainActor in
            let client = ClaudeClient(configuration: .init(apiKey: key))
            await coordinator.refineSelection(using: client)
        }
    }

    /// Bind the global chords.
    ///
    /// A chord another app already owns simply fails to register — ordinary,
    /// and not something to crash or nag about. The menu shows the chord only
    /// when it actually bound, so it never advertises a shortcut that does
    /// nothing.
    private func registerHotkeys() {
        fixHotkey = GlobalHotkey(.fixSelection) { [weak self] in
            Task { @MainActor in self?.coordinator.correctSelection() }
        }
        expandHotkey = GlobalHotkey(.expandPrompt) { [weak self] in
            Task { @MainActor in self?.expandPrompt() }
        }
    }

    /// macOS delivers nothing for an app that never asked.
    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @objc private func openSettings() {
        settingsWindow.show()
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
                if Settings.current.asYouTypeEnabled { self?.coordinator.start() }
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
