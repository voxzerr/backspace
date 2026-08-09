import Foundation

/// The offline correction pass.
///
/// Deliberately pure: no network, no clock, no filesystem, no AppKit. Give it
/// a string and a dictionary and it gives you a string back, the same way
/// every time. The model-backed `clean` and `polish` passes compose *around*
/// this rather than living inside it — the Python original did its own HTTP
/// from the engine, which made the "the core is platform-free" claim thinner
/// than it looked.
///
/// The bar for every rule here: it must be a change we can justify to someone
/// who is annoyed we made it. A word that is not in the dictionary, a missing
/// apostrophe in a contraction, a lowercase `i`. Ambiguous calls — `its`/`it's`,
/// `were`/`we're` — are left alone on purpose. That is what `clean` is for.
public struct Corrector: Sendable {
    private let spell: any SpellProvider
    private let protectedWords: Set<String>
    private let masking = Masking()

    /// The largest length change a spelling correction may make.
    ///
    /// A dictionary asked to correct a word it has never seen will happily
    /// suggest something structurally unrelated. Capping the edit distance by
    /// proxy keeps `dropshipping` from becoming `dropping`.
    private static let maxSpellingLengthDelta = 3

    public init(spell: any SpellProvider = NoSpellProvider(), allowlist: Set<String> = []) {
        self.spell = spell
        self.protectedWords = Vocabulary.protectedWords(extra: allowlist)
    }

    // MARK: - Entry point

