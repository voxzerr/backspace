import XCTest
@testable import BackspaceCore

final class PromptShapeTests: XCTestCase {
    func testClassifiesByLeadingVerb() {
        XCTAssertEqual(PromptShape.of("Build a car"), .build)
        XCTAssertEqual(PromptShape.of("write a cold email to a founder"), .write)
        XCTAssertEqual(PromptShape.of("explain kubernetes"), .explain)
        XCTAssertEqual(PromptShape.of("fix this bug"), .fix)
        XCTAssertEqual(PromptShape.of("review my landing page"), .analyse)
        XCTAssertEqual(PromptShape.of("should I use Postgres or Mongo"), .decide)
    }

    func testMultiWordMarkersBeatSingleWordOnes() {
        // "how does" must win over any shorter prefix match.
        XCTAssertEqual(PromptShape.of("how does TLS work"), .explain)
        XCTAssertEqual(PromptShape.of("what is a monad"), .explain)
    }

    func testRequiresAWordBoundary() {
        // "buildings" is not "build".
        XCTAssertNotEqual(PromptShape.of("buildings in Tokyo"), .build)
    }

    func testFindsTheVerbMidSentence() {
        XCTAssertEqual(PromptShape.of("I want you to build a landing page"), .build)
    }

    func testUnknownRatherThanGuessing() {
        XCTAssertEqual(PromptShape.of("the quarterly numbers"), .unknown)
        XCTAssertEqual(PromptShape.of(""), .unknown)
    }

    func testEveryShapeHasAFocus() {
        for shape in PromptShape.allCases {
            XCTAssertFalse(shape.focus.isEmpty)
        }
    }
}

final class PromptHeuristicsTests: XCTestCase {
    private func offers(_ prompt: String) -> Bool {
        PromptHeuristics.evaluate(prompt).worthExpanding
    }

    func testOffersOnAShortVagueAsk() {
        XCTAssertTrue(offers("Build a car"))
        XCTAssertTrue(offers("write me a landing page"))
        XCTAssertTrue(offers("explain how OAuth works"))
    }

    func testStaysOutOfTheWayWhenAlreadySpecified() {
        // Any one of these markers means the person said what they meant.
        XCTAssertFalse(offers("Build a car. It must seat four and cost under 20k."))
        XCTAssertFalse(offers("Write a post. Requirements: 300 words, no jargon."))
        XCTAssertFalse(offers("Explain OAuth, but do not use analogies"))
        XCTAssertFalse(offers("Summarise this. Output: three bullets."))
    }

    func testStaysOutOfTheWayOnLongPrompts() {
        // Past the ceiling, assume the person has carried their own detail.
        let long = Array(repeating: "detail", count: PromptHeuristics.wordCeiling + 5)
            .joined(separator: " ")
        XCTAssertFalse(offers("Build a car " + long))
    }

    func testStaysOutOfTheWayWhenTheAskIsEnumerated() {
        XCTAssertFalse(offers("Build a car\n- four seats\n- electric"))
        XCTAssertFalse(offers("Fix this\n1. it crashes\n2. on launch"))
    }

    func testStaysOutOfTheWayAroundCode() {
        XCTAssertFalse(offers("why does this fail ```let x = 1```"))
    }

    func testDoesNotFireOnAFragmentStillBeingTyped() {
        XCTAssertFalse(offers("Build"))
        XCTAssertFalse(offers(""))
        XCTAssertFalse(offers("   "))
    }

    func testTheReasonIsSomethingAPersonWouldAccept() {
        let verdict = PromptHeuristics.evaluate("Build a car")
        XCTAssertTrue(verdict.worthExpanding)
        XCTAssertTrue(verdict.reason.contains("3-word"))
        XCTAssertEqual(verdict.shape, .build)
        // A refusal carries no reason, so the UI has nothing to show.
        XCTAssertEqual(PromptHeuristics.evaluate("Build"), .no)
    }
}

final class PromptBriefTests: XCTestCase {
    private let brief = PromptBrief(
        objective: "Design a four-seat electric city car for European urban commuting.",
        context: ["Target buyer is a two-car household replacing a second car."],
        requirements: ["Range at least 250km WLTP", "Fits a standard 2.4m garage"],
        acceptanceCriteria: ["A spec sheet a supplier could quote against"],
        nonGoals: ["Autonomous driving"],
        openDecisions: ["What is the target unit cost?"],
        outputFormat: "A one-page spec table."
    )

    func testRenderLeadsWithTheObjective() {
        XCTAssertTrue(brief.render().hasPrefix("Design a four-seat electric"))
    }

    func testRenderIncludesEverySectionThatHasContent() {
        let text = brief.render()
        for heading in ["Context", "Requirements", "Done when", "Not in scope", "Output"] {
            XCTAssertTrue(text.contains("**\(heading)**"), "missing \(heading)")
        }
    }

    func testOpenDecisionsComeLast() {
        // They are questions, so the brief still works if sent as-is — but
        // they must not be the first thing the reader hits.
        let text = brief.render()
        let decisions = text.range(of: "Decide before answering")
        let requirements = text.range(of: "Requirements")
        XCTAssertNotNil(decisions)
        XCTAssertNotNil(requirements)
        if let decisions, let requirements {
            XCTAssertTrue(decisions.lowerBound > requirements.lowerBound)
        }
    }

    func testEmptySectionsAreOmittedRatherThanLeftAsEmptyHeadings() {
        let sparse = PromptBrief(objective: "Just the objective.")
        XCTAssertEqual(sparse.render(), "Just the objective.")
    }

    func testBlankOutputFormatIsNotRendered() {
        // The schema requires the field, so the model says "nothing to add"
        // with an empty string rather than by omitting it.
        let blank = PromptBrief(objective: "X", outputFormat: "")
        XCTAssertFalse(blank.render().contains("**Output**"))
    }

    func testWhitespaceOnlyItemsAreDropped() {
        let padded = PromptBrief(objective: "X", requirements: ["  ", "real one"])
        let text = padded.render()
        XCTAssertTrue(text.contains("- real one"))
        XCTAssertFalse(text.contains("-   \n"))
    }

    func testDecodesTheSchemaShape() throws {
        // Exactly the wire shape the JSON schema pins, snake_case included.
        let json = """
        {
          "objective": "Do the thing.",
          "context": ["some context"],
          "requirements": ["a requirement"],
          "acceptance_criteria": ["checkable"],
          "non_goals": ["not this"],
          "open_decisions": ["what budget?"],
          "output_format": "prose"
        }
        """
        let decoded = try JSONDecoder().decode(PromptBrief.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.objective, "Do the thing.")
        XCTAssertEqual(decoded.acceptanceCriteria, ["checkable"])
        XCTAssertEqual(decoded.nonGoals, ["not this"])
        XCTAssertEqual(decoded.openDecisions, ["what budget?"])
        XCTAssertEqual(decoded.outputFormat, "prose")
    }

    func testSchemaIsStrictEnoughToGuaranteeParsing() {
        let schema = PromptBrief.jsonSchema
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let required = Set(schema["required"] as? [String] ?? [])
        let properties = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
        // Every property required: an absent field would decode to nil and
        // silently drop a section.
        XCTAssertEqual(required, properties)
    }

    func testGrowthFactorReportsRealExpansion() {
        XCTAssertGreaterThan(brief.growthFactor(over: "Build a car"), 5)
        XCTAssertGreaterThan(PromptBrief(objective: "X").growthFactor(over: ""), 0)
    }
}
