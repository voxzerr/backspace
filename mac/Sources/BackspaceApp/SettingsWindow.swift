import AppKit
import BackspaceAX
import BackspaceCore
import SwiftUI

/// Live, observable settings.
///
/// The `Settings` struct stays a plain value type — it is read on the typing
/// hot path and must not carry any UI machinery. This wraps it for SwiftUI and
/// writes through on every change, so the window has no Save button to forget
/// to press.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var mode: Mode { didSet { persist() } }
    @Published var asYouTypeEnabled: Bool { didSet { persist() } }
    @Published var playSound: Bool { didSet { persist() } }
    @Published var showNotifications: Bool { didSet { persist() } }
    @Published var blocklist: [String] { didSet { persist() } }
    @Published var allowlist: [String] { didSet { persist() } }

    /// Held in memory only while the window is open; the Keychain is the store.
    @Published var apiKey: String = ""
    @Published var apiKeySaved: Bool = AIConfiguration.hasAPIKey

    /// Called after any write, so the coordinator can rebuild its engine.
    var onChange: (() -> Void)?

    private var loading = true

    init() {
        let current = Settings.current
        mode = current.mode
        asYouTypeEnabled = current.asYouTypeEnabled
        playSound = current.playSound
        showNotifications = current.showNotifications
        blocklist = current.blocklist.sorted()
        allowlist = current.allowlist.sorted()
        loading = false
    }

    private func persist() {
        guard !loading else { return }
        var settings = Settings.current
        settings.mode = mode
        settings.asYouTypeEnabled = asYouTypeEnabled
        settings.playSound = playSound
        settings.showNotifications = showNotifications
        settings.blocklist = blocklist
        settings.allowlist = Set(allowlist)
        settings.save()
        Settings.current = settings
        onChange?()
    }

    func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apiKeySaved = AIConfiguration.setAPIKey(trimmed)
        // Do not keep it in memory once it is in the Keychain.
        apiKey = ""
        onChange?()
    }

    func removeAPIKey() {
        AIConfiguration.setAPIKey(nil)
        apiKey = ""
        apiKeySaved = false
        onChange?()
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var newBlocked = ""
    @State private var newAllowed = ""

    private var capabilities: Accessibility.Capabilities { Accessibility.capabilities() }

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            intelligence.tabItem { Label("Intelligence", systemImage: "sparkles") }
            lists.tabItem { Label("Lists", systemImage: "list.bullet") }
            about.tabItem { Label("Status", systemImage: "stethoscope") }
        }
        .frame(width: 520, height: 420)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                Picker("Correction level", selection: $store.mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(store.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.mode.needsModel && !store.apiKeySaved {
                    Label("Needs an API key — set one in Intelligence.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Toggle("Fix each sentence as I type", isOn: $store.asYouTypeEnabled)
                    .disabled(!capabilities.asYouType)
                if let why = capabilities.whyNoAsYouType {
                    Text(why).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Off by default. Backspace never touches password fields, "
                         + "and refuses anything that looks like code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show a notification after each fix", isOn: $store.showNotifications)
                Toggle("Play a sound", isOn: $store.playSound)
                    .disabled(!store.showNotifications)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Intelligence

    private var intelligence: some View {
        Form {
            Section("Anthropic API key") {
                if store.apiKeySaved {
                    HStack {
                        Label("A key is stored in your Keychain", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Remove", role: .destructive) { store.removeAPIKey() }
                    }
                } else {
                    SecureField("sk-ant-…", text: $store.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.saveAPIKey() }
                    HStack {
                        Spacer()
                        Button("Save to Keychain") { store.saveAPIKey() }
                            .disabled(store.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Text("Stored in the Keychain, never in a preferences file. "
                     + "Needed for Clean, Polish, and Expand Prompt. "
                     + "Typo correction always runs offline and never needs it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Lists

    private var lists: some View {
        HStack(alignment: .top, spacing: 16) {
            listEditor(
                title: "Never touch these apps",
                caption: "Bundle identifiers. Backspace stays out of these entirely.",
                items: $store.blocklist,
                field: $newBlocked,
                placeholder: "com.example.app"
            )
            listEditor(
                title: "Never correct these words",
                caption: "Product names, jargon, anything the dictionary keeps “fixing”.",
                items: $store.allowlist,
                field: $newAllowed,
                placeholder: "yourproductname"
            )
        }
        .padding()
    }

    private func listEditor(
        title: String,
        caption: String,
        items: Binding<[String]>,
        field: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(caption).font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(items.wrappedValue, id: \.self) { item in
                    HStack {
                        Text(item).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            items.wrappedValue.removeAll { $0 == item }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 200)
            HStack {
                TextField(placeholder, text: field)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(field, to: items) }
                Button("Add") { add(field, to: items) }
                    .disabled(field.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add(_ field: Binding<String>, to items: Binding<[String]>) {
        let value = field.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !items.wrappedValue.contains(value) else { return }
        items.wrappedValue = (items.wrappedValue + [value]).sorted()
        field.wrappedValue = ""
    }

    // MARK: - Status

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What this machine can do")
                .font(.headline)
            ScrollView {
                Text(capabilities.describe())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !capabilities.accessibilityTrusted {
                Button("Open System Settings…") { Accessibility.openSettingsPane() }
            }
        }
        .padding()
    }
}

/// Owns the settings window so it survives being closed and reopened.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    let store = SettingsStore()

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Backspace Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // An accessory app has no menu bar of its own, so it must ask for
        // activation explicitly or the window opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
