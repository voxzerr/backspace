"""Backspace correction engine.

Three modes, cheapest first:

  fix     offline only. Typos, capitals, contractions, spacing. ~1ms.
  clean   fix + a local LLM grammar pass that keeps your voice.
  polish  fix + a local LLM pass that tightens it for work writing.

Everything the LLM returns is checked before it is trusted. If it
rewrites too much, drops your protected tokens, or starts chatting,
the offline result is used instead. A correction tool that surprises
you is worse than no correction tool.
"""

from __future__ import annotations

import difflib
import json
import re
import urllib.error
import urllib.request
from dataclasses import dataclass, field

try:
    from spellchecker import SpellChecker
except ImportError:  # keeps the module importable for tests without the dep
    SpellChecker = None


# --- things we never touch -------------------------------------------------

PROTECTED = re.compile(
    r"""(
        https?://\S+                    # urls
      | \bwww\.\S+                      # bare www
      | \b[\w.+-]+@[\w-]+\.[\w.]+\b     # emails
      | [@#][\w-]+                      # handles, tags
      | `[^`]*`                         # inline code
      # Hostnames and filenames. Deliberately a LIST, not a shape: "works.we"
      # and "example.com" are structurally identical, and a shape-based rule
      # protects the run-on sentence "that works.we should ship it" from ever
      # being split. Only a real TLD or a real extension distinguishes them.
      | \b[\w-]+\.(?:com|net|org|io|co|dev|app|ai|xyz|me|tv|cc|info|biz
                    |uk|us|ca|de|fr|jp|au|nz|in|br|edu|gov|mil)\b(?![\w-])
      | \b[\w-]+\.(?:py|js|ts|tsx|jsx|json|md|sh|css|html|htm|yml|yaml|toml|env
                    |swift|rs|go|rb|java|kt|c|h|cpp|sql|pdf|png|jpg|jpeg|gif|svg
                    |csv|txt|doc|docx|xls|xlsx|ppt|pptx|zip|tar|gz|mp4|mov|mp3)\b
      | [\w.~-]*/[\w./-]+               # paths, relative or absolute
      | \b[\w-]+\(\)                    # func()
      | \b\d[\d,.:/-]*\w*\b             # numbers, times, versions
    )""",
    re.VERBOSE,
)

OPEN, CLOSE = "", ""
PLACEHOLDER = re.compile(re.escape(OPEN) + r"(\d+)" + re.escape(CLOSE))

CONTRACTIONS = {
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

    # Recognised and deliberately declined. Each of these is a real, common
    # English word far more often than it is a missing apostrophe, and only
    # meaning tells the two apart:
    #
    #   he is ill today       not  he is I'll today
    #   the user id is here   not  the user I'd is here
    #   she lets me drive     not  she let's me drive
    #   we were going         not  we we're going
    #
    # Listed rather than omitted because `self.allow` unions these keys —
    # being in the table is what also stops the spell pass touching them.
    "ill": None, "id": None, "lets": None, "were": None,
}

# Months omit "may", "march" and "august": a modal verb, a verb and an
# adjective respectively, each far more common in that sense than as a date.
# "we march forward" must not become "we March forward".
PROPER = {w: w.capitalize() for w in (
    "i monday tuesday wednesday thursday friday saturday sunday january "
    "february april june july september october november "
    "december english spanish american google shopify python amazon claude "
    "anthropic alabama"
).split()}
PROPER.update({
    "i": "I", "github": "GitHub", "javascript": "JavaScript",
    "typescript": "TypeScript", "macos": "macOS", "ios": "iOS",
    "iphone": "iPhone", "macbook": "MacBook", "openai": "OpenAI",
    "youtube": "YouTube", "tiktok": "TikTok", "postgres": "Postgres",
    "vs code": "VS Code",
})
PROPER.update({w: w.upper() for w in
               "ui ux api sdk cli url json html css sql seo faq pdf llm ai".split()})

