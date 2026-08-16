import Foundation

/// Finds the sentence a person just finished typing.
///
/// The as-you-type path needs to answer one question on every keystroke:
/// "did that just complete a sentence, and if so, which characters were it?"
/// Getting this wrong in either direction is bad — fire too early and you
/// rewrite a half-written thought under the cursor, fire too late and the
/// correction lands after they have moved on.
///
/// Offsets are UTF-16 throughout, because that is what the Accessibility API
/// speaks (`AXSelectedTextRange` is a `CFRange` over UTF-16 units). Converting
/// to Swift's grapheme indices at the boundary and back again is where emoji
/// and combining marks go wrong, so we simply do not.
public struct SentenceScanner: Sendable {
    /// Characters that end a sentence.
    private static let terminators: Set<Character> = [".", "!", "?"]

    public init() {}

    /// The sentence immediately before `caret`, if one just ended there.
    ///
    /// Returns nil unless the caret sits directly after a terminator, or after
    /// a terminator plus a single trailing space — which is the moment a
    /// person has actually finished the thought rather than paused inside it.
    ///
    /// - Parameters:
    ///   - text: the full contents of the field.
    ///   - caret: the insertion point, as a UTF-16 offset into `text`.
    public func completedSentence(in text: String, caret: Int) -> NSRange? {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return nil }

        // Walk back over at most one trailing space, then require a terminator.
        var end = caret
        if end > 0, ns.character(at: end - 1) == 32 /* space */ {
            end -= 1
        }
        guard end > 0 else { return nil }

        let lastCharacter = Character(UnicodeScalar(ns.character(at: end - 1)) ?? " ")
        guard Self.terminators.contains(lastCharacter) else { return nil }

        // A terminator with a letter or digit hard against it is *inside* a
        // token, not at the end of a sentence: the dot in example.com, in
        // report.pdf, in 3.5. Without this the scanner hands the corrector
        // half a hostname and "check example.com" comes back as
        // "Check example. Com".
        if isInsideToken(in: ns, terminatorAt: end - 1) { return nil }

        // An ellipsis is a pause, not an ending. "Hmm..." is still in progress.
        if end >= 2, ns.character(at: end - 2) == ns.character(at: end - 1) { return nil }

        let start = sentenceStart(in: ns, before: end - 1)
        guard end > start else { return nil }

        // A "sentence" of one or two characters is punctuation, not prose.
        let range = NSRange(location: start, length: end - start)
        // UTF-16 length, not grapheme count: everything else in this file is
        // in UTF-16 units because that is what the Accessibility API speaks,
        // and mixing the two here is how an emoji makes the guard disagree
        // with the range it is guarding.
        let candidate = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (candidate as NSString).length > 2 else { return nil }

        return range
    }

    /// Is the terminator at `position` inside a token rather than ending a
    /// sentence?
    ///
    /// The dot in `example.com`, `report.pdf` and `3.5` all have a letter or
    /// digit hard against them. Without this, typing `check example.com for
    /// details.` hands the corrector the fragment `com for details.` — the
    /// scanner having cut the sentence in the middle of a hostname — and it
    /// comes back as `Com for details.`
    ///
    /// Applied in both directions: to the terminator at the caret, and to
    /// every one passed while scanning backwards for the start.
    private func isInsideToken(in ns: NSString, terminatorAt position: Int) -> Bool {
        let after = position + 1
        guard after < ns.length else { return false }
        let following = UnicodeScalar(ns.character(at: after)) ?? " "
        return CharacterSet.alphanumerics.contains(following)
    }

    /// Scan backwards for the start of the sentence containing `index`.
    ///
    /// Stops at the previous terminator or newline, then skips the whitespace
    /// that follows it so the range starts on the first real character.
    private func sentenceStart(in ns: NSString, before index: Int) -> Int {
        var cursor = index
        while cursor > 0 {
            let scalar = UnicodeScalar(ns.character(at: cursor - 1)) ?? " "
            let character = Character(scalar)
            if character == "\n" { break }
            if Self.terminators.contains(character), !isInsideToken(in: ns, terminatorAt: cursor - 1) {
                break
            }
            cursor -= 1
        }
        // Skip leading whitespace so we do not re-correct the gap.
        while cursor < index {
            let scalar = UnicodeScalar(ns.character(at: cursor)) ?? "x"
            guard CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            cursor += 1
        }
        return cursor
    }
}
