import BackspaceAX
import BackspaceCore
import Foundation

/// User settings, persisted to `UserDefaults`.
///
/// Every capability-gated setting is re-checked against what the machine can
/// actually do on load, so a preferences file copied from another Mac — or
/// carried across a revoked permission — cannot switch on a feature this
/// machine has no way to deliver safely.
struct Settings {
    var mode: Mode
    var asYouTypeEnabled: Bool
    var blocklist: [String]
    var allowlist: Set<String>
    var playSound: Bool
    var showNotifications: Bool

    private enum Key {
        static let mode = "mode"
        static let asYouType = "asYouTypeEnabled"
        static let blocklist = "blocklist"
        static let allowlist = "allowlist"
        static let sound = "playSound"
        static let notifications = "showNotifications"
    }

    static var current: Settings = .load()

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        return Settings(
            mode: Mode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .fix,
            // Off by default. A tool that starts rewriting your typing before
            // you have asked it to is a tool people uninstall.
            asYouTypeEnabled: defaults.bool(forKey: Key.asYouType),
            blocklist: defaults.stringArray(forKey: Key.blocklist) ?? AppIdentity.defaultBlocklist,
            allowlist: Set(defaults.stringArray(forKey: Key.allowlist) ?? []),
            playSound: defaults.object(forKey: Key.sound) as? Bool ?? false,
            showNotifications: defaults.object(forKey: Key.notifications) as? Bool ?? true
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(asYouTypeEnabled, forKey: Key.asYouType)
        defaults.set(blocklist, forKey: Key.blocklist)
        defaults.set(Array(allowlist), forKey: Key.allowlist)
        defaults.set(playSound, forKey: Key.sound)
        defaults.set(showNotifications, forKey: Key.notifications)
    }

    /// Force settings back into what this machine can actually honour.
    ///
    /// Returns the reason when something was switched off, so the UI can say
    /// why rather than silently disagreeing with the checkbox the user ticked.
    mutating func reconcile(with capabilities: Accessibility.Capabilities) -> String? {
        guard asYouTypeEnabled, !capabilities.asYouType else { return nil }
        asYouTypeEnabled = false
        save()
        return capabilities.whyNoAsYouType
    }
}
