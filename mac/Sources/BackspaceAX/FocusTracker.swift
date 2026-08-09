import AppKit
import ApplicationServices
import BackspaceCore
import Foundation

/// Watches where focus is and when the focused text changes.
///
/// There is no system-wide text-change notification on macOS; observers are
/// per-process. So this keeps exactly one `AXObserver` alive — for whichever
/// app is frontmost — and re-points it when the user switches apps. That is
/// both the cheapest option and the most private one: we are never subscribed
/// to a background app's text.
///
/// The alternative, walking every app's accessibility tree and subscribing to
/// every text element, is both slow and wrong: elements are created and
/// destroyed constantly, so the subscription set is stale the moment it is
/// built.
public final class FocusTracker {

    /// Called when the text in the focused field changed.
    public var onTextChanged: ((FocusedField) -> Void)?
    /// Called when focus moves. `nil` means focus left editable text entirely.
    public var onFocusChanged: ((FocusedField?) -> Void)?

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observedElement: AXElement?
    private var workspaceToken: NSObjectProtocol?
    private var isRunning = false

    public init() {}

    // MARK: - Lifecycle

    /// Begin watching. Returns false — without installing anything — when the
    /// permission is missing.
    ///
    /// "Returns false without installing anything" is the important half. A
    /// watcher that installs itself and then filters everything out is still a
    /// watcher; refusing to install is the only honest answer when we cannot
    /// tell a password field from a chat box.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        guard Accessibility.isTrusted else { return false }

        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let key = NSWorkspace.applicationUserInfoKey
            let app = notification.userInfo?[key] as? NSRunningApplication
            self?.attach(to: app?.processIdentifier)
        }

        isRunning = true
        attach(to: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        return true
    }

    public func stop() {
        detach()
        if let workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken)
            self.workspaceToken = nil
        }
        isRunning = false
    }

    deinit { stop() }

    // MARK: - Per-application observer

    private func attach(to pid: pid_t?) {
        guard let pid, pid != observedPID else { return }
        detach()

        // Chromium and Electron apps keep their accessibility tree switched
        // off until an assistive client asks for it. Ask before subscribing,
        // or the observer attaches to an empty tree and never fires.
        let app = AppIdentity.app(forPID: pid)
        if AppIdentity.needsAccessibilityWakeUp(app) {
            AppIdentity.enableAccessibilityTree(forPID: pid)
        }

        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success,
              let created else { return }

        observer = created
        observedPID = pid

        let context = Unmanaged.passUnretained(self).toOpaque()
        let application = AXElement.application(pid: pid)
        AXObserverAddNotification(
            created, application.raw,
            kAXFocusedUIElementChangedNotification as CFString, context
        )

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(created),
            .defaultMode
        )

        // Subscribe to whatever already has focus in the app we just switched to.
        focusMoved(to: AXElement.systemWide.element(kAXFocusedUIElementAttribute))
    }

    private func detach() {
        if let observer {
            unsubscribeFromFocusedElement(observer)
            if let pid = observedPID {
                let application = AXElement.application(pid: pid)
                AXObserverRemoveNotification(
                    observer, application.raw,
                    kAXFocusedUIElementChangedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observer = nil
        observedPID = nil
        observedElement = nil
    }

    // MARK: - Per-element observer

    private func focusMoved(to element: AXElement?) {
        guard let observer else { return }
        unsubscribeFromFocusedElement(observer)

        guard let element, let field = FocusReader.read(element) else {
            observedElement = nil
            onFocusChanged?(nil)
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(
            observer, element.raw, kAXValueChangedNotification as CFString, context
        )
        AXObserverAddNotification(
            observer, element.raw, kAXSelectedTextChangedNotification as CFString, context
        )
        observedElement = element
        onFocusChanged?(field)
    }

    private func unsubscribeFromFocusedElement(_ observer: AXObserver) {
        guard let element = observedElement else { return }
        AXObserverRemoveNotification(
            observer, element.raw, kAXValueChangedNotification as CFString
        )
        AXObserverRemoveNotification(
            observer, element.raw, kAXSelectedTextChangedNotification as CFString
        )
    }

    // MARK: - Callback

    /// A C function pointer, so it cannot capture context — `self` is threaded
    /// through the refcon instead. Held unretained: the tracker owns the
    /// observer, so it always outlives any callback it can receive.
    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
        tracker.handle(notification: notification as String, element: AXElement(element))
    }

    private func handle(notification: String, element: AXElement) {
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            focusMoved(to: AXElement.systemWide.element(kAXFocusedUIElementAttribute))
        case kAXValueChangedNotification, kAXSelectedTextChangedNotification:
            guard let field = FocusReader.read(element) else { return }
            onTextChanged?(field)
        default:
            break
        }
    }
}
