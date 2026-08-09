import XCTest
@testable import BackspaceCore

/// The correction engine, tested against the same cases the Python original
/// was tested against.
///
/// The dictionary is a fixed word list rather than the system spellchecker on
/// purpose: these tests assert *our rules*, and a test that also depends on
/// Apple's dictionary would start failing on an OS update for reasons that
/// have nothing to do with the code under test.
final class CorrectorTests: XCTestCase {

    /// Exactly the misspellings the cases below need, and nothing else.
    /// Any word absent from this map is treated as correctly spelled, which
    /// makes "the engine left it alone" the default and therefore the thing
    /// a passing test actually proves.
    private let spell = DictionarySpellProvider(corrections: [
        "basiclly": "basically",
        "ncie": "nice",
        "beleive": "believe",
        "actualy": "actually",
        "adn": "and",
        "teh": "the",
        "jumpd": "jumped",
        "recieve": "receive",
        "dropshiping": "dropshipping",
    ])

    private func fix(_ text: String) -> String {
        Corrector(spell: spell).fix(text).text
    }

    // MARK: - It fixes things

    func testTypos() {
        XCTAssertEqual(fix("this is basiclly a ncie idea"), "This is basically a nice idea")
    }

    func testContractionsAndStandaloneI() {
        XCTAssertEqual(fix("i dont think im wrong"), "I don't think I'm wrong")
    }

    func testSpacingAndCapitals() {
        XCTAssertEqual(fix("hello ,world .how are you"), "Hello, world. How are you")
    }

    func testRunOnSentences() {
        XCTAssertEqual(fix("that works.we should ship it"), "That works. We should ship it")
    }

    func testCaseIsCarriedOntoCorrections() {
        XCTAssertEqual(fix("Teh cat"), "The cat")
    }

    func testAllCapsIsTreatedAsAnAcronymAndLeftAlone() {
        // `TEH` is very probably a typo, but ALLCAPS is how people write
        // acronyms and product names, and a corrector that rewrites those is
        // worse than one that misses a shouted typo.
        XCTAssertEqual(fix("TEH cat"), "TEH cat")
    }

    func testCollapsesRepeatedSpaces() {
        XCTAssertEqual(fix("too    many     spaces"), "Too many spaces")
    }

    func testLongEllipsisBecomesOneCharacter() {
        XCTAssertEqual(fix("well.... maybe"), "Well… maybe")
    }

    // MARK: - It leaves things alone (the part that matters)

    func testKeepsCodeAndURLs() {
        let source = "check https://github.com/svj/backspace and run `npm i` in src/app.py"
        XCTAssertEqual(
            fix(source),
            "Check https://github.com/svj/backspace and run `npm i` in src/app.py"
        )
    }

    func testKeepsHandlesAndAcronyms() {
        XCTAssertEqual(fix("@svj the API and SDK docs"), "@svj the API and SDK docs")
    }

    func testKeepsCamelCase() {
        XCTAssertTrue(fix("call getUserById first").contains("getUserById"))
    }

    func testKeepsPascalCase() {
        XCTAssertTrue(fix("the NSSpellChecker class").contains("NSSpellChecker"))
    }

    func testKeepsNumbersAndTimes() {
        XCTAssertEqual(fix("meet at 10:30 for 2.5 hours"), "Meet at 10:30 for 2.5 hours")
    }

    func testKeepsAllowlistedJargon() {
        XCTAssertEqual(fix("the ollama repo uses tauri"), "The ollama repo uses tauri")
    }

    func testKeepsEmailAddresses() {
        XCTAssertTrue(fix("mail me at vs.saicharan@gmail.com ok").contains("vs.saicharan@gmail.com"))
    }

    func testRefusesAmbiguousContractions() {
        // `were` could be `we're` or the past tense. Only meaning tells them
        // apart, so the offline pass must not guess.
        XCTAssertTrue(fix("we were going").contains("were"))
        XCTAssertFalse(fix("we were going").contains("we're"))
    }

    func testDoesNotCorrectShortWords() {
        // Two-letter words are far too easy to "fix" into something else.
        let corrector = Corrector(spell: DictionarySpellProvider(corrections: ["ok": "of"]))
        XCTAssertTrue(corrector.fix("ok then").text.hasPrefix("Ok"))
    }

    func testRejectsWildlyDifferentCandidates() {
        // A candidate more than three characters away in length is a
        // structurally different word, not a typo fix.
        let corrector = Corrector(spell: DictionarySpellProvider(corrections: [
            "dropshiping": "drop",
        ]))
        XCTAssertEqual(corrector.fix("dropshiping works").text, "Dropshiping works")
    }

    func testUserAllowlistIsRespected() {
        let corrector = Corrector(
            spell: DictionarySpellProvider(corrections: ["svjco": "since"]),
            allowlist: ["svjco"]
        )
        XCTAssertEqual(corrector.fix("svjco ships").text, "Svjco ships")
    }

    // MARK: - Degenerate input

    func testEmptyAndWhitespace() {
        let corrector = Corrector(spell: spell)
        XCTAssertEqual(corrector.fix("").text, "")
        XCTAssertFalse(corrector.fix("   ").changed)
        XCTAssertFalse(corrector.fix("\n\n").changed)
    }

    func testWithoutADictionaryEverythingElseStillWorks() {
        // No spellchecker: contractions, capitals and spacing must still run.
        // The tool degrades rather than switching itself off.
        let corrector = Corrector(spell: NoSpellProvider())
        XCTAssertEqual(corrector.fix("i dont know").text, "I don't know")
        // ...and it must not invent corrections it has no dictionary for.
        XCTAssertEqual(corrector.fix("Basiclly fine").text, "Basiclly fine")
    }

    // MARK: - Change reporting

    func testChangesAreReportedWithReasons() {
        let result = Corrector(spell: spell).fix("i cant beleive it")
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.changes.contains { $0.reason == .contraction && $0.after == "can't" })
        XCTAssertTrue(result.changes.contains { $0.reason == .spelling && $0.after == "believe" })
    }

    func testSummaryReadsLikeEnglish() {
        // Already capitalised and correctly spelled, so genuinely nothing to do.
        XCTAssertEqual(Corrector(spell: spell).fix("Nothing wrong here").summary, "already clean")
        XCTAssertEqual(CorrectionResult(text: "x", changes: [
            Change(before: "a", after: "b", reason: .spelling),
        ]).summary, "1 fix")
        XCTAssertEqual(CorrectionResult(text: "x", changes: [
            Change(before: "a", after: "b", reason: .spelling),
            Change(before: "c", after: "d", reason: .spelling),
        ]).summary, "2 fixes")
    }

    // MARK: - The end-to-end case from the README

    func testTheReadmeExample() {
        let corrector = Corrector(spell: DictionarySpellProvider(corrections: [
            "beleive": "believe",
            "actualy": "actually",
            "adn": "and",
            "basiclly": "basically",
        ]))
        XCTAssertEqual(
            corrector.fix("i cant beleive this actualy works, its basiclly reading what i type adn fixing it").text,
            "I can't believe this actually works, its basically reading what I type and fixing it"
        )
    }
}
