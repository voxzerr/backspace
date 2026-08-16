import XCTest
@testable import BackspaceCore

/// One case per bug found in the full-codebase review.
///
/// Kept in their own file, named for what they are: every one of these was
/// shipped, and every one turned correct English into wrong English on the
/// live typing path. The safety gates could not catch any of them — the gates
/// stop *dangerous* corrections, not *wrong* ones — so a test is the only
/// thing standing between these and a regression.
final class RegressionTests: XCTestCase {

    private let corrector = Corrector(spell: DictionarySpellProvider(corrections: [
        "beleive": "believe",
        "actualy": "actually",
    ]))

    private func fix(_ text: String) -> String { corrector.fix(text).text }

    // MARK: - Real words wrongly expanded as contractions

    func testRealWordsAreNotExpandedIntoContractions() {
        // Each of these is a common English word far more often than it is a
        // missing apostrophe, and only meaning tells them apart.
        XCTAssertEqual(fix("he is ill today"), "He is ill today")
        XCTAssertEqual(fix("the user id is here"), "The user id is here")
        XCTAssertEqual(fix("she lets me drive"), "She lets me drive")
        XCTAssertEqual(fix("we were going"), "We were going")
    }

    func testGenuineContractionsStillExpand() {
        // The fix above must not have disarmed the feature.
        XCTAssertEqual(fix("i dont know"), "I don't know")
        XCTAssertEqual(fix("that wasnt me"), "That wasn't me")
        XCTAssertEqual(fix("im here"), "I'm here")
    }

    // MARK: - Ordinary words wrongly capitalised as months

    func testMonthsThatAreAlsoOrdinaryWordsAreLeftAlone() {
        XCTAssertEqual(fix("we march forward"), "We march forward")
        XCTAssertEqual(fix("a august evening"), "A august evening")
        XCTAssertEqual(fix("it may rain"), "It may rain")
    }

    func testUnambiguousMonthsStillCapitalise() {
        XCTAssertEqual(fix("see you in january"), "See you in January")
        XCTAssertEqual(fix("due friday"), "Due Friday")
    }

    // MARK: - Hostnames and filenames split apart

    func testHostnamesAndFilenamesSurviveIntact() {
        XCTAssertEqual(fix("the report.pdf is ready"), "The report.pdf is ready")
        XCTAssertEqual(fix("check example.com for details"), "Check example.com for details")
        XCTAssertEqual(fix("see sub.example.co.uk now"), "See sub.example.co.uk now")
        XCTAssertEqual(fix("open notes.txt then"), "Open notes.txt then")
    }

    func testRunOnSentencesAreStillJoinedCorrectly() {
        // The reason the hostname rule is a list and not a shape: "works.we"
        // is structurally identical to "example.com", and this correction is
        // one people actually want.
        XCTAssertEqual(fix("that works.we should ship it"), "That works. We should ship it")
    }

    // MARK: - Curly apostrophes

    func testCurlyApostrophesAreTreatedAsApostrophes() {
        // macOS substitutes U+2019 by default in every field this app targets,
        // so by the time we see the text the straight quote is usually gone.
        // A tokenizer that knows only U+0027 splits `doesn't` into `doesn` +
        // `t` and hands the stem to the spellchecker.
        let smart = "that doesn\u{2019}t work"
        XCTAssertEqual(fix(smart), "That doesn\u{2019}t work")

        let corrector = Corrector(spell: DictionarySpellProvider(corrections: ["doesn": "dozen"]))
        XCTAssertEqual(corrector.fix(smart).text, "That doesn\u{2019}t work")
    }

    // MARK: - Markers must never reach the user

    func testChangesNeverCarryPrivateUseMarkers() {
        let result = corrector.fix("check example.com now.it works")
        for change in result.changes {
            XCTAssertFalse(change.before.contains(Masking.open), "marker leaked into a change")
            XCTAssertFalse(change.after.contains(Masking.open), "marker leaked into a change")
        }
        XCTAssertFalse(result.text.contains(Masking.open))
    }
}

final class SentenceBoundaryRegressionTests: XCTestCase {
    private let scanner = SentenceScanner()

