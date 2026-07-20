"""Run with: python3 -m pytest test_engine.py -q   (or just: python3 test_engine.py)"""

from engine import Corrector, summary

c = Corrector()


def fix(t):
    return c.fix(t).text


# --- it actually fixes things ---------------------------------------------

def test_typos():
    assert fix("this is basiclly a ncie idea") == "This is basically a nice idea"


def test_contractions_and_i():
    assert fix("i dont think im wrong") == "I don't think I'm wrong"


def test_spacing_and_capitals():
    assert fix("hello ,world .how are you") == "Hello, world. How are you"


def test_run_on_sentences():
    assert fix("that works.we should ship it") == "That works. We should ship it"


# --- it leaves things alone (the part that matters) ------------------------

def test_keeps_code_and_urls():
    src = "check https://github.com/svj/backspace and run `npm i` in src/app.py"
    assert fix(src) == "Check https://github.com/svj/backspace and run `npm i` in src/app.py"


def test_keeps_handles_and_acronyms():
    src = "@svj the API and SDK docs"
    assert fix(src) == "@svj the API and SDK docs"


def test_keeps_camel_case():
    assert "getUserById" in fix("call getUserById first")


def test_keeps_numbers_and_times():
    assert fix("meet at 10:30 for 2.5 hours") == "Meet at 10:30 for 2.5 hours"


def test_keeps_allowlisted_jargon():
    assert fix("the ollama repo uses tauri") == "The ollama repo uses tauri"


def test_empty_and_whitespace():
    assert c.fix("").text == ""
    assert c.fix("   ").changed is False


# --- llm guardrails --------------------------------------------------------

def test_rejects_chatty_model_output():
    assert c._vet("Sure! Here is your corrected text: hello", "helo", []) is None


def test_rejects_runaway_rewrite():
    assert c._vet("x" * 500, "short text", []) is None


def test_rejects_dropped_placeholder():
    src = "see 0 now"
    assert c._vet("see it now", src, ["https://x.com"]) is None


def test_accepts_clean_output():
    src = "i went too the store 0"
    got = c._vet("I went to the store 0", src, ["yesterday"])
    assert got == "I went to the store yesterday"


def test_summary():
    assert summary("teh cat", "The cat") == "1 fix"
    assert summary("same", "same") == "already clean"


if __name__ == "__main__":
    passed = failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                passed += 1
            except AssertionError:
                failed += 1
                print(f"FAIL {name}")
            except Exception as e:
                failed += 1
                print(f"ERROR {name}: {e}")
    print(f"\n{passed} passed, {failed} failed")

    demo = ("As well as the whispr flow can we also make something super simple "
            "copy of that and it basiclly does the exact opposite and whatever "
            "you are typing it automatically corrects for you and it has a ncie "
            "ui to use and whenver i want to push this out on github")
    print("\nbefore:", demo)
    print("\nafter: ", fix(demo))
