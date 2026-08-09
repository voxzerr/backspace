import Foundation

/// A dictionary the corrector can ask about a word.
///
/// This is a protocol rather than a concrete type for one reason: the real
/// implementation is `NSSpellChecker`, which needs AppKit, and the whole point
/// of this module is that it needs nothing. Injecting the dictionary keeps the
/// engine exhaustively testable with a fixed word list — the tests then assert
/// the *rules*, not Apple's dictionary, which is what we actually wrote.
///
/// **Providers own their own confidence bar.** `correction(for:)` returns nil
/// whenever the provider would be guessing. The engine layers its own guards
/// on top (length delta, allowlist, casing) but it cannot second-guess a
/// dictionary's ranking, so a provider that returns low-confidence suggestions
/// will produce a tool that corrects things it shouldn't.
public protocol SpellProvider: Sendable {
    /// Is this word absent from the dictionary? Always asked with a
    /// lowercased word.
    func isMisspelled(_ word: String) -> Bool

    /// The one correction worth making, or nil to leave the word alone.
    func correction(for word: String) -> String?
}

/// The honest no-op: knows nothing, so corrects nothing.
///
/// Used when spellchecking is unavailable or switched off. The app still runs;
/// contractions, capitals and spacing all keep working. It degrades rather
/// than failing, and it never pretends a word is fine when it simply has no
/// opinion.
public struct NoSpellProvider: SpellProvider {
    public init() {}
    public func isMisspelled(_ word: String) -> Bool { false }
    public func correction(for word: String) -> String? { nil }
}

/// A fixed dictionary, for tests and for deterministic behaviour in CI.
public struct DictionarySpellProvider: SpellProvider {
    private let known: Set<String>
    private let corrections: [String: String]

    /// - Parameters:
    ///   - known: words considered correctly spelled.
    ///   - corrections: misspelling → correction. Keys are implicitly unknown.
    public init(known: Set<String> = [], corrections: [String: String] = [:]) {
        self.known = Set(known.map { $0.lowercased() })
        self.corrections = corrections.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }

    public func isMisspelled(_ word: String) -> Bool {
        let low = word.lowercased()
        if known.contains(low) { return false }
        return corrections[low] != nil
    }

    public func correction(for word: String) -> String? {
        corrections[word.lowercased()]
    }
}