    private func sentence(_ text: String) -> String? {
        let caret = (text as NSString).length
        guard let range = scanner.completedSentence(in: text, caret: caret) else { return nil }
        return (text as NSString).substring(with: range)
    }

    func testADotInsideATokenIsNotASentenceEnd() {
        XCTAssertNil(sentence("check example.com"))
        XCTAssertNil(sentence("open report.pdf"))
        XCTAssertNil(sentence("that is 3.5"))
    }

    func testScanningBackwardsSkipsInTokenDots() {
        // Without this the sentence start lands inside the hostname and the
        // corrector is handed "com for details." — which comes back as
        // "Com for details."
        XCTAssertEqual(
            sentence("check example.com for details."),
            "check example.com for details."
        )
        XCTAssertEqual(
            sentence("open report.pdf and read it."),
            "open report.pdf and read it."
        )
    }

    func testRealSentenceEndsStillFire() {
        XCTAssertEqual(sentence("this is done."), "this is done.")
        XCTAssertEqual(sentence("first. second one."), "second one.")
    }
}

final class ModelOutputTests: XCTestCase {
    private let masking = Masking()

    private func vet(_ raw: String, source: String) -> Result<String, ModelOutput.Rejection> {
        ModelOutput.vet(raw, against: source, expectedMarkers: masking.markersInOrder(in: source))
    }

    func testAcceptsACleanCorrection() {
        let result = vet("I went to the store", source: "i went too the store")
        XCTAssertEqual(try? result.get(), "I went to the store")
    }

    func testRejectsAChattyModel() {
        // "Sure! Here is your corrected text: ..." must never be pasted into
        // someone's document.
        for chatty in [
            "Sure! Here is your corrected text: hello",
            "Here's the fixed version: hello",
            "Of course. hello there friend",
        ] {
            if case .success = vet(chatty, source: "helo there friend") {
                XCTFail("accepted chatty output: \(chatty)")
            }
        }
    }

    func testStripsLabelsRatherThanRejecting() {
        let result = vet("Corrected: I went to the store", source: "i went too the store")
        XCTAssertEqual(try? result.get(), "I went to the store")
    }

    func testRejectsARunawayRewrite() {
        if case .success = vet(String(repeating: "x", count: 500), source: "short text") {
            XCTFail("accepted a runaway rewrite")
        }
    }

    func testRejectsATruncation() {
        if case .success = vet("I", source: "a much longer original sentence here") {
            XCTFail("accepted a truncation")
        }
    }

    func testRejectsRestructuring() {
        let source = "one line here"
        if case .success = vet("a\nb\nc\nd\ne", source: source) {
            XCTFail("accepted a restructured answer")
        }
    }

    func testRejectsDroppedProtectedContent() {
        let masked = masking.mask("see https://example.com now")
        let result = ModelOutput.vet(
            "see it now",
            against: masked.text,
            expectedMarkers: masking.markersInOrder(in: masked.text)
        )
        if case .success = result { XCTFail("accepted output that dropped a protected span") }
    }

    func testRejectsReorderedMarkers() {
        // The check the sorted comparison could not make: two protected spans
        // swapping places means the URL and the file path traded positions.
        let masked = masking.mask("see https://a.com and https://b.com")
        let swapped = masked.text
            .replacingOccurrences(of: "\(Masking.open)0\(Masking.close)", with: "@@TMP@@")
            .replacingOccurrences(of: "\(Masking.open)1\(Masking.close)", with: "\(Masking.open)0\(Masking.close)")
            .replacingOccurrences(of: "@@TMP@@", with: "\(Masking.open)1\(Masking.close)")
        let result = ModelOutput.vet(
            swapped,
            against: masked.text,
            expectedMarkers: masking.markersInOrder(in: masked.text)
        )
        if case .success = result { XCTFail("accepted reordered markers") }
    }

    func testEveryRejectionExplainsItself() {
        for rejection in [
            ModelOutput.Rejection.empty, .chatty, .lengthDrift, .newlineGrowth, .markersChanged,
        ] {
            XCTAssertFalse(rejection.describe.isEmpty)
        }
    }
}
