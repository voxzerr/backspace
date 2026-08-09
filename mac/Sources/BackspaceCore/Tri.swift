import Foundation

/// Every question Backspace asks about the world has three answers, not two.
///
/// This is the single most important type in the app. A probe that fails —
/// an app we could not identify, a password check that errored, a text field
/// that would not answer — must not read as "no". `frontmostApp() in blocklist`
/// is `false` for an app we failed to identify, and that silently fails *open*:
/// the unidentified app gets treated as an allowed one.
///
/// So: `UNKNOWN` blocks exactly like `YES` blocks. Every safety gate in this
/// app asks `.blocks`, never `== .yes`.
public enum Tri: String, Sendable, Codable, CaseIterable {
    case yes
    case no
    case unknown

    /// Does this answer stop us from touching the user's text?
    ///
    /// `UNKNOWN` blocks. That is the whole design.
    public var blocks: Bool {
        switch self {
        case .yes, .unknown: return true
        case .no: return false
        }
    }

    /// Build a Tri from a probe that may have failed.
    ///
    /// `nil` means the probe could not answer, which is `UNKNOWN` — never `NO`.
    public init(_ value: Bool?) {
        switch value {
        case .some(true): self = .yes
        case .some(false): self = .no
        case .none: self = .unknown
        }
    }

    /// Combine two answers conservatively: if either blocks, the result blocks.
    ///
    /// `YES` beats `UNKNOWN` beats `NO`, so a definite yes is never softened
    /// into a maybe by an unrelated failed probe.
    public func or(_ other: Tri) -> Tri {
        if self == .yes || other == .yes { return .yes }
        if self == .unknown || other == .unknown { return .unknown }
        return .no
    }
}

/// A reference to an application, which we may or may not have identified.
///
/// The `known` flag is not a convenience. An app we could not identify must
/// never compare equal to "not on the blocklist", so `matches` returns a Tri
/// rather than a Bool and callers are forced to handle the third case.
public struct AppRef: Sendable, Equatable, Hashable {
    /// Bundle identifier, lowercased, e.g. `com.apple.mail`. Empty when unknown.
    public let bundleID: String
    /// Human-readable name, for the UI only. Never used for matching.
    public let name: String
    /// Did we actually identify this app?
    public let known: Bool

    public static let unknown = AppRef(bundleID: "", name: "Unknown", known: false)

    public init(bundleID: String, name: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.bundleID = id
        self.name = name
        self.known = !id.isEmpty
    }

    private init(bundleID: String, name: String, known: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.known = known
    }

    /// Is this app on the given list?
    ///
    /// Returns `UNKNOWN` — which blocks — when we never identified the app,
    /// rather than `NO`, which would let an unidentified app through.
    public func matches(_ list: some Sequence<String>) -> Tri {
        guard known else { return .unknown }
        let needles = list.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        for needle in needles where bundleID == needle || bundleID.hasPrefix(needle + ".") {
            return .yes
        }
        return .no
    }
}
