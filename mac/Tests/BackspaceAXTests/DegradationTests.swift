import XCTest
@testable import BackspaceAX
import BackspaceCore

/// What CI can actually prove about the platform layer.
///
/// Every runner is headless: no window server, no granted permission, no other
/// applications. That is a *supported* state, and these tests assert it
/// degrades honestly rather than crashing or — much worse — claiming a
/// capability it does not have.
///
/// What these tests deliberately do **not** prove: that a keystroke ever
/// reaches another application, that a correction is ever written, or that an
/// observer ever fires. Those need a real session and a granted permission,
/// and they are verified by hand before a release or they are not verified.
final class DegradationTests: XCTestCase {

    /// The ungranted case, built by hand rather than waited for.
    ///
    /// GitHub's macOS runners have the Accessibility permission pre-granted —
    /// `--doctor` on CI reports every capability as `yes`. So a test written
    /// as `if !isTrusted { assert everything is off }` passes without ever
    /// running an assertion, and the degradation path we most need to be right
    /// about is the one nothing checks. Construct the state instead of hoping
    /// the runner is in it.
    private func capabilities(
        trusted: Bool = true,
        detectsSecureFields: Bool = true,
        observes: Bool = true
    ) -> Accessibility.Capabilities {
        Accessibility.Capabilities(
            accessibilityTrusted: trusted,
            canReadFocusedText: trusted,
            canWriteFocusedText: trusted,
            canDetectSecureFields: trusted && detectsSecureFields,
            canIdentifyFrontmostApp: true,
            canObserveChanges: trusted && observes,
            notes: trusted ? [] : ["Accessibility permission not granted."]
        )
    }

    func testWithoutPermissionNothingIsClaimed() {
        let ungranted = capabilities(trusted: false)
        XCTAssertFalse(ungranted.canReadFocusedText)
        XCTAssertFalse(ungranted.canWriteFocusedText)
        XCTAssertFalse(ungranted.canDetectSecureFields)
        XCTAssertFalse(ungranted.hotkeyPath)
        XCTAssertFalse(ungranted.asYouType)
        XCTAssertFalse(ungranted.notes.isEmpty, "degraded silently: nothing said what was missing")
        XCTAssertNotNil(ungranted.whyNoAsYouType)
    }

    func testTheFullCapabilityTruthTable() {
        // Every combination, so no path through the logic is untested.
        for trusted in [true, false] {
            for detects in [true, false] {
                for observes in [true, false] {
                    let caps = capabilities(
                        trusted: trusted, detectsSecureFields: detects, observes: observes
                    )
                    XCTAssertEqual(caps.hotkeyPath, trusted)
                    XCTAssertEqual(caps.asYouType, trusted && detects && observes)
                    // Unavailable always explains itself; available never does.
                    if caps.asYouType {
                        XCTAssertNil(caps.whyNoAsYouType)
                    } else {
                        XCTAssertFalse(caps.whyNoAsYouType?.isEmpty ?? true)
                    }
                }
            }
        }
    }

    func testTheLiveMachineNeverClaimsMoreThanItsPermissionAllows() {
        // Whatever this runner's state, the invariant holds: no permission
        // means no capability. On a pre-granted runner this asserts the
        // granted side instead, which is still worth checking.
        let live = Accessibility.capabilities()
        if !live.accessibilityTrusted {
            XCTAssertFalse(live.hotkeyPath)
            XCTAssertFalse(live.asYouType)
        }
        XCTAssertEqual(live.hotkeyPath, live.canReadFocusedText && live.canWriteFocusedText)
    }

    func testAsYouTypeRequiresSecureFieldDetection() {
        // The categorical rule: no password-field probe, no watching. The
        // observer is itself the exposure, so this must hold by construction
        // and not by a runtime check somewhere else.
        let blind = capabilities(detectsSecureFields: false)
        XCTAssertFalse(blind.asYouType)
        XCTAssertTrue(blind.whyNoAsYouType?.contains("password") ?? false,
                      "the refusal must name the actual reason")
    }

    func testDoctorReportRunsWithoutASession() {
        let text = Accessibility.capabilities().describe()
        XCTAssertTrue(text.contains("as-you-type"))
        XCTAssertTrue(text.contains("password fields"))
    }

