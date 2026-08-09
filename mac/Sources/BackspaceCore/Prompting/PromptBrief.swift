import Foundation

/// A short ask, turned into something that gets a good answer first time.
///
/// Structured rather than free text for three reasons: the model returns it
/// under a JSON schema so it cannot drift into prose, the UI can show the
/// sections separately and let you drop the ones you disagree with, and the
/// rendering can differ per destination — a chat box wants markdown, a code
/// editor's prompt field wants something flatter.
public struct PromptBrief: Sendable, Codable, Equatable {
    /// What is actually being asked for, stated precisely.
    public let objective: String
    /// What the assistant needs to know that the original left implicit.
    public let context: [String]
    /// Constraints a reasonable person would assume, made explicit.
    public let requirements: [String]
    /// How you would know the answer was good.
    public let acceptanceCriteria: [String]
    /// What is deliberately out of scope.
    public let nonGoals: [String]
    /// Genuinely unknowable choices, surfaced rather than invented.
    public let openDecisions: [String]
    /// The shape of answer wanted, when it matters.
    public let outputFormat: String?

    public init(
        objective: String,
        context: [String] = [],
        requirements: [String] = [],
        acceptanceCriteria: [String] = [],
        nonGoals: [String] = [],
        openDecisions: [String] = [],
        outputFormat: String? = nil
    ) {
        self.objective = objective
        self.context = context
        self.requirements = requirements
        self.acceptanceCriteria = acceptanceCriteria
        self.nonGoals = nonGoals
        self.openDecisions = openDecisions
        self.outputFormat = outputFormat
    }

    private enum CodingKeys: String, CodingKey {
        case objective
        case context
        case requirements
        case acceptanceCriteria = "acceptance_criteria"
        case nonGoals = "non_goals"
        case openDecisions = "open_decisions"
        case outputFormat = "output_format"
    }

    /// The JSON Schema the model answers under.
    ///
    /// Every field required and `additionalProperties: false`, so the response
    /// is guaranteed parseable rather than merely usually parseable. Empty
    /// arrays are how the model says "nothing to add here" — which is why
    /// they are required rather than optional.
    public static var jsonSchema: [String: Any] {
        func list(_ description: String) -> [String: Any] {
            ["type": "array", "items": ["type": "string"], "description": description]
        }
        return [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "objective", "context", "requirements", "acceptance_criteria",
                "non_goals", "open_decisions", "output_format",
            ],
            "properties": [
                "objective": [
                    "type": "string",
                    "description": "What is actually being asked for, in one or two precise sentences.",
                ],
                "context": list("Background the assistant needs that the original left implicit."),
                "requirements": list("Constraints and requirements a reasonable person would assume."),
                "acceptance_criteria": list("Concrete, checkable statements of what a good answer does."),
                "non_goals": list("What is deliberately out of scope."),
                "open_decisions": list(
                    "Choices that genuinely cannot be inferred, phrased as questions "
                    + "for the person to answer. Empty if everything was inferable."
                ),
                "output_format": [
                    "type": "string",
                    "description": "The shape of answer wanted. Empty string if it does not matter.",
                ],
            ],
        ]
    }

    /// Render for pasting straight into a chat box.
    ///
    /// Markdown headings, because every AI chat surface renders them and they
    /// survive as readable plain text where one does not.
    public func render() -> String {
        var out = [objective]

        func section(_ title: String, _ items: [String]) {
            let real = items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !real.isEmpty else { return }
            out.append("")
            out.append("**\(title)**")
            out.append(contentsOf: real.map { "- \($0)" })
        }

        section("Context", context)
        section("Requirements", requirements)
        section("Done when", acceptanceCriteria)
        section("Not in scope", nonGoals)

        if let outputFormat, !outputFormat.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append("")
            out.append("**Output**")
            out.append(outputFormat)
        }

        // Open decisions go last and are phrased as questions, so the prompt
        // still works if you send it as-is — the assistant answers them or
        // asks. Inventing a fact here would be the one genuinely harmful
        // thing this feature could do.
        section("Decide before answering", openDecisions)

        return out.joined(separator: "\n")
    }

    /// Roughly how much this expanded the original, for the confirmation UI.
    public func growthFactor(over original: String) -> Double {
        let before = max(original.trimmingCharacters(in: .whitespacesAndNewlines).count, 1)
        return Double(render().count) / Double(before)
    }
}
