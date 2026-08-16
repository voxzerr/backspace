import AppKit
import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey, via Carbon's `RegisterEventHotKey`.
///
/// Carbon rather than a `CGEventTap`, deliberately. A tap needs Input
/// Monitoring — a second, scarier permission prompt — and sees *every*
/// keystroke on the machine including the ones typed into password fields.
/// `RegisterEventHotKey` needs no permission at all and only ever tells us
/// that our own chord fired. For a tool whose entire pitch is "it stays out of
/// where it shouldn't be", asking for less is the point.
///
/// The handler is a C function pointer and cannot capture context, so
/// registrations live in a static table keyed by hotkey id.
public final class GlobalHotkey {

    /// A key combination, in Carbon's terms.
    public struct Combination: Sendable, Equatable {
        public let keyCode: UInt32
        public let modifiers: UInt32
        public let label: String

        public init(keyCode: UInt32, modifiers: UInt32, label: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.label = label
        }

        /// ⌥Space — correct the selection.
        ///
        /// Matches what the Python app used. `Alt+Space` is the window menu on
        /// Windows and Linux, which is why that version documented a different
        /// chord there; on macOS it is free.
        public static let fixSelection = Combination(
            keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "⌥Space"
        )

        /// ⌥⇧Space — expand the prompt under the cursor.
        public static let expandPrompt = Combination(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey | shiftKey),
            label: "⌥⇧Space"
        )
    }

    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4253_5041  // 'BSPA'

    private var reference: EventHotKeyRef?
    private let identifier: UInt32
    public let combination: Combination

    /// Register a chord. Returns nil if the system refused it — almost always
    /// because another app already owns it, which is ordinary and must not be
    /// a crash or a silent no-op.
    public init?(_ combination: Combination, action: @escaping () -> Void) {
        Self.installSharedHandlerIfNeeded()

        self.combination = combination
        identifier = Self.nextID
        Self.nextID += 1

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return nil }

        self.reference = reference
        Self.actions[identifier] = action
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.actions[identifier] = nil
    }

    // MARK: - The shared Carbon handler

    private static func installSharedHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), dispatch, 1, &spec, nil, &eventHandler)
    }

    private static let dispatch: EventHandlerUPP = { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == GlobalHotkey.signature else {
            return OSStatus(eventNotHandledErr)
        }
        guard let action = GlobalHotkey.actions[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }
        action()
        return noErr
    }
}