# words the spell pass must never "fix"
ALLOWLIST = {
    "src", "npm", "npx", "pnpm", "yarn", "async", "await", "config",
    "auth", "repo", "cli", "api", "sdk", "env", "url", "uri", "json",
    "yaml", "dev", "prod", "std", "dir", "img", "css", "html", "sql",
    "regex", "async", "enum", "struct", "impl", "init", "args", "kwargs",
    "stdout", "stderr", "localhost", "webhook", "middleware", "backend",
    "frontend", "runtime", "changelog", "readme", "eslint", "vite",
    "ollama", "wispr", "whispr", "whisper", "tauri", "shopify", "stripe",
    "supabase", "vercel", "netlify", "figma", "notion", "obsidian",
    "dropshipping", "plushie", "waypoint", "svj", "cowork",
}

SENTENCE_START = re.compile(r"(^|[.!?]\s+|\n\s*)([a-z])")
_LLM_PREAMBLE = re.compile(
    r"^(here'?s|here is|sure|certainly|corrected|fixed|i've|okay|ok)\b", re.I
)


@dataclass
class Result:
    text: str
    changes: list[tuple[str, str]] = field(default_factory=list)
    used_llm: bool = False
    note: str = ""

    @property
    def changed(self) -> bool:
        return bool(self.changes)