    /// Correct a span of text. Offline, synchronous, sub-millisecond.
    public func fix(_ text: String) -> CorrectionResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CorrectionResult(text: text, note: "nothing to fix")
        }

        let masked = masking.mask(text)
        var changes: [Change] = []

        var out = spacing(masked.text, changes: &changes)
        out = words(out, changes: &changes)
        out = capitals(out, changes: &changes)

        return CorrectionResult(text: masking.unmask(out, vault: masked.vault), changes: changes)
    }

    // MARK: - Spacing

    private static let collapseSpaces = Pattern(#"[ \t]+"#)
    private static let spaceBeforePunctuation = Pattern(#" +([,.!?;:])"#)
    private static let missingSpaceAfterPunctuation = Pattern(#"([,;:])(?=[^\s\d])"#)
    private static let missingSentenceGap = Pattern(#"(?<=[a-z]{3})([.!?])(?=[A-Za-z])"#)
    private static let longEllipsis = Pattern(#"\.{3,}"#)
    private static let extraBlankLines = Pattern(#"\n{3,}"#)

    /// Whitespace and punctuation spacing.
    ///
    /// Recorded as a single change rather than one per edit: "spacing" is not
    /// a per-token concept a person wants itemised, and an itemised list of
    /// eleven invisible whitespace fixes is noise in the UI.
    private func spacing(_ text: String, changes: inout [Change]) -> String {
        var out = Self.collapseSpaces.replacingMatches(in: text, withTemplate: " ")
        out = Self.spaceBeforePunctuation.replacingMatches(in: out, withTemplate: "$1")
        out = Self.missingSpaceAfterPunctuation.replacingMatches(in: out, withTemplate: "$1 ")
        out = Self.missingSentenceGap.replacingMatches(in: out, withTemplate: "$1 ")
        out = Self.longEllipsis.replacingMatches(in: out, withTemplate: "…")
        out = Self.extraBlankLines.replacingMatches(in: out, withTemplate: "\n\n")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)

        if out != text {
            changes.append(Change(before: text, after: out, reason: .spacing))
        }
        return out
    }

    // MARK: - Words

    private static let wordPattern = Pattern(#"[A-Za-z][A-Za-z']*"#)

    private func words(_ text: String, changes: inout [Change]) -> String {
        Self.wordPattern.replacingMatches(in: text) { groups in
            let word = groups[0] ?? ""
            let (fixed, reason) = correct(word: word)
            if fixed != word {
                changes.append(Change(before: word, after: fixed, reason: reason))
            }
            return fixed
        }
    }

    private func correct(word: String) -> (String, Change.Reason) {
        let low = word.lowercased()

        // A contraction we recognise. A `nil` value means we recognise it and
        // are deliberately declining — `were` could be `we're` or could be the
        // past tense, and only meaning tells them apart.
        if let entry = Vocabulary.contractions[low] {
            guard let expansion = entry else { return (word, .contraction) }
            return (matchCase(of: word, applyingTo: expansion), .contraction)
        }

        guard isCorrectable(word, lowercased: low) else { return (word, .spelling) }
        guard let candidate = spell.correction(for: low), candidate != low else {
            return (word, .spelling)
        }
        guard abs(candidate.count - low.count) <= Self.maxSpellingLengthDelta else {
            return (word, .spelling)
        }
        return (matchCase(of: word, applyingTo: candidate), .spelling)
    }

    /// Is this word one the spell pass is even allowed to look at?
    ///
    /// Every clause is a category of false positive we have already been
    /// bitten by: short words are too easy to "fix" wrongly, apostrophes mean
    /// we already handled it, ALLCAPS is an acronym, an interior capital is
    /// camelCase or a product name, and the allowlist is everything a
    /// dictionary does not know but a person at a computer types daily.
    private func isCorrectable(_ word: String, lowercased low: String) -> Bool {
        guard word.count >= 3 else { return false }
        guard !word.contains("'") else { return false }
        guard word.allSatisfy({ $0.isLetter }) else { return false }
        guard !isAllUppercase(word) else { return false }
        guard !word.dropFirst().contains(where: { $0.isUppercase }) else { return false }
        guard !protectedWords.contains(low) else { return false }
        return spell.isMisspelled(low)
    }

    // MARK: - Capitalisation

    private static let sentenceStart = Pattern(#"(^|[.!?]\s+|\n\s*)([a-z])"#)
    private static let lowercaseWord = Pattern(#"\b[a-z]+\b"#)
    private static let phrasePatterns: [(Pattern, String)] = Vocabulary.properPhrases.map {
        (
            Pattern(
                #"\b"# + NSRegularExpression.escapedPattern(for: $0.pattern) + #"\b"#,
                options: [.caseInsensitive]
            ),
            $0.replacement
        )
    }

    private func capitals(_ text: String, changes: inout [Change]) -> String {
        var out = Self.sentenceStart.replacingMatches(in: text) { groups in
            let lead = groups[1] ?? ""
            let letter = groups[2] ?? ""
            let upper = letter.uppercased()
            if upper != letter {
                changes.append(Change(before: letter, after: upper, reason: .capitalisation))
            }
            return lead + upper
        }

        out = Self.lowercaseWord.replacingMatches(in: out) { groups in
            let word = groups[0] ?? ""
            guard let proper = Vocabulary.proper[word], proper != word else { return word }
            changes.append(Change(before: word, after: proper, reason: .capitalisation))
            return proper
        }

        for (pattern, replacement) in Self.phrasePatterns {
            out = pattern.replacingMatches(in: out) { groups in
                let found = groups[0] ?? ""
                guard found != replacement else { return found }
                changes.append(Change(before: found, after: replacement, reason: .capitalisation))
                return replacement
            }
        }

        return out
    }

    // MARK: - Casing helpers

    /// Carry the original's casing onto the replacement.
    ///
    /// `TEH` → `THE`, `Teh` → `The`, `teh` → `the`.
    private func matchCase(of original: String, applyingTo replacement: String) -> String {
        if isAllUppercase(original), original.count > 1 {
            return replacement.uppercased()
        }
        if original.first?.isUppercase == true {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    /// Python's `str.isupper`: every cased character is uppercase, and there
    /// is at least one. `"123"` is not uppercase; `"ABC"` is.
    private func isAllUppercase(_ string: String) -> Bool {
        var sawLetter = false
        for character in string where character.isLetter {
            sawLetter = true
            if !character.isUppercase { return false }
        }
        return sawLetter
    }
}
