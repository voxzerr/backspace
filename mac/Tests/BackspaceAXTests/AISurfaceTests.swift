import XCTest
@testable import BackspaceAX
import BackspaceCore

/// Detecting that you are typing into an AI.
///
/// The pure halves are tested here — app matching and URL matching. The live
/// `current(app:focused:)` walk needs a real browser with a real focused
/// element, so CI can only prove it compiles.
final class AISurfaceTests: XCTestCase {

    private func app(_ bundleID: String) -> AppRef {
        AppRef(bundleID: bundleID, name: bundleID)
    }

    func testRecognisesNativeAIClients() {
        XCTAssertEqual(AISurface.fromApp(app("com.openai.chat"))?.name, "ChatGPT")
        XCTAssertEqual(AISurface.fromApp(app("com.anthropic.claudefordesktop"))?.name, "Claude")
        XCTAssertEqual(AISurface.fromApp(app("com.todesktop.230313mzl4w4u92"))?.name, "Cursor")
    }

    func testDoesNotMistakeOrdinaryAppsForAI() {
        XCTAssertNil(AISurface.fromApp(app("com.apple.mail")))
        XCTAssertNil(AISurface.fromApp(app("com.tinyspeck.slackmacgap")))
    }

    func testAnUnidentifiedAppIsNeverAnAISurface() {
        // Guessing here would mean sending someone's text somewhere on the
        // strength of a probe that failed.
        XCTAssertNil(AISurface.fromApp(.unknown))
    }

    func testRecognisesAIHosts() {
        XCTAssertEqual(AISurface.fromURL("https://chatgpt.com/c/abc123")?.name, "ChatGPT")
        XCTAssertEqual(AISurface.fromURL("https://claude.ai/chat/xyz")?.name, "Claude")
        XCTAssertEqual(AISurface.fromURL("https://www.perplexity.ai/search?q=x")?.name, "Perplexity")
    }

    func testDetectionViaURLIsMarkedAsSuch() {
        XCTAssertEqual(AISurface.fromURL("https://claude.ai/new")?.viaURL, true)
        XCTAssertEqual(AISurface.fromApp(app("com.openai.chat"))?.viaURL, false)
    }

    func testOrdinaryBrowsingIsNotAnAISurface() {
        XCTAssertNil(AISurface.fromURL("https://github.com/voxzerr/backspace"))
        XCTAssertNil(AISurface.fromURL("https://news.ycombinator.com"))
        XCTAssertNil(AISurface.fromURL(""))
    }

    func testKnowsWhichAppsAreBrowsers() {
        // Only browsers get their URL read at all — that scoping is the whole
        // privacy argument for reading it.
        XCTAssertTrue(AISurface.isBrowser(app("com.apple.safari")))
        XCTAssertTrue(AISurface.isBrowser(app("com.google.chrome")))
        XCTAssertFalse(AISurface.isBrowser(app("com.apple.mail")))
        XCTAssertFalse(AISurface.isBrowser(.unknown))
    }

    func testANonBrowserIsNeverURLSniffed() {
        // Mail is not a browser, so even with a focused element there is no
        // URL read and no detection.
        XCTAssertNil(AISurface.current(app: app("com.apple.mail"), focused: nil))
    }
}
