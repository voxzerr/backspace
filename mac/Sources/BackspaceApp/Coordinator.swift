import AppKit
import BackspaceAI
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

    // MARK: - Model-backed correction (clean / polish)

    /// Correct the selection offline, then run the model pass the current mode
    /// asks for.
    ///
    /// The model never sees protected content: the text is masked first, and
    /// every marker must come back in the same order or the whole result is
    /// discarded. Offline output is the floor — a rejected or unreachable
    /// model degrades to `fix` rather than failing, which is the same contract
    /// the Python engine had and the reason its `note` field exists.
    func refineSelection(using client: ClaudeClient) async {
        let mode = Settings.current.mode
        guard mode.needsModel else {
            correctSelection()
            return
        }
        guard let field = FocusReader.current() else {
            onRefusal?("select some text first")
            return
        }
        if let refusal = explicitRefusal(for: field) {
            onRefusal?(refusal)
            return
        }

        let target = field.selection.length > 0
            ? field.selection
            : NSRange(location: 0, length: (field.text as NSString).length)
        guard target.length > 0 else {
            onRefusal?("select some text first")
            return
        }

        let source = (field.text as NSString).substring(with: target)
        let offline = corrector.fix(source)

        let masking = Masking()
        let masked = masking.mask(offline.text)
        let system = mode == .clean ? Prompts.clean : Prompts.polish

        var finalText = offline.text
        var usedModel = false
        var note = ""

        do {
            let raw = try await client.complete(
                system: system + "\n\nPreserve any \u{E000}N\u{E001} markers character for character.",
                user: masked.text,
                effort: .low
            )
            switch ModelOutput.vet(
                raw,
                against: masked.text,
                expectedMarkers: masking.markersInOrder(in: masked.text)
            ) {
            case .success(let vetted):
                finalText = masking.unmask(vetted, vault: masked.vault)
                usedModel = true
            case .failure(let rejection):
                note = "offline only — \(rejection.describe)"
            }
        } catch {
            note = "offline only — \(String(describing: error))"
        }

        guard finalText != source else {
            onCorrection?(CorrectionResult(text: source, note: note))
            return
        }
        guard let live = FocusReader.current(), live.text == field.text else {
            onRefusal?("the text changed while refining — nothing was replaced")
            return
        }

        isApplying = true
        defer { isApplying = false }
        do {
            try FieldWriter.replace(range: target, with: finalText, in: live)
            onCorrection?(CorrectionResult(
                text: finalText,
                changes: offline.changes.isEmpty && usedModel
                    ? [Change(before: source, after: finalText, reason: .model)]
                    : offline.changes,
                usedModel: usedModel,
                note: note
            ))
        } catch {
            onRefusal?(String(describing: error))
        }
    }

    // MARK: - Gates for explicitly-invoked actions

    /// The gates that apply to anything the person asks for by menu or hotkey.
    ///
    /// The as-you-type path runs the full `Gates.evaluate` chain. Explicit
    /// actions skip only the gates about typing rhythm — idle time and
    /// mid-sentence focus moves are meaningless when someone just picked a
    /// menu item — but every gate about *where the text is going* still
    /// applies, and so does every gate about where it is going *to*.
    ///
    /// This exists as one function because the alternative already failed:
    /// each explicit path grew its own ad-hoc checks, and `expandPrompt` —
    /// the only path that sends text off the machine — ended up with the
    /// fewest of them.
    private func explicitRefusal(for field: FocusedField) -> String? {
        if field.isSecure.blocks {
            return "that looks like a password field"
        }
        if Accessibility.secureInputActive.blocks {
            return "secure input is active"
        }
        if field.app.matches(Settings.current.blocklist).blocks {
            return field.app.known
                ? "\(field.app.name) is on your blocklist"
                : "couldn't identify the front app"
        }
        return nil
    }

    // MARK: - Prompt expansion

    /// Turn the prompt under the cursor into a brief.
    ///
    /// Unlike the correction paths this one goes over the network, which means
    /// a second or two passes between reading the text and writing it back —
    /// long enough for the person to have kept typing. So the field is re-read
    /// immediately before the write and the whole thing is abandoned if it
    /// moved. Pasting a brief over a sentence someone has since changed is
    /// exactly the kind of surprise this app exists not to cause.
    func expandPrompt(using expander: PromptExpander) async {
        guard let field = FocusReader.current() else {
            onRefusal?("click into a prompt box first")
            return
        }
        // Run every destination gate *before* the network call, not after.
        // This is the only path that sends the field's contents off the
        // machine, so a refusal that arrives after the request has left is
        // not a refusal.
        if let refusal = explicitRefusal(for: field) {
            onRefusal?(refusal)
            return
        }

        let target = field.selection.length > 0
            ? field.selection
            : NSRange(location: 0, length: (field.text as NSString).length)
        let source = (field.text as NSString).substring(with: target)

        let verdict = PromptHeuristics.evaluate(source)
        guard verdict.worthExpanding else {
            onRefusal?(
                source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "nothing to expand"
                    : "that prompt already says what it means"
            )
            return
        }

        // Name the destination so the brief can be written to suit it.
        let surface = AISurface.current(app: field.app, focused: field.element)?.name

        do {
            let brief = try await expander.expand(source, surface: surface)
            let rendered = brief.render()

            guard let live = FocusReader.current(), live.text == field.text else {
                onRefusal?("the text changed while expanding — nothing was replaced")
                return
            }

            isApplying = true
            defer { isApplying = false }
            try FieldWriter.replace(range: target, with: rendered, in: live)
            onCorrection?(CorrectionResult(
                text: rendered,
                changes: [Change(before: source, after: rendered, reason: .model)],
                usedModel: true
            ))
        } catch {
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

        if let refusal = explicitRefusal(for: field) {
            onRefusal?(refusal)
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
