import Foundation

/// Everything the app knows at the moment it is about to change your text.
///
/// Assembled by the coordinator from the Accessibility layer; consumed by
/// `Gates` here, which is pure. That split is what makes the safety rules
/// testable without a Mac, a display, or a granted permission — the exact
/// conditions under which they are hardest to test and most important to be
/// right about.
public struct TypingContext: Sendable {
    /// The sentence we intend to replace.
    public let sentence: String
    /// What we intend to replace it with.
    public let correction: String
    /// The app that owns the field, or `.unknown` if we could not tell.
    public let app: AppRef
    /// Bundle IDs the user has excluded.
    public let blocklist: [String]
    /// Can this platform detect password fields *at all*?
    public let platformDetectsPasswordFields: Bool
    /// Is the focused element a secure field? `UNKNOWN` if the probe failed.
    public let focusedFieldIsSecure: Tri
    /// Is system-wide secure input active (login window, `sudo`, and friends)?
    public let secureInputActive: Tri
    /// Is there anything stopping us inserting this replacement?
    ///
    /// Phrased as a problem rather than a permission so that every field in
    /// this struct answers "should we stop?" the same way, and `Tri.blocks`
    /// reads correctly on all of them.
    public let insertionBlocked: Tri
    /// How long since the last keystroke in this field.
    public let idleTime: TimeInterval
    /// Did focus leave the app the sentence was started in?
    public let focusMovedSinceSentenceStarted: Bool

    public init(
        sentence: String,
        correction: String,
        app: AppRef,
        blocklist: [String],
        platformDetectsPasswordFields: Bool,
        focusedFieldIsSecure: Tri,
        secureInputActive: Tri,
        insertionBlocked: Tri,
        idleTime: TimeInterval,
        focusMovedSinceSentenceStarted: Bool
    ) {
        self.sentence = sentence
        self.correction = correction
        self.app = app
        self.blocklist = blocklist
        self.platformDetectsPasswordFields = platformDetectsPasswordFields
        self.focusedFieldIsSecure = focusedFieldIsSecure
        self.secureInputActive = secureInputActive
        self.insertionBlocked = insertionBlocked
        self.idleTime = idleTime
        self.focusMovedSinceSentenceStarted = focusMovedSinceSentenceStarted
    }
}

/// The answer, with a reason we can show a person who asks "why didn't it fix
/// that?" — a silent refusal is indistinguishable from a bug.
public enum GateDecision: Sendable, Equatable {
    case allow
    case block(String)

    public var allowed: Bool {
        if case .allow = self { return true }
        return false
    }

    public var reason: String? {
        if case .block(let reason) = self { return reason }
        return nil
    }
}

/// The safety gates for the as-you-type path.
///
/// Ordered cheapest and most categorical first, so the common refusals cost
/// nothing and the log reads in the order a person would reason.
///
/// Every gate that consults the world asks `Tri.blocks`, never `== .yes`. A
/// probe that failed and a probe that said yes are treated identically. This
/// is the difference between a tool that occasionally declines to help and a
/// tool that one day retypes a password into a chat window.
public enum Gates {
    /// Longest length change a live correction may make.
    ///
    /// A correction that changes the sentence's length dramatically is either
    /// a rewrite or a bug, and neither should happen under the cursor without
    /// being asked for.
    public static let maxLengthDelta = 12

    /// The idle window after which we assume the caret may have moved.
    ///
    /// Focus is tracked at app granularity: a click between two fields of the
    /// *same* app produces no focus event we can see. This timeout is what
    /// guards that gap, and it is why it exists rather than being tuned for
    /// feel.
    public static let maxIdleTime: TimeInterval = 2.5

    /// Characters that mean "this is code, leave it alone".
    private static let codeCharacters = Set("{}()[]<>=|$\\/")

    public static func evaluate(_ context: TypingContext) -> GateDecision {
        // 1. A platform that cannot see password fields does not get to watch
        //    typing at all. Not disabled with a warning — refused. The keyboard
        //    hook is itself the exposure.
        guard context.platformDetectsPasswordFields else {
            return .block("this system can't detect password fields")
        }

        // 2. A password field has focus — or the probe failed and we do not know.
        if context.focusedFieldIsSecure.blocks {
            return .block("the focused field is (or might be) a password field")
        }
        if context.secureInputActive.blocks {
            return .block("secure input is (or might be) active")
        }

        // 3. The front app is excluded — or we could not identify it, which
        //    reads the same. `app.matches` returns UNKNOWN for an app we never
        //    identified precisely so this cannot silently fail open.
        if context.app.matches(context.blocklist).blocks {
            return .block(
                context.app.known
                    ? "\(context.app.name) is on your blocklist"
                    : "couldn't identify the front app"
            )
        }

        // 4. It looks like code.
        if context.sentence.contains(where: { codeCharacters.contains($0) }) {
            return .block("that looks like code")
        }

        // 5. The correction is too big to be a correction.
        let delta = abs(context.correction.count - context.sentence.count)
        if delta > maxLengthDelta {
            return .block("that would change too much (\(delta) characters)")
        }

        // 6. We cannot actually type the replacement. Asked *before* anything
        //    is deleted, never after.
        if context.insertionBlocked.blocks {
            return .block("can't insert that text here")
        }

        // 7. Focus left, or it went quiet long enough that a click could have
        //    moved the caret without us seeing it.
        if context.focusMovedSinceSentenceStarted {
            return .block("focus moved while you were typing")
        }
        if context.idleTime > maxIdleTime {
            return .block("too long since the last keystroke")
        }

        return .allow
    }
}
