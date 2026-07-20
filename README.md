# Backspace

Fixes your typing anywhere. Runs entirely on your machine.

The opposite of a dictation tool: instead of turning speech into text, it takes
the text you already typed and quietly makes it right.

```
i cant beleive this actualy works, its basiclly reading what i type adn fixing it
→ I can't believe this actually works, its basically reading what I type and fixing it
```

macOS, Windows and Linux. Not equally — see the [capability
matrix](#what-works-where) and the [tested and unverified](#tested-and-unverified)
section, which tells you exactly which parts have been run on a real machine and
which have only been proven as far as CI can prove them.

## Two ways to use it

**Hotkey** — select text in any app, press the hotkey, it is replaced corrected.
Your clipboard is restored afterwards. `⌥Space` on macOS, `Ctrl+Alt+Space` on
Windows and Linux, because `Alt+Space` is already the window menu there.

**As you type** — off by default, and **available on macOS only**. Watches what
you type and fixes each sentence the moment you finish it.

Windows and Linux do not get it. Not disabled with a warning — refused. Neither
platform has a reliable way to tell that the thing you are typing into is a
password field, and a tool that retypes your text without knowing that is a tool
that will one day retype your password into a chat window. The toggle is greyed
out and says why.

## Three levels

| Mode | What it does | Needs a model |
|---|---|---|
| `fix` | Typos, capitals, apostrophes, spacing | no |
| `clean` | The above, then grammar tidied in your own voice | yes |
| `polish` | The above, then tightened for work writing | yes |

`fix` is the default and never rewrites you. It only makes changes it can
justify: a word that is not in the dictionary, a missing apostrophe in a
contraction, a lowercase `i`.

## Install

```bash
git clone https://github.com/YOURNAME/backspace && cd backspace
pip3 install -r requirements.txt
python3 app.py --doctor      # what can this machine actually do?
python3 app.py
```

`--doctor` is the first thing to run on any new machine. It prints every
capability, whether each of the two paths is available, and the reason for
anything that is off. If something does not work later, run it again — it is the
same report the app itself uses to decide what to offer you.

### Running it without a GUI

Nothing here requires a tray, a display, or a permission grant to be useful:

```bash
python3 app.py --headless            # hotkey + settings server, no tray at all
python3 app.py --fix "i cant beleive it wrked"
echo "some txt" | python3 app.py --fix --mode clean
python3 app.py --doctor
```

`--fix` touches no platform library whatsoever. It works on a server, in a
container, over SSH, and inside a CI job.

### macOS

```bash
pip3 install -r requirements.txt
python3 app.py
```

A `⌫` appears in your menu bar. macOS then asks for two permissions:

- **Accessibility** — to send `⌘C` / `⌘V` and replace your selection
- **Input Monitoring** — for the global hotkey and for as-you-type

System Settings → Privacy & Security → grant them to **Terminal** (or to
whatever app you launched Python from), then restart it.

Two things about those grants that cost people an afternoon:

- They are granted to the **interpreter**, not to `app.py`. Upgrading Python, or
  running under a different Python than the one you granted, silently loses
  them.
- Denial is invisible. `CGEventPost` returns success and does nothing; the event
  tap returns NULL. Backspace probes `IOHIDCheckAccess` up front so that
  `start_hotkey` returns a clean False instead of a hotkey that appears to work
  and never fires.

If you are on `/usr/bin/python3` (3.9), the `pyobjc<11` pin in
`requirements.txt` is load-bearing: pyobjc 11+ ships no wheels for 3.9 and
building it from source needs full Xcode.

### Windows

```powershell
pip install -r requirements.txt
python app.py
```

A tray icon appears. No permission dialog — but three things to know:

- **As-you-type is not available.** There is no reliable password-field probe.
  The classic `ES_PASSWORD` window style is blind to Chromium, Electron, WPF,
  UWP, Qt and Swing, which is most of what you actually type into, so it is
  implemented but deliberately not wired to anything that grants permission.
- **UIPI silently eats keystrokes sent to elevated windows.** If the target app
  runs as administrator and Backspace does not, the copy chord goes nowhere and
  you get "Select some text first". Backspace treats an app it cannot identify
  as blocked for exactly this reason.
- **Astral-plane characters** (emoji above U+FFFF) cannot be sent as synthetic
  input, so `can_type()` refuses them before anything is deleted.

The tray icon needs `pystray` and `Pillow`. Without them, use `--headless`.

### Linux

The clipboard and the frontmost-app lookup shell out to command-line tools,
because there is no stable in-process API for either. Install them first:

```bash
# X11
sudo apt install xclip xdotool libnotify-bin
# Wayland
sudo apt install wl-clipboard libnotify-bin

pip3 install -r requirements.txt
python3 app.py --doctor
```

**X11 works. Wayland mostly does not, and this is not a bug in Backspace.**

Under Wayland, no ordinary application can register a global hotkey, watch
keystrokes, inject synthetic input, or ask which window has focus. The
compositor does not expose any of it, on purpose. The trap is that `pynput`
constructs perfectly happily on Wayland and then simply never fires — so
Backspace checks `WAYLAND_DISPLAY` before constructing anything and reports the
feature as unavailable rather than starting a listener that will never work.

`WAYLAND_DISPLAY` is checked before `DISPLAY`, because XWayland sets `DISPLAY`
too and a Wayland session that looks like X11 is the worst of both.

On Wayland you get the clipboard, the settings page, and `--fix`. That is all
there is to get.

If there is no system tray — a minimal window manager, a container, a server —
the app runs headless and says so. It does not fail.

### Optional: local model for `clean` and `polish`

```bash
ollama pull qwen2.5:3b
```

Nothing is sent anywhere. If the model is not running, those modes fall back to
the offline pass instead of failing.

## What works where

| | macOS | Windows | Linux X11 | Linux Wayland |
|---|---|---|---|---|
| Hotkey fix | works [^1] | works [^2] | works [^3] | **impossible** [^4] |
| As-you-type | works [^1] [^5] | **impossible** [^6] | **impossible** [^6] | **impossible** [^4] [^6] |
| Password-field guard | degraded [^5] | **impossible** [^6] | **impossible** [^7] | **impossible** [^7] |
| Frontmost-app blocklist | works | degraded [^8] | degraded [^9] | **impossible** [^4] |
| Tray icon | works | works [^10] | degraded [^11] | degraded [^11] |
| Settings page + `--fix` | works | works | works | works |

[^1]: Needs Accessibility (to send keys) and Input Monitoring (to receive them).
Both are granted to the interpreter, not to the script, and both are lost when
you upgrade Python.

[^2]: Fails silently against windows owned by an elevated process — UIPI drops
synthetic input from a lower-integrity process with no error. Cannot send
codepoints above U+FFFF.

[^3]: Needs `xclip` or `xsel` for the clipboard. X11 has no clipboard change
counter, so the selection is captured by writing a sentinel and watching for it
to be replaced, rather than by polling a counter.

[^4]: Wayland exposes no API for global hotkeys, synthetic input, keystroke
monitoring, or window focus to an unprivileged application. Nothing can be done
about this from inside the app.

[^5]: `IsSecureEventInputEnabled` is **global, not per-field**. It catches the
login window, `sudo` in Terminal, and native password fields. It does **not**
catch a password box in a browser, which is most password boxes. This is why
as-you-type also requires the app blocklist and the code heuristic, and why the
matrix says "degraded" rather than "works".

[^6]: With no password signal, `secure_input_active()` returns UNKNOWN, and
UNKNOWN blocks. `start_watcher()` then returns False **without installing
anything** — not installed and filtered, not installed at all. The keyboard hook
is itself the exposure.

[^7]: AT-SPI2 is not sufficient. A `sudo` prompt in a terminal is a VTE text
area with role `terminal`, not a password widget, so an AT-SPI-based probe would
answer "not a password field" to the most obvious password field on the system.

[^8]: Identifies apps by lowercased exe basename. When `OpenProcess` is denied —
which is exactly the elevated-window case — the app comes back as unknown, and
unknown blocks.

[^9]: Identifies apps by `WM_CLASS` via `xdotool` or `xprop`. The window title is
deliberately not used: it is unstable for matching and carries document names
and URLs there is no reason to hold.

[^10]: Needs `pystray` and `Pillow`. Windows tray balloons have no sound
parameter, so the sound setting is ignored there.

[^11]: `pystray` picks its backend at import time; the `xorg` fallback supports
an icon but no menu, in which case use the settings page. No tray at all on a
server or a minimal WM — the app runs headless.

**"Impossible"** means the operating system does not expose it, not that it is
unimplemented. **"Degraded"** means it works but with a documented hole you
should know about. Run `--doctor` for the answer on your specific machine rather
than trusting this table.

## Tested and unverified

Being straight about this, because the matrix above would otherwise read as a
claim that all four columns got the same treatment. They did not.

**Tested on a real machine — macOS 12.6, Intel, `/usr/bin/python3` 3.9.6:**

- The correction engine, 15 tests.
- The backend contract, 29 tests, against both `NullBackend` and the live
  `MacBackend`.
- The core's safety gates, against fakes: secure input YES and UNKNOWN both
  block, an unidentified frontmost app blocks, a backend that cannot detect
  password fields cannot enable as-you-type, and `can_type()` is asked *before*
  any backspace is sent.
- Live macOS values: clipboard change counter, frontmost bundle id,
  `secure_input_active() → NO`, `pretty_hotkey → ⌥Space`.
- The honest-degradation path, for real: this interpreter has no Input
  Monitoring grant, so `IOHIDCheckAccess` returns denied and `start_hotkey` and
  `start_watcher` both correctly return False rather than pretending.
- Import safety: with AppKit, pynput, rumps, objc and PyObjCTools all blocked by
  a meta-path hook, everything still imports, every capability reports False,
  and `--fix` still works.
- `--doctor`, `--fix` (argv and stdin), and `--headless` end to end, including
  the settings server responding and Ctrl-C shutting down cleanly.

**Not verified anywhere, on any platform:**

- **Any keystroke actually reaching another application.** Copy and paste
  chords, backspacing, retyping, a hotkey firing, a listener delivering keys.
  This machine has no Accessibility or Input Monitoring grant, so the send path
  is silently dropped and the tap returns NULL. The refusal logic is tested; the
  success path is not.
- `secure_input_active()` ever returning YES. Nothing on the test machine holds
  secure input, so only the NO and UNKNOWN branches have run.
- macOS notification banners rendering. Unbundled, the daemon is expected to
  drop them regardless.
- The tray icon or menu bar item appearing. `NSStatusItem` needs a real
  WindowServer session; `pystray` needs a desktop with a status area.
- Blocklist matching against real applications, since a runner has no frontmost
  app to identify.

**Windows: written from documentation. Never executed.** No ctypes call, no
clipboard round-trip, no window creation, no keystroke, no hotkey registration
has ever run on Windows. Signatures were checked against the Win32 documentation
and `ctypes.wintypes`; the module is proven to import cleanly with zero Windows
dependencies present, and proven to degrade to a clear error rather than a
traceback. That is the whole of it. Treat the Windows column as a careful first
draft that has passed a type check, not as a shipped port.

**Linux: written from documentation. Never executed against a real X server or
compositor.** Session detection, the capability gates and the sentinel-based
selection capture were tested against fakes under five simulated sessions
(headless, X11, GNOME Wayland, stale-`DISPLAY` Wayland, non-Linux). The actual
`xclip` / `xsel` / `wl-copy` / `xdotool` / `xprop` invocations, XTEST injection,
and the `WM_CLASS` parser have not seen real output.

**What CI can and cannot prove.** CI runs the full 15-cell matrix — three
operating systems by Python 3.9 through 3.13 — and on each cell installs the
package, prints the capability report, runs both test suites, and asserts four
things: that `engine.py` and `server.py` import no platform library, that every
module still imports with its platform libraries blocked, that the live backend
does not claim a capability it lacks, and that `backend.py`'s platform map
points at modules that actually ship. Every runner is headless, with no desktop
session, no granted permissions and no other applications running, so CI can
verify that Backspace degrades honestly and nothing more. Everything in the two
lists above is hand-tested per platform before a release, or is not tested.

## Settings

Tray or menu bar → Settings, or open http://127.0.0.1:8765

Live preview, hotkey, mode, the app blocklist, and a list of words it should
never touch. Everything saves to `~/.backspace/config.json` as you change it.

The config is re-checked against the platform's capabilities on load and after
every write, so a config file copied from a Mac cannot switch as-you-type on
under a Linux session that has no way to see a password field.

## What it refuses to touch

Most autocorrect is annoying because it is confident about things it should not
be. This one masks these before it looks at anything:

URLs, emails, `@handles`, `#tags`, `inline code`, file paths, filenames,
`func()`, numbers, times, versions, ALLCAPS acronyms, camelCase, and any word
on your allowlist.

As-you-type additionally bails out when:

- the platform cannot detect password fields at all — the feature is refused,
  not warned about
- a password field has focus, **or the probe failed and we do not know**
- the front app is on your blocklist, **or we could not identify it**
- the sentence contains `{}()[]<>=|$\/` — it looks like code
- the correction would change length by more than 12 characters
- the platform cannot type the replacement, checked *before* the backspaces
- focus left the app the sentence was started in, **or it went quiet long
  enough that a click could have moved the caret unseen** (2.5s)

Focus is tracked at app granularity today: a jump between two fields of the
*same* app produces no key event and no app change, so the idle timeout above is
what guards it. The backend exposes a `focused_field()` seam for a future
per-field probe (macOS Accessibility, Windows UI Automation); until one lands
reliably, app identity plus that timeout is the honest guard.

The two "or we do not know" cases are the whole design. Every question about the
world is answered YES, NO or UNKNOWN, and every safety gate treats UNKNOWN the
same as YES, so a broken probe fails closed. The previous version asked
`frontmost_app() in blocklist`, which is False for an app it failed to identify
— an unidentified app read as an allowed one.

Ambiguous corrections are left alone on purpose. `its` / `it's` and `were` /
`we're` depend on meaning, so the offline pass will not guess. That is what
`clean` is for.

## Files

```
engine.py         corrections. no platform dependencies, fully tested
platform_base.py  the contract: Tri, AppRef, Capabilities, Backend, NullBackend
backend.py        picks a backend for this machine, or explains why it cannot
platform_mac.py   macOS: AppKit, Carbon, pynput, rumps
platform_win.py   Windows: ctypes/user32, pynput, pystray
platform_linux.py Linux: xclip/wl-clipboard/xdotool subprocesses, pynput, pystray
app.py            the core plus three front ends. no platform code at all
server.py         local settings API
settings.html     the UI
test_engine.py    python3 test_engine.py
test_backend.py   python3 test_backend.py
```

`app.py` talks to `backend.get_backend()` and nothing else. Nothing in it, in
`engine.py` or in `server.py` imports a platform library at module scope, which
is what makes `--fix` and `--doctor` work on a machine with none of them
installed. A new platform means writing one `platform_*.py` and adding one line
to `backend.py`.

## Roadmap

- [ ] Run the Windows and Linux paths on real machines and replace the
      "unverified" section with results
- [ ] Bundle as a real `.app` with `py2app` so it is a double-click install
- [ ] Package as a directory so `settings.html` survives a non-editable wheel
- [ ] Learn from corrections you undo, and stop making them
- [ ] Per-app modes — `polish` in Gmail, `fix` everywhere else

## License

MIT.