class Corrector:
    def __init__(
        self,
        model: str = "qwen2.5:3b",
        host: str = "http://127.0.0.1:11434",
        timeout: float = 6.0,
        allowlist: set[str] | None = None,
    ):
        self.model = model
        self.host = host.rstrip("/")
        self.timeout = timeout
        # never "correct" a word we already know how to spell or capitalise
        self.allow = (ALLOWLIST | set(PROPER) | CONTRACTIONS.keys()
                      | {w.lower() for w in (allowlist or set())})
        self._spell = SpellChecker() if SpellChecker else None

    # --- public ------------------------------------------------------------

    def fix(self, text: str, mode: str = "fix") -> Result:
        if not text or not text.strip():
            return Result(text, note="nothing to fix")

        masked, vault = self._mask(text)
        out = self._spacing(masked)
        out, changes = self._words(out)
        out = self._capitals(out)

        result = Result(self._unmask(out, vault), changes)

        if mode in ("clean", "polish"):
            llm = self._llm(result.text, mode, vault)
            if llm:
                result.text = llm
                result.used_llm = True
            else:
                result.note = "offline only (model unavailable or output rejected)"

        return result

    def available(self) -> bool:
        """Is the local model reachable?"""
        try:
            with urllib.request.urlopen(f"{self.host}/api/tags", timeout=1.5) as r:
                return r.status == 200
        except Exception:
            return False

    # --- layers ------------------------------------------------------------

    def _mask(self, text: str) -> tuple[str, list[str]]:
        vault: list[str] = []

        def stash(m: re.Match) -> str:
            vault.append(m.group(0))
            return f"{OPEN}{len(vault) - 1}{CLOSE}"

        return PROTECTED.sub(stash, text), vault

    def _unmask(self, text: str, vault: list[str]) -> str:
        return PLACEHOLDER.sub(lambda m: vault[int(m.group(1))], text)

    def _spacing(self, text: str) -> str:
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r" +([,.!?;:])", r"\1", text)
        text = re.sub(r"([,;:])(?=[^\s\d])", r"\1 ", text)
        text = re.sub(r"(?<=[a-z]{3})([.!?])(?=[A-Za-z])", r"\1 ", text)
        text = re.sub(r"\.{3,}", "…", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()

    def _words(self, text: str) -> tuple[str, list[tuple[str, str]]]:
        changes: list[tuple[str, str]] = []

        def repl(m: re.Match) -> str:
            word = m.group(0)
            fixed = self._word(word)
            if fixed != word:
                changes.append((word, fixed))
            return fixed

        return re.sub(r"[A-Za-z][A-Za-z']*", repl, text), changes

    def _word(self, word: str) -> str:
        low = word.lower()

        if low in CONTRACTIONS and CONTRACTIONS[low]:
            return self._match_case(word, CONTRACTIONS[low])

        if not self._correctable(word):
            return word

        candidate = self._spell.correction(low) if self._spell else None
        if not candidate or candidate == low:
            return word

        # only swap if the fix is a small edit away and clearly more common
        if abs(len(candidate) - len(low)) > 3:
            return word
        if self._spell.word_frequency[candidate] < self._spell.word_frequency[low] * 10:
            return word

        return self._match_case(word, candidate)

    def _correctable(self, word: str) -> bool:
        if not self._spell or len(word) < 3 or "'" in word:
            return False
        if word.isupper() or not word.isalpha():
            return False
        if word[1:] != word[1:].lower():  # camelCase, PascalCase
            return False
        low = word.lower()
        if low in self.allow:
            return False
        return low in self._spell.unknown([low])

    @staticmethod
    def _match_case(original: str, new: str) -> str:
        if original.isupper() and len(original) > 1:
            return new.upper()
        if original[0].isupper():
            return new[0].upper() + new[1:]
        return new

    def _capitals(self, text: str) -> str:
        text = SENTENCE_START.sub(lambda m: m.group(1) + m.group(2).upper(), text)

        def caps(m: re.Match) -> str:
            w = m.group(0)
            return PROPER.get(w.lower(), w)

        return re.sub(r"\b[a-z]+\b", caps, text)

    # --- the model ---------------------------------------------------------

    SYSTEM = {
        "clean": (
            "You fix typing. Return the user's text with spelling, grammar and "
            "punctuation corrected. Keep their voice, slang, contractions and "
            "sentence order exactly as they are. Do not add ideas, greetings, "
            "sign-offs or explanations. Do not answer the text, only correct it. "
            "Preserve any N markers character for character. "
            "Reply with the corrected text and nothing else."
        ),
        "polish": (
            "You edit workplace writing. Return the user's text corrected and "
            "tightened: fix grammar, cut filler, keep it direct and professional. "
            "Same meaning, same order, same facts. Never add new information, "
            "greetings or sign-offs. Preserve any N markers character "
            "for character. Reply with the edited text and nothing else."
        ),
    }

    def _llm(self, text: str, mode: str, vault: list[str]) -> str | None:
        masked, _ = self._mask(text)
        payload = json.dumps({
            "model": self.model,
            "prompt": masked,
            "system": self.SYSTEM[mode],
            "stream": False,
            "options": {"temperature": 0.1, "num_predict": 800},
        }).encode()

        req = urllib.request.Request(
            f"{self.host}/api/generate",
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                raw = json.loads(r.read())["response"]
        except (urllib.error.URLError, OSError, KeyError, ValueError, TimeoutError):
            return None

        return self._vet(raw, masked, vault)

    def _vet(self, raw: str, source: str, vault: list[str]) -> str | None:
        out = raw.strip().strip("`").strip()
        out = re.sub(r"^(?:text|corrected|output)\s*:\s*", "", out, flags=re.I)

        if not out or _LLM_PREAMBLE.match(out):
            return None
        if not 0.5 <= len(out) / max(len(source), 1) <= 1.8:
            return None
        if out.count("\n") > source.count("\n") + 2:
            return None
        # every masked token must come back untouched
        if sorted(PLACEHOLDER.findall(out)) != sorted(PLACEHOLDER.findall(source)):
            return None

        return self._unmask(out, vault)


def word_diff(before: str, after: str) -> list[tuple[str, str]]:
    """Word-level ops for the preview: [('equal', 'the'), ('replace', 'teh|the')]."""
    a, b = before.split(), after.split()
    ops = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=a, b=b).get_opcodes():
        if tag == "equal":
            ops.append(("equal", " ".join(a[i1:i2])))
        elif tag == "delete":
            ops.append(("delete", " ".join(a[i1:i2])))
        elif tag == "insert":
            ops.append(("insert", " ".join(b[j1:j2])))
        else:
            ops.append(("replace", " ".join(a[i1:i2]) + "|" + " ".join(b[j1:j2])))
    return ops


def summary(before: str, after: str) -> str:
    """Short line for the toast, e.g. '3 fixes'."""
    n = sum(1 for tag, *_ in difflib.SequenceMatcher(
        a=before.split(), b=after.split()).get_opcodes() if tag != "equal")
    if not n:
        return "already clean" if before == after else "1 fix"
    return f"{n} fix" + ("es" if n > 1 else "")
