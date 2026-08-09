# Backspace for macOS

The native rewrite. Reads and writes text through the **Accessibility API**
instead of reconstructing keystrokes and round-tripping the clipboard.

The Python app at the repository root still works and is still the only thing
that has been run end to end on real hardware. It stays until this replaces it.

## Why this is a rewrite and not a port

The Python version watched a keyboard hook, rebuilt what you had typed since
the field gained focus, and replaced your selection by sending `⌘C` / `⌘V`.
That works, but it is the wrong foundation for a writing assistant:

| | keystroke + clipboard | Accessibility API |
|---|---|---|
| Sees | only what you typed since focus | the whole field |
| Edits by | synthesising `⌘C`/`⌘V` and backspaces | writing the value directly |
| Clipboard | borrowed and restored | never touched |
| Password fields | one global flag, blind to browsers | the field's own `AXSecureTextField` subrole |
| Caret position on screen | unknowable | `kAXBoundsForRangeParameterizedAttribute` |

That last row is what makes inline suggestions possible at all: it is the only
way to learn where a run of text is being drawn inside another app's window.

## Layout

```
Sources/
  BackspaceCore/     Foundation only. Correction engine + safety gates.
    Correction/      masking, vocabulary, the rules, sentence detection
    Guards/          Tri and the fail-closed gate chain
  BackspaceAX/       macOS platform layer: Accessibility, focus, spellchecker
  BackspaceAI/       Claude API client and the prompts behind each surface
  BackspaceApp/      menu bar app, coordinator, settings
Tests/
  BackspaceCoreTests/  the engine and the gates, exhaustively
  BackspaceAXTests/    that the platform layer degrades honestly
```

`BackspaceCore` imports nothing but Foundation, and CI asserts it by parsing
the imports rather than trusting a review. That is what makes the correction
rules and every safety gate testable on a machine with no display, no
permission and no windowserver — which is every CI runner we will ever have.

## Running it

```bash
swift build
swift test

swift run backspace --doctor            # what can this machine actually do?
swift run backspace --fix "teh quick brown fox"
echo "i cant beleive it" | swift run backspace --fix
```

`--doctor` and `--fix` touch no platform API and need no permission. They work
over SSH, in a container, and in CI.

## Permission

Backspace needs **Accessibility** (System Settings → Privacy & Security →
Accessibility). Two things about that grant cost people an afternoon:

- It belongs to the **binary that asks**, not to the source. Moving or
  rebuilding the app can lose it silently.
- **Denial is invisible at the call site.** The API returns plausible errors
  and the observer simply never fires. So we probe up front and report a clean
  `false` rather than shipping a feature that appears to work and never does.

## The safety design

Every question about the world is answered `YES`, `NO`, or `UNKNOWN`, and every
gate treats `UNKNOWN` exactly like `YES`. A probe that failed must never read
as "no problem".

The bug this exists to prevent: `frontmostApp() in blocklist` is `false` for an
app we failed to identify — so an unidentified app reads as an allowed one and
gets typed into. `AppRef.matches` returns a `Tri`, so that cannot compile.

As-you-type additionally refuses when: the field is (or might be) a password
field, secure input is (or might be) active, the front app is on your blocklist
or could not be identified, the sentence contains `{}()[]<>=|$\/`, the change
is more than 12 characters, the field will not accept the insertion, focus
moved, or it went quiet for 2.5s — long enough that a click could have moved
the caret unseen.

## What is verified, and what is not

**Verified by CI on a macOS runner:** it compiles; the full core test suite
passes; `BackspaceCore` imports nothing platform-specific; `--doctor` and
`--fix` run end to end with no permission and no display; the capability
report never claims something the permission does not allow.

**Verified against the Python engine:** every correction case in
`CorrectorTests` produces byte-identical output to `engine.py`, which was
tested on real hardware.

**Not verified anywhere yet:** that a correction is ever actually written into
another application's text field. That needs a real session and a granted
permission. CI is headless by construction, so this is hand-tested before a
release or it is not tested. Treat the Accessibility write path as a careful
first draft that type-checks, not as shipped.
