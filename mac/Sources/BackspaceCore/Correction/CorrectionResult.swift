import Foundation

/// How hard the corrector is allowed to work.
public enum Mode: String, Sendable, Codable, CaseIterable {
    /// Offline only. Typos, capitals, contractions, spacing. Sub-millisecond,
    /// no network, never rewrites you.
    case fix
    /// `fix`, then grammar tidied in your own voice by a model.
    case clean
    /// `fix`, then tightened for work writing by a model.
    case polish

    public var needsModel: Bool { self != .fix }

    public var label: String {
        switch self {
        case .fix: return "Fix"
        case .clean: return "Clean"
        case .polish: return "Polish"
        }
    }

    public var explanation: String {
        switch self {
        case .fix: return "Typos, capitals, apostrophes, spacing. Runs on your machine."
        case .clean: return "The above, then grammar tidied in your own voice."
        case .polish: return "The above, then tightened for work writing."
        }
    }
}

/// A single thing the corrector changed, with enough context to explain and
/// to undo it.
public struct Change: Sendable, Equatable, Hashable {
    public let before: String
    public let after: String
    public let reason: Reason

    public enum Reason: String, Sendable, Codable {
        case spelling
        case contraction
        case capitalisation
        case spacing
        case model

        public var describe: String {
            switch self {
            case .spelling: return "spelling"
            case .contraction: return "missing apostrophe"
            case .capitalisation: return "capitalisation"
            case .spacing: return "spacing"
            case .model: return "rewritten"
            }
        }
    }

    public init(before: String, after: String, reason: Reason) {
        self.before = before
        self.after = after
        self.reason = reason
    }
}

/// The outcome of a correction pass.
public struct CorrectionResult: Sendable {
    public let text: String
    public let changes: [Change]
    public let usedModel: Bool
    /// Why we did less than asked, when we did. Empty when nothing to say.
    public let note: String

    public var changed: Bool { !changes.isEmpty }

    public init(text: String, changes: [Change] = [], usedModel: Bool = false, note: String = "") {
        self.text = text
        self.changes = changes
        self.usedModel = usedModel
        self.note = note
    }

    /// Short line for a toast, e.g. "3 fixes".
    public var summary: String {
        switch changes.count {
        case 0: return "already clean"
        case 1: return "1 fix"
        default: return "\(changes.count) fixes"
        }
    }
}
