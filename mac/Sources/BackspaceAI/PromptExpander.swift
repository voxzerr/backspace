import BackspaceCore
import Foundation

/// Turns a short ask into a brief that gets a good answer first time.
///
/// "Build a car" is not a bad prompt because it is short. It is a bad prompt
/// because every interesting decision — who it is for, what it must do, what
/// counts as finished — is left for the assistant to guess, and it will guess
/// confidently and wrongly. This makes those decisions visible: inferring the
/// ones a reasonable person would assume, and surfacing the rest as questions
/// rather than inventing answers to them.
public struct PromptExpander: Sendable {
    private let client: ClaudeClient

    public init(client: ClaudeClient) {
        self.client = client
    }

    /// The one rule that matters: rewrite the request, never answer it.
    ///
    /// Everything else is tuning. A model handed "Build a car" will reach for
    /// the deliverable unless told plainly and repeatedly not to, and an
    /// expander that answers the prompt instead of sharpening it is worse than
    /// no expander — it dumps an unwanted essay into your chat box.
    static func system(for shape: PromptShape, surface: String?) -> String {
        var prompt = """
            You turn a short, underspecified request into a brief that gets a \
            good answer on the first try.

            You are rewriting the request. You are never answering it. If the \
            request is "build a car", you produce the brief for building a car \
            — you do not describe how to build a car, and you do not build one.

            This request is a \(shape.rawValue) request, so the brief most \
            needs to pin down \(shape.focus).

            How to fill it in:
            - Keep the person's intent exactly. Never widen the scope beyond \
            what they asked for, and never narrow it to whatever is easiest.
            - Infer what a competent colleague would assume without being told, \
            and write those assumptions down as requirements so they can be \
            corrected.
            - Where a choice genuinely cannot be inferred and would change the \
            answer, put it in open_decisions as a direct question. Never invent \
            a fact — a made-up constraint is the one thing here that does real \
            damage, because it reads as though the person said it.
            - Prefer specifics to adjectives. "Loads in under 200ms on a cold \
            cache" beats "fast".
            - Acceptance criteria must be checkable by looking at the result.
            - Leave a list empty rather than padding it. A brief with three \
            real requirements beats one with three real and four invented.
            """

        if let surface, !surface.isEmpty {
            prompt += """


                This will be sent to \(surface). Write it to suit that surface \
                without mentioning it.
                """
        }
        return prompt
    }

    /// Expand a prompt into a brief.
    public func expand(_ prompt: String, surface: String? = nil) async throws -> PromptBrief {
        let shape = PromptShape.of(prompt)
        let data = try await client.structured(
            system: Self.system(for: shape, surface: surface),
            user: prompt,
            schema: PromptBrief.jsonSchema,
            // Medium, not low: the whole value is in the judgement about what
            // a reasonable person would assume, which is exactly what effort
            // buys. It also runs while the person waits, so not higher.
            effort: .medium
        )

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(PromptBrief.self, from: data)
        } catch {
            // The schema makes this near-impossible, but "near" is doing work
            // in a path that writes into someone's text field. Fail loudly
            // rather than pasting a decode error.
            throw ClaudeClient.ClientError.malformedResponse
        }
    }
}
