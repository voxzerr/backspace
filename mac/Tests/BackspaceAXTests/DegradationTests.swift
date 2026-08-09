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

    func testCapabilitiesNeverClaimMoreThanThePermissionAllows() {
        let capabilities = Accessibility.capabilities()

        if !capabilities.accessibilityTrusted {
            XCTAssertFalse(capabilities.canReadFocusedText)
            XCTAssertFalse(capabilities.canWriteFocusedText)
            XCTAssertFalse(capabilities.canDetectSecureFields)
            XCTAssertFalse(capabilities.hotkeyPath)
            XCTAssertFalse(capabilities.asYouType)
            XCTAssertFalse(capabilities.notes.isEmpty, "degraded silently: nothing said what was missing")
        }
    }

    func testUnavailableFeaturesExplainThemselves() {
        let capabilities = Accessibility.capabilities()
        if !capabilities.asYouType {
            XCTAssertNotNil(capabilities.whyNoAsYouType)
            XCTAssertFalse(capabilities.whyNoAsYouType?.isEmpty ?? true)
        }
    }

    func testAsYouTypeRequiresSecureFieldDetection() {
        // The categorical rule: no password-field probe, no watching. The
        // keyboard observer is itself the exposure, so this must hold by
        // construction and not by a runtime check somewhere else.
        let blind = Accessibility.Capabilities(
            accessibilityTrusted: true,
            canReadFocusedText: true,
            canWriteFocusedText: true,
            canDetectSecureFields: false,
            canIdentifyFrontmostApp: true,
            canObserveChanges: true,
            notes: []
        )
        XCTAssertFalse(blind.asYouType)
        XCTAssertNotNil(blind.whyNoAsYouType)
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

    func testEngineWorksWithTheSystemDictionary() {
        // End to end through the real macOS dictionary — the one place CI can
        // check that the seam between the engine and NSSpellChecker is wired
        // up at all.
        let corrector = Corrector(spell: SystemSpellProvider())
        XCTAssertEqual(corrector.fix("i dont know").text, "I don't know")
    }
}
