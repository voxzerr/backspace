import Foundation

/// What kind of thing a prompt is asking for.
///
/// The expansion differs by shape: a build request needs requirements and
/// acceptance criteria, an explain request needs an audience and a depth, a
/// fix request needs the symptom and what "working" looks like. Getting the
/// shape right is most of what makes the expanded brief useful rather than
/// generic.
public enum PromptShape: String, Sendable, CaseIterable {
    case build      // "build a car", "make me a landing page"
    case write      // "write a cold email", "draft a post"
    case explain    // "explain kubernetes", "how does TLS work"
    case fix        // "fix this bug", "why is this slow"
    case analyse    // "review this", "compare these options"
    case decide     // "should I use Postgres or Mongo"
    case unknown

    /// Verbs that reliably signal each shape, as whole words at the start of
    /// the prompt or right after a pronoun like "I want you to".
    private static let markers: [(PromptShape, [String])] = [
        (.build, ["build", "make", "create", "generate", "implement", "add",
                  "set up", "setup", "design", "code", "develop", "scaffold"]),
        (.write, ["write", "draft", "compose", "rewrite", "summarise",
                  "summarize", "translate", "reply", "respond"]),
        (.explain, ["explain", "describe", "teach", "what is", "what are",
                    "how does", "how do", "why does", "why is", "tell me about"]),
        (.fix, ["fix", "debug", "troubleshoot", "repair", "resolve",
                "why isn't", "why doesn't", "not working", "broken"]),
        (.analyse, ["review", "analyse", "analyze", "audit", "critique",
                    "evaluate", "assess", "compare", "check"]),
        (.decide, ["should i", "should we", "which is better", "or should",
                   "recommend", "pick", "choose"]),
    ]

    /// Classify a prompt by its leading verb.
    ///
    /// Deliberately shallow. A model could classify this more accurately, but
    /// that would mean an API round trip before we know whether we even want
    /// to offer to expand — and the cost of guessing wrong here is only a
    /// slightly less tailored brief.
    public static func of(_ prompt: String) -> PromptShape {
        let text = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unknown }

        // Longest marker first, so "how does" beats a bare "how".
        let candidates = markers
            .flatMap { shape, words in words.map { (shape, $0) } }
            .sorted { $0.1.count > $1.1.count }

        for (shape, marker) in candidates where text.hasPrefix(marker) {
            // Require a word boundary: "buildings" is not "build".
            let next = text.dropFirst(marker.count).first
            if next == nil || next == " " || next == "'" { return shape }
        }
        for (shape, marker) in candidates where text.contains(" \(marker) ") {
            return shape
        }
        return .unknown
    }

    /// What an expanded brief for this shape most needs to pin down.
    public var focus: String {
        switch self {
        case .build:
            return "requirements, constraints, and what a finished version does"
        case .write:
            return "audience, voice, length, and what the reader should do next"
        case .explain:
            return "who is asking, what they already know, and how deep to go"
        case .fix:
            return "the symptom, what was expected, and what counts as fixed"
        case .analyse:
            return "what to judge against, and what a useful finding looks like"
        case .decide:
            return "the options, the criteria that actually matter, and the constraints"
        case .unknown:
            return "what is actually being asked for, and what done looks like"
        }
    }
}
