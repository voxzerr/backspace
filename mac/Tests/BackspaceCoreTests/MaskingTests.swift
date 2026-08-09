import XCTest
@testable import BackspaceCore

final class MaskingTests: XCTestCase {
    private let masking = Masking()

    func testRoundTripIsLossless() {
        let cases = [
            "see https://example.com/a/b?c=1 for details",
            "email me at a.b+tag@example.co.uk today",
            "run `npm install --save-dev` first",
            "open src/main.swift and Package.swift",
            "call renderView() twice",
            "at 10:30 on 2026-08-09 for 2.5h",
            "ping @svj about #backspace",
            "no protected content at all here",
        ]
        for original in cases {
            let masked = masking.mask(original)
            XCTAssertEqual(masking.unmask(masked.text, vault: masked.vault), original,
                           "round trip lost data for: \(original)")
        }
    }

    func testProtectedSpansAreActuallyRemovedFromTheProse() {
        let masked = masking.mask("go to https://example.com now")
        XCTAssertFalse(masked.text.contains("https://"))
        XCTAssertEqual(masked.vault, ["https://example.com"])
    }

    func testURLIsNotChewedApartByThePathRule() {
        // The alternation is ordered so URLs win. If paths matched first, a
        // URL would come back as three separate fragments and unmasking would
        // reassemble it wrong.
        let masked = masking.mask("https://github.com/svj/backspace")
        XCTAssertEqual(masked.vault.count, 1)
        XCTAssertEqual(masked.vault.first, "https://github.com/svj/backspace")
    }

    func testMarkersUseAPrivateUseArea() {
        // A person cannot type these, so a marker surviving into output is
        // unambiguously our bug and never their text.
        XCTAssertEqual(Masking.open.unicodeScalars.first?.value, 0xE000)
        XCTAssertEqual(Masking.close.unicodeScalars.first?.value, 0xE001)
    }

    func testUnmaskIgnoresInventedMarkers() {
        // A model could hand back a marker index we never issued. That must
        // leave the text intact, not trap.
        let text = "\(Masking.open)7\(Masking.close) is not ours"
        XCTAssertEqual(masking.unmask(text, vault: ["only-one"]), text)
    }

    func testMarkerListIsComparable() {
        let masked = masking.mask("a https://x.com b `code` c")
        XCTAssertEqual(masking.markers(in: masked.text).count, 2)
        XCTAssertEqual(masking.markers(in: "nothing here"), [])
    }
}
