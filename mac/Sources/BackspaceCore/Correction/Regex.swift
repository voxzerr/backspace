import Foundation

/// A thin, total wrapper over NSRegularExpression.
///
/// Deliberately not Swift's `Regex` literal type: these patterns are ported
/// from Python and need to behave identically, and NSRegularExpression's ICU
/// dialect is much closer to Python's `re` than Swift's own engine is. It also
/// keeps this module free of anything newer than Foundation.
///
/// Every pattern here is a compile-time constant written by us, so a pattern
/// that fails to compile is a programmer error, not a runtime condition —
/// hence the `preconditionFailure` rather than a throwing initialiser that
/// every call site would have to pretend to handle.
struct Pattern {
    private let regex: NSRegularExpression

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Backspace shipped an invalid regex: \(pattern) — \(error)")
        }
    }

    private static func fullRange(of string: String) -> NSRange {
        NSRange(string.startIndex..<string.endIndex, in: string)
    }

    /// Replace every match, letting the caller build the replacement from the
    /// captured groups. Groups that did not participate come back as `nil`.
    func replacingMatches(
        in string: String,
        using transform: (_ groups: [String?]) -> String
    ) -> String {
        let ns = string as NSString
        let matches = regex.matches(in: string, range: Self.fullRange(of: string))
        guard !matches.isEmpty else { return string }

        var out = ""
        out.reserveCapacity(string.count)
        var cursor = 0

        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var groups: [String?] = []
            groups.reserveCapacity(match.numberOfRanges)
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? nil : ns.substring(with: range))
            }
            out += transform(groups)
            cursor = match.range.location + match.range.length
        }

        out += ns.substring(from: cursor)
        return out
    }

    /// Template-based replacement, using `$1`-style references.
    func replacingMatches(in string: String, withTemplate template: String) -> String {
        regex.stringByReplacingMatches(
            in: string,
            range: Self.fullRange(of: string),
            withTemplate: template
        )
    }

    /// Every full-match string, in order. Used to compare masked-token sets.
    func allMatches(in string: String) -> [String] {
        let ns = string as NSString
        return regex.matches(in: string, range: Self.fullRange(of: string))
            .map { ns.substring(with: $0.range) }
    }

    func matches(_ string: String) -> Bool {
        regex.firstMatch(in: string, range: Self.fullRange(of: string)) != nil
    }
}
