import Foundation

/// Checks model output before any of it is trusted.
///
/// A correction tool that surprises you is worse than no correction tool, and
/// a model asked to fix a sentence will sometimes answer it, explain it,
/// translate it, or cheerfully rewrite three paragraphs you did not ask about.
/// Every one of those failures is silent unless something looks.
///
/// Ported from the Python engine's `_vet`, which the README describes as the
/// reason the model passes can be trusted at all — the Swift rewrite shipped
/// the promise without the check. One improvement over the original: markers
/// are compared **in order**, not as sorted multisets. The Python version's
/// own comment claims to catch renumbering, and a sorted comparison cannot —
/// `[0, 1]` and `[1, 0]` sort identically while meaning opposite things.
public enum ModelOutput {

    public enum Rejection: String, Sendable {
        case empty
        case chatty
        case lengthDrift
        case newlineGrowth
        case markersChanged

        public var describe: String {
            switch self {
            case .empty: return "the model returned nothing"
            case .chatty: return "the model started talking instead of correcting"
            case .lengthDrift: return "the model rewrote too much"
            case .newlineGrowth: return "the model restructured the text"
            case .markersChanged: return "the model altered protected content"
            }
        }
    }

    /// Openers that mean the model is addressing you rather than editing.
    private static let preamble = Pattern(
        #"^(here'?s|here is|sure|certainly|corrected|fixed|i've|i have|okay|ok|of course)\b"#,
        options: [.caseInsensitive]
    )

    /// Labels a model adds when it thinks it is filling in a form.
    private static let label = Pattern(
        #"^(?:text|corrected|output|result|answer)\s*:\s*"#,
        options: [.caseInsensitive]
    )

    /// Acceptable size change. Below half is a truncation, above 1.8x is a
    /// rewrite; both mean something other than correction happened.
    private static let lengthBounds: ClosedRange<Double> = 0.5...1.8

    /// How many new lines a correction may introduce before it counts as
    /// restructuring rather than fixing.
    private static let newlineAllowance = 2

    /// Returns the cleaned output, or the reason it cannot be trusted.
    ///
    /// - Parameters:
    ///   - raw: exactly what the model said.
    ///   - source: the masked text it was given, for comparison.
    ///   - expectedMarkers: the protected-content markers, in order.
    public static func vet(
        _ raw: String,
        against source: String,
        expectedMarkers: [String]
    ) -> Result<String, Rejection> {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        out = label.replacingMatches(in: out, withTemplate: "")

        guard !out.isEmpty else { return .failure(.empty) }
        guard !preamble.matches(out) else { return .failure(.chatty) }

        let ratio = Double(out.count) / Double(max(source.count, 1))
        guard lengthBounds.contains(ratio) else { return .failure(.lengthDrift) }

        let sourceLines = source.filter { $0 == "\n" }.count
        let outLines = out.filter { $0 == "\n" }.count
        guard outLines <= sourceLines + newlineAllowance else { return .failure(.newlineGrowth) }

        // Ordered, not sorted: renumbering markers would swap which protected
        // span lands where, and a multiset comparison cannot see that.
        let masking = Masking()
        guard masking.markersInOrder(in: out) == expectedMarkers else {
            return .failure(.markersChanged)
        }

        return .success(out)
    }
}
