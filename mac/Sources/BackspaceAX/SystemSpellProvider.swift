import AppKit
import BackspaceCore
import Foundation

/// The macOS system dictionary, behind the engine's `SpellProvider` seam.
///
/// `NSSpellChecker.correction(forWordRange:...)` is deliberately chosen over
/// `guesses(forWordRange:...)`. `guesses` returns a ranked list and will
/// happily offer something for a word it has no real opinion about; the
/// `correction` API is the one macOS's own autocorrect uses, and it returns
/// nil unless the system would actually make the substitution itself. That
/// makes it the right confidence bar for a tool that edits text under the
/// cursor — the engine's own guards then layer on top.
///
/// The type has no stored state, so `Sendable` is trivially satisfied; the
/// shared checker underneath is touched only from the main actor in practice.
public struct SystemSpellProvider: SpellProvider {
    public init() {}

    public func isMisspelled(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let found = checker.checkSpelling(of: word, startingAt: 0)
        return found.location != NSNotFound
    }

    public func correction(for word: String) -> String? {
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        let suggestion = checker.correction(
            forWordRange: range,
            in: word,
            language: checker.language(),
            inSpellDocumentWithTag: 0
        )
        // A "correction" identical to the input is not a correction.
        guard let suggestion, suggestion.lowercased() != word.lowercased() else { return nil }
        // Multi-word expansions are a different feature ("teh cat" → "the cat"
        // is fine, but a one-word input turning into a phrase is autocomplete,
        // not spelling).
        guard !suggestion.contains(" ") else { return nil }
        return suggestion
    }
}
