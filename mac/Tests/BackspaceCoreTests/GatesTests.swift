import XCTest
@testable import BackspaceCore

/// The safety gates.
///
/// These are the most important tests in the app, and the ones hardest to
/// write anywhere else: the conditions they cover (a password field has focus,
/// a probe failed, focus moved mid-sentence) cannot be reproduced on a CI
/// runner with no session and no permissions. Keeping the rules pure is what
/// makes them testable at all.
final class GatesTests: XCTestCase {

    /// A context where everything is fine. Each test spoils exactly one thing,
    /// so a failure names its own cause.
    private func safeContext(
        sentence: String = "this is a normal sentence",
        correction: String = "This is a normal sentence",
        app: AppRef = AppRef(bundleID: "com.apple.mail", name: "Mail"),
        blocklist: [String] = ["com.agilebits.onepassword7"],
        platformDetectsPasswordFields: Bool = true,
        focusedFieldIsSecure: Tri = .no,
        secureInputActive: Tri = .no,
        insertionBlocked: Tri = .no,
        idleTime: TimeInterval = 0.1,
        focusMoved: Bool = false
    ) -> TypingContext {
        TypingContext(
            sentence: sentence,
            correction: correction,
            app: app,
            blocklist: blocklist,
            platformDetectsPasswordFields: platformDetectsPasswordFields,
            focusedFieldIsSecure: focusedFieldIsSecure,
            secureInputActive: secureInputActive,
            // Every signal is phrased as "is there a problem?", so NO is the
            // good case for all of them.
            insertionBlocked: insertionBlocked,
            idleTime: idleTime,
            focusMovedSinceSentenceStarted: focusMoved
        )
    }

    func testTheSafeCaseIsAllowed() {
        XCTAssertTrue(Gates.evaluate(safeContext()).allowed)
    }

    // MARK: - UNKNOWN blocks exactly like YES

    func testSecureFieldBlocksOnYesAndOnUnknown() {
        XCTAssertFalse(Gates.evaluate(safeContext(focusedFieldIsSecure: .yes)).allowed)
        XCTAssertFalse(Gates.evaluate(safeContext(focusedFieldIsSecure: .unknown)).allowed)
        XCTAssertTrue(Gates.evaluate(safeContext(focusedFieldIsSecure: .no)).allowed)
    }

    func testSecureInputBlocksOnYesAndOnUnknown() {
        XCTAssertFalse(Gates.evaluate(safeContext(secureInputActive: .yes)).allowed)
        XCTAssertFalse(Gates.evaluate(safeContext(secureInputActive: .unknown)).allowed)
    }

    func testBlockedInsertionBlocksOnYesAndOnUnknown() {
        XCTAssertFalse(Gates.evaluate(safeContext(insertionBlocked: .yes)).allowed)
        XCTAssertFalse(Gates.evaluate(safeContext(insertionBlocked: .unknown)).allowed)
    }