    func testReadingFocusWithoutPermissionReturnsNilRatherThanCrashing() {
        // The headless runner has no focused element and no permission. The
        // contract is "returns nil", not "traps".
        _ = FocusReader.current()
    }

    func testSecureInputProbeAlwaysAnswers() {
        // Whatever it says, it must be a Tri and must not hang.
        let answer = Accessibility.secureInputActive
        XCTAssertTrue(Tri.allCases.contains(answer))
    }

    func testStartingTheTrackerWithoutPermissionInstallsNothing() {
        // Not "installs and filters" — refuses to install. If the permission
        // happens to be granted on some future runner, starting is fine too;
        // what must never happen is a tracker running without permission.
        let tracker = FocusTracker()
        let started = tracker.start()
        if !Accessibility.isTrusted {
            XCTAssertFalse(started, "a watcher was installed with no permission to watch")
        }
        tracker.stop()
    }

    func testDefaultBlocklistIsSaneAndNormalised() {
        let blocklist = AppIdentity.defaultBlocklist
        XCTAssertFalse(blocklist.isEmpty)
        for bundleID in blocklist {
            XCTAssertEqual(bundleID, bundleID.lowercased(), "\(bundleID) will never match")
            XCTAssertTrue(bundleID.contains("."), "\(bundleID) is not a bundle identifier")
        }
        // The ones that matter most: a password manager and a terminal.
        XCTAssertTrue(blocklist.contains { $0.contains("1password") || $0.contains("onepassword") })
        XCTAssertTrue(blocklist.contains { $0.contains("terminal") || $0.contains("iterm") })
    }

    func testChromiumAppsAreFlaggedForTheAccessibilityWakeUp() {
        let slack = AppRef(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let textEdit = AppRef(bundleID: "com.apple.textedit", name: "TextEdit")
        XCTAssertTrue(AppIdentity.needsAccessibilityWakeUp(slack))
        XCTAssertFalse(AppIdentity.needsAccessibilityWakeUp(textEdit))
        // An app we could not identify must not be poked at.
        XCTAssertFalse(AppIdentity.needsAccessibilityWakeUp(.unknown))
    }

    func testFrontmostAppIsAlwaysAValidAppRef() {
        // On a headless runner this is usually `.unknown`, which is correct
        // and must be usable rather than a crash or an empty-string sentinel.
        let app = AppIdentity.frontmost
        if !app.known {
            XCTAssertEqual(app.matches(["anything"]), .unknown)
        }
    }

    func testSystemSpellProviderDoesNotInventCorrections() {
        let provider = SystemSpellProvider()
        // A correctly spelled word must never come back "corrected".
        XCTAssertNil(provider.correction(for: "believe"))
        XCTAssertFalse(provider.isMisspelled("believe"))
    }

    /// The macOS dictionary answers `jumpd` with `jump` — it finds a real word
    /// in the prefix and stops, silently dropping the tense. Someone who typed
    /// `jumpd` meant `jumped`.
    ///
    /// This test runs against the live system dictionary on purpose: the whole
    /// question is what Apple's dictionary actually does, and a fake would
    /// only assert that our own fake behaves as written.
    func testTruncationIsNotAcceptedAsACorrection() {
        let provider = SystemSpellProvider()
        for typo in ["jumpd", "workd", "playd"] {
            guard let correction = provider.correction(for: typo) else { continue }
            XCTAssertFalse(
                typo.lowercased().hasPrefix(correction.lowercased()),
                "'\(typo)' was 'corrected' to '\(correction)' by truncation, "
                    + "which drops meaning rather than fixing a typo"
            )
        }
    }

    func testTheJumpedCase() {
        // The specific regression the CI log surfaced, pinned by name.
        XCTAssertEqual(SystemSpellProvider().correction(for: "jumpd"), "jumped")
    }

    func testEngineWorksWithTheSystemDictionary() {
        // End to end through the real macOS dictionary — the one place CI can
        // check that the seam between the engine and NSSpellChecker is wired
        // up at all.
        let corrector = Corrector(spell: SystemSpellProvider())
        XCTAssertEqual(corrector.fix("i dont know").text, "I don't know")
    }
}
