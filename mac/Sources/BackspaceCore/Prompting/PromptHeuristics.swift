import Foundation

/// Decides whether a prompt is worth offering to expand.
///
/// The bar is deliberately high. A tool that offers to "improve" every
/// sentence you type into a chat box is noise, and worse, it implies your
/// perfectly clear question was inadequate. This only fires when the prompt
/// is genuinely thin: a short ask with no constraints, no success criteria,
/// and no format — the kind that reliably produces a confident answer to a
/// question you did not mean.
public enum PromptHeuristics {

    public struct Verdict: Sendable, Equatable {
        public let worthExpanding: Bool
        /// Why, in words a person would accept. Empty when not offering.
        public let reason: String
        public let shape: PromptShape

        public static let no = Verdict(worthExpanding: false, reason: "", shape: .unknown)
    }

    /// Above this many words, assume the person has said what they mean.
    static let wordCeiling = 30
    /// Below this, it is a fragment rather than a prompt — probably still typing.
    static let wordFloor = 2

    /// Markers that the prompt is already specified. Any one of these and we
    /// stay out of the way.
    private static let specifiedMarkers: [String] = [
        "must ", "should ", "requirement", "constraint", "acceptance",
        "criteria", "format:", "output:", "for example", "e.g.", "step by step",
        "do not ", "don't ", "avoid ", "make sure",
    ]

    public static func evaluate(_ prompt: String) -> Verdict {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .no }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= wordFloor else { return .no }

        // Already long enough to carry its own detail.
        guard words.count <= wordCeiling else { return .no }

        let lower = trimmed.lowercased()

        // Already structured: a list means the person enumerated their asks.
        if trimmed.contains("\n- ") || trimmed.contains("\n* ") || trimmed.contains("\n1. ") {
            return .no
        }
        // Contains code or a quoted block — the specificity is in there.
        if trimmed.contains("```") { return .no }

        for marker in specifiedMarkers where lower.contains(marker) {
            return .no
        }

        let shape = PromptShape.of(trimmed)
        return Verdict(
            worthExpanding: true,
            reason: "That's a \(words.count)-word ask — expanding it pins down \(shape.focus).",
            shape: shape
        )
    }
}