    /// The bug this whole design exists to prevent.
    ///
    /// The naive check is `frontmostApp() in blocklist`, which is `false` for
    /// an app we failed to identify — so an unidentified app reads as an
    /// allowed one and gets typed into.
    func testUnidentifiedAppIsBlockedRatherThanAllowed() {
        let decision = Gates.evaluate(safeContext(app: .unknown))
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "couldn't identify the front app")
    }

    func testBlocklistedAppIsBlockedByName() {
        let onePassword = AppRef(bundleID: "com.agilebits.onepassword7", name: "1Password")
        let decision = Gates.evaluate(safeContext(app: onePassword))
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "1Password is on your blocklist")
    }

    func testBlocklistMatchesSubdomainsOfABundleID() {
        let helper = AppRef(bundleID: "com.agilebits.onepassword7.helper", name: "1Password Helper")
        XCTAssertFalse(Gates.evaluate(safeContext(app: helper)).allowed)
    }

    // MARK: - Categorical refusals

    func testPlatformWithoutPasswordDetectionIsRefusedOutright() {
        // Not disabled with a warning — refused. A keyboard hook on a platform
        // that cannot see password fields is itself the exposure.
        let decision = Gates.evaluate(safeContext(platformDetectsPasswordFields: false))
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "this system can't detect password fields")
    }

    func testPasswordDetectionIsCheckedBeforeAnythingElse() {
        // Even with every other signal clean, a platform that cannot see
        // password fields must lose on the first gate.
        let decision = Gates.evaluate(safeContext(
            app: .unknown,
            platformDetectsPasswordFields: false
        ))
        XCTAssertEqual(decision.reason, "this system can't detect password fields")
    }

    // MARK: - Content heuristics

    func testCodeLookingTextIsLeftAlone() {
        for sentence in [
            "if (x == 1) { return y }",
            "let a = b",
            "cat foo | grep bar",
            "run cmd $HOME",
            "path\\to\\thing",
        ] {
            XCTAssertFalse(
                Gates.evaluate(safeContext(sentence: sentence, correction: sentence)).allowed,
                "should have refused: \(sentence)"
            )
        }
    }

    func testLargeRewritesAreRefused() {
        let decision = Gates.evaluate(safeContext(
            sentence: "short",
            correction: "a very much longer replacement than the original"
        ))
        XCTAssertFalse(decision.allowed)
        XCTAssertTrue(decision.reason?.contains("change too much") == true)
    }

    func testSmallRewritesAreFine() {
        XCTAssertTrue(Gates.evaluate(safeContext(
            sentence: "i cant beleive it",
            correction: "I can't believe it"
        )).allowed)
    }

    // MARK: - Caret safety

    func testFocusMovingMidSentenceBlocks() {
        XCTAssertFalse(Gates.evaluate(safeContext(focusMoved: true)).allowed)
    }

    func testGoingQuietForTooLongBlocks() {
        // A click can move the caret between two fields of the same app with
        // no focus event we can see. The idle window is what covers that.
        XCTAssertTrue(Gates.evaluate(safeContext(idleTime: Gates.maxIdleTime - 0.1)).allowed)
        XCTAssertFalse(Gates.evaluate(safeContext(idleTime: Gates.maxIdleTime + 0.1)).allowed)
    }

    // MARK: - Every refusal explains itself

    func testEveryRefusalCarriesAReason() {
        let refusals = [
            safeContext(platformDetectsPasswordFields: false),
            safeContext(focusedFieldIsSecure: .unknown),
            safeContext(secureInputActive: .yes),
            safeContext(app: .unknown),
            safeContext(sentence: "x = {1}", correction: "x = {1}"),
            safeContext(sentence: "a", correction: String(repeating: "b", count: 40)),
            safeContext(insertionBlocked: .unknown),
            safeContext(focusMoved: true),
            safeContext(idleTime: 99),
        ]
        for context in refusals {
            let decision = Gates.evaluate(context)
            XCTAssertFalse(decision.allowed)
            XCTAssertFalse(decision.reason?.isEmpty ?? true, "a silent refusal is indistinguishable from a bug")
        }
    }
}

final class TriTests: XCTestCase {
    func testUnknownBlocksLikeYes() {
        XCTAssertTrue(Tri.yes.blocks)
        XCTAssertTrue(Tri.unknown.blocks)
        XCTAssertFalse(Tri.no.blocks)
    }

    func testFailedProbeBecomesUnknownNotNo() {
        XCTAssertEqual(Tri(nil), .unknown)
        XCTAssertEqual(Tri(true), .yes)
        XCTAssertEqual(Tri(false), .no)
    }

    func testOrIsConservative() {
        XCTAssertEqual(Tri.no.or(.no), .no)
        XCTAssertEqual(Tri.no.or(.unknown), .unknown)
        XCTAssertEqual(Tri.unknown.or(.yes), .yes)
        XCTAssertEqual(Tri.yes.or(.no), .yes)
    }

    func testUnknownAppNeverMatchesAndNeverMisses() {
        // Both answers must be UNKNOWN: "not on the list" is as dangerous as
        // "on the list" when we never identified the app.
        XCTAssertEqual(AppRef.unknown.matches(["com.apple.mail"]), .unknown)
        XCTAssertEqual(AppRef.unknown.matches([]), .unknown)
    }

    func testEmptyBundleIDIsNotAnIdentifiedApp() {
        XCTAssertFalse(AppRef(bundleID: "", name: "?").known)
        XCTAssertFalse(AppRef(bundleID: "   ", name: "?").known)
    }

    func testBundleIDMatchingIsCaseInsensitive() {
        let app = AppRef(bundleID: "COM.Apple.Mail", name: "Mail")
        XCTAssertEqual(app.matches(["com.apple.mail"]), .yes)
    }
}
