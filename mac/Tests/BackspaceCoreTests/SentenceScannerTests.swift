import XCTest
@testable import BackspaceCore

final class SentenceScannerTests: XCTestCase {
    private let scanner = SentenceScanner()

    private func sentence(_ text: String, caret: Int? = nil) -> String? {
        let position = caret ?? (text as NSString).length
        guard let range = scanner.completedSentence(in: text, caret: position) else { return nil }
        return (text as NSString).substring(with: range)
    }

    func testFiresOnATerminator() {
        XCTAssertEqual(sentence("this is done."), "this is done.")
    }

    func testFiresAfterTheTrailingSpace() {
        XCTAssertEqual(sentence("this is done. "), "this is done.")
    }

    func testDoesNotFireMidSentence() {
        XCTAssertNil(sentence("this is still being"))
        XCTAssertNil(sentence("this is still being typed"))
    }

    func testOnlyReturnsTheMostRecentSentence() {
        XCTAssertEqual(sentence("first one. second one."), "second one.")
    }

    func testHandlesQuestionsAndExclamations() {
        XCTAssertEqual(sentence("does it work?"), "does it work?")
        XCTAssertEqual(sentence("it works!"), "it works!")
    }

    func testEllipsisIsAPauseNotAnEnding() {
        // "Hmm..." is someone still thinking, not someone finished.
        XCTAssertNil(sentence("hmm..."))
        XCTAssertNil(sentence("wait.."))
    }

    func testIgnoresTrivialFragments() {
        // A "sentence" of one or two characters is punctuation, not prose.
        XCTAssertNil(sentence("a."))
        XCTAssertNil(sentence("."))
        XCTAssertNil(sentence("ok. a."))
    }

    func testStartsAfterANewline() {
        XCTAssertEqual(sentence("first line\nsecond line."), "second line.")
    }

    func testCaretBeforeTheEndOfTheField() {
        // The person moved back and finished an earlier sentence; we correct
        // that one, not whatever trails after the caret.
        let text = "done here. and more text later"
        XCTAssertEqual(sentence(text, caret: 10), "done here.")
    }

    func testDegenerateInput() {
        XCTAssertNil(sentence(""))
        XCTAssertNil(scanner.completedSentence(in: "abc.", caret: 0))
        XCTAssertNil(scanner.completedSentence(in: "abc.", caret: 999))
    }

    func testEmojiDoNotDesyncTheOffsets() {
        // Offsets are UTF-16 because that is what the Accessibility API
        // speaks. A grapheme-indexed scanner would land in the wrong place
        // the first time someone types an emoji.
        let text = "nice 👍 work here."
        let ns = text as NSString
        XCTAssertEqual(sentence(text, caret: ns.length), "nice 👍 work here.")
    }
}
