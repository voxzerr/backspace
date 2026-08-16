import Foundation

/// Hides the things a corrector has no business touching.
///
/// Most autocorrect is annoying because it is confident about things it should
/// not be. Before any rule runs, every URL, email, handle, path, filename,
/// function call, inline code span and number is lifted out and replaced with
/// an opaque marker. The rules then operate on prose only, and the originals
/// are put back byte for byte afterwards.
///
/// The markers are U+E000 and U+E001 — private-use codepoints, so they cannot
/// collide with anything a person actually types, and a marker that survives
/// into the output is unambiguously our bug rather than their text.
public struct Masking: Sendable {
    public static let open = "\u{E000}"
    public static let close = "\u{E001}"

    /// The union of everything we refuse to touch. Order inside the
    /// alternation matters: URLs come first so that the path and number
    /// branches cannot chew a URL apart mid-match.
    private static let protectedPattern = Pattern(
        [
            #"https?://\S+"#,                     // urls
            #"\bwww\.\S+"#,                       // bare www
            #"\b[\w.+-]+@[\w-]+\.[\w.]+\b"#,      // emails
            #"[@#][\w-]+"#,                       // @handles, #tags
            "`[^`]*`",                            // inline code
            // Hostnames and filenames.
            //
            // Deliberately a LIST, not a shape. `example.com` and `works.we`
            // are structurally identical — a shape-based rule protects the
            // run-on sentence "that works.we should ship it" from ever being
            // split, which is a correction people actually want. Only a real
            // TLD or a real extension tells the two apart.
            //
            // The previous list covered code and config extensions only, so
            // "the report.pdf is ready" came out as "The report. Pdf is ready".
            #"\b[\w-]+\.(?:com|net|org|io|co|dev|app|ai|xyz|me|tv|cc|info|biz|uk|us|ca|de|fr|jp|au|nz|in|br|edu|gov|mil)\b(?![\w-])"#,
            #"\b[\w-]+\.(?:py|js|ts|tsx|jsx|json|md|sh|css|html|htm|yml|yaml|toml|env|swift|rs|go|rb|java|kt|c|h|cpp|sql|pdf|png|jpg|jpeg|gif|svg|csv|txt|doc|docx|xls|xlsx|ppt|pptx|zip|tar|gz|mp4|mov|mp3)\b"#,
            #"[\w.~-]*/[\w./-]+"#,                // paths, relative or absolute
            #"\b[\w-]+\(\)"#,                     // func()
            #"\b\d[\d,.:/-]*\w*\b"#,              // numbers, times, versions
        ].joined(separator: "|")
    )

    private static let placeholderPattern = Pattern(open + #"(\d+)"# + close)

    /// A masked document: prose with markers, plus the originals to restore.
    public struct Masked: Sendable {
        public let text: String
        public let vault: [String]

        public var isEmpty: Bool { vault.isEmpty }
    }

    public init() {}

    /// Replace every protected span with an opaque marker.
    public func mask(_ text: String) -> Masked {
        var vault: [String] = []
        let masked = Self.protectedPattern.replacingMatches(in: text) { groups in
            let original = groups[0] ?? ""
            vault.append(original)
            return "\(Self.open)\(vault.count - 1)\(Self.close)"
        }
        return Masked(text: masked, vault: vault)
    }

    /// Put the originals back.
    ///
    /// A marker whose index is out of range is left in place rather than
    /// crashing: that can only happen if a model invented a marker, and the
    /// vetting pass is what catches it. Never trap on untrusted output.
    public func unmask(_ text: String, vault: [String]) -> String {
        guard !vault.isEmpty else { return text }
        return Self.placeholderPattern.replacingMatches(in: text) { groups in
            guard let digits = groups[1], let index = Int(digits), vault.indices.contains(index) else {
                return groups[0] ?? ""
            }
            return vault[index]
        }
    }

    /// Every marker present in a string, sorted.
    ///
    /// Used to prove a model handed back exactly the markers it was given —
    /// no additions, no losses, no renumbering.
    public func markers(in text: String) -> [String] {
        Self.placeholderPattern.allMatches(in: text).sorted()
    }

    /// Every marker present, in the order they appear.
    ///
    /// The ordered form is the one that can actually catch a model renumbering
    /// markers: sorted, `[0, 1]` and `[1, 0]` compare equal while meaning that
    /// two protected spans swapped places.
    public func markersInOrder(in text: String) -> [String] {
        Self.placeholderPattern.allMatches(in: text)
    }
}
