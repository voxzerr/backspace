import Foundation

/// The fixed vocabulary the offline pass works from.
///
/// Ported verbatim from the Python engine so the two agree token for token
/// during the transition. Anything added here must be a correction that can
/// be *justified* — a word that is not a word, a missing apostrophe in a
/// contraction, a proper noun that is always capitalised. Judgement calls
/// belong in the model passes, not here.
public enum Vocabulary {

    /// Contractions people type without the apostrophe.
    ///
    /// A `nil` value means "recognised, but deliberately not corrected".
    /// `were` is the important one: `were` and `we're` are both real words
    /// and only meaning tells them apart, so the offline pass refuses to
    /// guess. Same reasoning keeps `its`/`it's` out of this table entirely.
    public static let contractions: [String: String?] = [
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't",
        "cant": "can't", "wont": "won't", "wouldnt": "wouldn't",
        "shouldnt": "shouldn't", "couldnt": "couldn't", "isnt": "isn't",
        "arent": "aren't", "wasnt": "wasn't", "werent": "weren't",
        "hasnt": "hasn't", "havent": "haven't", "hadnt": "hadn't",
        "im": "I'm", "ive": "I've",
        "youre": "you're", "youve": "you've", "youll": "you'll",
        "theyre": "they're", "theyve": "they've", "theyll": "they'll",
        "thats": "that's", "whats": "what's", "heres": "here's",
        "theres": "there's", "whos": "who's",
        "aint": "ain't", "yall": "y'all", "wanna": "want to",

        // Recognised and deliberately declined. Every one of these is a real,
        // common English word far more often than it is a missing apostrophe,
        // and only meaning tells the two apart:
        //
        //   he is ill today        not  he is I'll today
        //   the user id is here    not  the user I'd is here
        //   she lets me drive      not  she let's me drive
        //   we were going          not  we we're going
        //
        // They are listed rather than omitted because `protectedWords` unions
        // these keys — being in the table is what stops the spell pass having
        // an opinion about them too.
        "ill": nil, "id": nil, "lets": nil, "were": nil,
    ]

    /// Words that always carry a specific capitalisation.
    ///
    /// `may` is deliberately absent from the months: it is a far more common
    /// modal verb than it is a month, and capitalising "may" mid-sentence is
    /// exactly the kind of confident-and-wrong correction this tool exists
    /// to avoid.
    public static let proper: [String: String] = [
        "i": "I",
        // days
        "monday": "Monday", "tuesday": "Tuesday", "wednesday": "Wednesday",
        "thursday": "Thursday", "friday": "Friday", "saturday": "Saturday",
        "sunday": "Sunday",
        // Months, minus every one that is also an ordinary word. `may`,
        // `march` and `august` are a modal verb, a verb, and an adjective
        // respectively, and all three are more common in those senses than as
        // dates — "we march forward" must not become "we March forward".
        "january": "January", "february": "February",
        "april": "April", "june": "June", "july": "July",
        "september": "September", "october": "October",
        "november": "November", "december": "December",
        // languages, places, companies
        "english": "English", "spanish": "Spanish", "american": "American",
        "google": "Google", "shopify": "Shopify", "python": "Python",
        "amazon": "Amazon", "claude": "Claude", "anthropic": "Anthropic",
        "alabama": "Alabama",
        // internal caps
        "github": "GitHub", "javascript": "JavaScript",
        "typescript": "TypeScript", "macos": "macOS", "ios": "iOS",
        "iphone": "iPhone", "macbook": "MacBook", "openai": "OpenAI",
        "youtube": "YouTube", "tiktok": "TikTok", "postgres": "Postgres",
        // acronyms
        "ui": "UI", "ux": "UX", "api": "API", "sdk": "SDK", "cli": "CLI",
        "url": "URL", "json": "JSON", "html": "HTML", "css": "CSS",
        "sql": "SQL", "seo": "SEO", "faq": "FAQ", "pdf": "PDF",
        "llm": "LLM", "ai": "AI",
    ]

    /// Multi-word proper nouns, matched case-insensitively on word boundaries.
    ///
    /// Single-word capitalisation runs over `\b[a-z]+\b`, which by construction
    /// can never see a phrase containing a space. These need their own pass.
    public static let properPhrases: [(pattern: String, replacement: String)] = [
        ("vs code", "VS Code"),
        ("new york", "New York"),
        ("san francisco", "San Francisco"),
        ("los angeles", "Los Angeles"),
        ("united states", "United States"),
    ]

    /// Real words the spell pass must never "fix".
    ///
    /// Every entry here is a word a dictionary does not know but a person
    /// typing at a computer uses constantly. Without this list the corrector
    /// turns `npx` into `nix` and `stderr` into `sterner`, which is the single
    /// fastest way to make someone uninstall a typing tool.
    public static let allowlist: Set<String> = [
        "src", "npm", "npx", "pnpm", "yarn", "async", "await", "config",
        "auth", "repo", "cli", "api", "sdk", "env", "url", "uri", "json",
        "yaml", "dev", "prod", "std", "dir", "img", "css", "html", "sql",
        "regex", "enum", "struct", "impl", "init", "args", "kwargs",
        "stdout", "stderr", "localhost", "webhook", "middleware", "backend",
        "frontend", "runtime", "changelog", "readme", "eslint", "vite",
        "ollama", "wispr", "whispr", "whisper", "tauri", "shopify", "stripe",
        "supabase", "vercel", "netlify", "figma", "notion", "obsidian",
        "dropshipping", "plushie", "waypoint", "svj", "cowork",
        // Swift-era additions: this app's own working vocabulary
        "swiftui", "appkit", "xcode", "swiftpm", "keychain", "notarize",
        "accessibility", "anthropic", "claude", "opus", "sonnet", "haiku",
    ]

    /// Everything the spell pass leaves alone: the allowlist, plus every word
    /// we already know how to capitalise or expand.
    public static func protectedWords(extra: Set<String> = []) -> Set<String> {
        var words = allowlist
        words.formUnion(proper.keys)
        words.formUnion(contractions.keys)
        words.formUnion(extra.map { $0.lowercased() })
        return words
    }
}
