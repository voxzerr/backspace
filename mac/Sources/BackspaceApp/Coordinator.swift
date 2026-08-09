import AppKit
import BackspaceAX
import BackspaceCore
import Foundation

/// Ties the Accessibility layer to the correction engine.
///
/// The whole as-you-type path is here: a change arrives, we look for a
/// sentence that just ended, correct it offline, run every safety gate, and
/// only then write it back. Nothing in this file decides *whether* something
/// is safe — that is `Gates`, which is pure and tested. This file's job is to
/// assemble an honest `TypingContext` and to not create feedback loops.
@MainActor
final class Coordinator {

    private let tracker = FocusTracker()
    private let scanner = SentenceScanner()
    private var corrector: Corrector

    /// True while we are writing. Our own edit raises `AXValueChanged`, so
    /// without this the corrector would react to its own output — correct the
    /// correction, react to that, and so on. This is the loop-breaker.
    private var isApplying = false

    /// The last sentence we finished with, so a person who keeps typing past
    /// a corrected sentence does not have it re-evaluated on every keystroke.
    private var lastHandledSentence: String?

    private var lastActivity = Date()
    private var appAtSentenceStart: AppRef = .unknown

    /// Called after each applied correction, for the UI.
    var onCorrection: ((CorrectionResult) -> Void)?
    /// Called when a correction was computed but refused, with the reason.
    var onRefusal: ((String) -> Void)?

    init() {
        corrector = Corrector(
            spell: SystemSpellProvider(),
            allowlist: Settings.current.allowlist
        )
    }

    // MARK: - Lifecycle

    /// Start watching. Returns false without installing anything when the
    /// machine cannot support the feature safely.
    @discardableResult
    func start() -> Bool {
        let capabilities = Accessibility.capabilities()
        guard capabilities.asYouType else { return false }

        tracker.onTextChanged = { [weak self] field in
            self?.textChanged(in: field)
        }
        tracker.onFocusChanged = { [weak self] field in
            self?.focusChanged(to: field)
        }
        return tracker.start()
    }

    func stop() {
        tracker.stop()
        lastHandledSentence = nil
    }

    /// Rebuild the engine after the user edits their allowlist.
    func reloadSettings() {
        corrector = Corrector(
            spell: SystemSpellProvider(),
            allowlist: Settings.current.allowlist
        )
    }

    // MARK: - Events

    private func focusChanged(to field: FocusedField?) {
        appAtSentenceStart = field?.app ?? .unknown
        lastHandledSentence = nil
        lastActivity = Date()
    }

    private func textChanged(in field: FocusedField) {
        guard !isApplying else { return }
        guard Settings.current.asYouTypeEnabled else { return }

        let now = Date()
        let idle = now.timeIntervalSince(lastActivity)
        lastActivity = now

        guard let range = scanner.completedSentence(in: field.text, caret: field.caret) else {
            return
        }
        let sentence = (field.text as NSString).substring(with: range)
        guard sentence != lastHandledSentence else { return }

        let result = corrector.fix(sentence)
        guard result.changed, result.text != sentence else {
            // Nothing to do — but remember it, so we do not re-run the engine
            // over the same finished sentence on every subsequent keystroke.
            lastHandledSentence = sentence
            return
        }

        let context = TypingContext(
            sentence: sentence,
            correction: result.text,
            app: field.app,
            blocklist: Settings.current.blocklist,
            // On macOS with the permission granted, we *can* tell a secure
            // field apart — that is what earns the right to watch at all.
            platformDetectsPasswordFields: Accessibility.isTrusted,
            focusedFieldIsSecure: field.isSecure,
            secureInputActive: Accessibility.secureInputActive,
            insertionBlocked: FieldWriter.insertionBlocked(result.text, in: field),
            idleTime: idle,
            focusMovedSinceSentenceStarted: appAtSentenceStart.known
                && field.app != appAtSentenceStart
        )

        switch Gates.evaluate(context) {
        case .block(let reason):
            lastHandledSentence = sentence
            onRefusal?(reason)
        case .allow:
            apply(result, over: range, in: field, original: sentence)
        }
    }

    private func apply(
        _ result: CorrectionResult,
        over range: NSRange,
        in field: FocusedField,
        original: String
    ) {
        isApplying = true
        defer { isApplying = false }

        do {
            try FieldWriter.replace(range: range, with: result.text, in: field)
            lastHandledSentence = result.text
            onCorrection?(result)
        } catch {
            // A failed write is not a crash and not a silent nothing: the text
            // is untouched, and the reason is worth surfacing because "it
            // stopped working in this one app" is the report we will get.
            lastHandledSentence = original
            onRefusal?(String(describing: error))
        }
    }

    // MARK: - Hotkey path

    /// Correct the current selection, or the whole field if nothing is
    /// selected. This path has no sentence detection and no idle timeout —
    /// the person asked for it explicitly — but every other gate still runs.
    @discardableResult
    func correctSelection() -> CorrectionResult? {
        guard let field = FocusReader.current() else {
            onRefusal?("select some text first")
            return nil
        }

        let target = field.selection.length > 0
            ? field.selection
            : NSRange(location: 0, length: (field.text as NSString).length)
        guard target.length > 0 else {
            onRefusal?("select some text first")
            return nil
        }

        let source = (field.text as NSString).substring(with: target)
        let result = corrector.fix(source)
        guard result.changed else {
            onCorrection?(result)
            return result
        }

        if field.isSecure.blocks {
            onRefusal?("that looks like a password field")
            return nil
        }
        if field.app.matches(Settings.current.blocklist).blocks {
            onRefusal?(
                field.app.known
                    ? "\(field.app.name) is on your blocklist"
                    : "couldn't identify the front app"
            )
            return nil
        }

        isApplying = true
        defer { isApplying = false }
        do {
            try FieldWriter.replace(range: target, with: result.text, in: field)
            onCorrection?(result)
            return result
        } catch {
            onRefusal?(String(describing: error))
            return nil
        }
    }
}
