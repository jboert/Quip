#!/usr/bin/env python3
"""
Kokoro TTS helper for Quip.

Reads raw terminal text from stdin (or --text arg), filters out Claude Code
TUI chrome, code blocks, diffs, and shell prompts, synthesizes speech with
kokoro-onnx, and writes WAV bytes to stdout.

Model files are loaded from ~/Library/Application Support/Quip/kokoro/ on macOS.
They must be downloaded once before first use — see setup docs.

Usage:
    echo "text" | python3 kokoro_tts.py > out.wav
    python3 kokoro_tts.py --text "hello" > out.wav
    python3 kokoro_tts.py --voice af_bella --text "hi"
"""

import argparse
import io
import os
import re
import sys
import wave
from pathlib import Path

VOICES_DIR = Path.home() / "Library" / "Application Support" / "Quip" / "kokoro"
MODEL_PATH = VOICES_DIR / "kokoro-v1.0.onnx"
VOICES_PATH = VOICES_DIR / "voices-v1.0.bin"
DEFAULT_VOICE = "af_heart"
DEFAULT_LANG = "en-us"
DEFAULT_SPEED = 0.95


_PERMISSION_SIGNATURES = (
    "do you want to proceed",
    "don't ask again",
    "don\u2019t ask again",
    "tell claude what to do",
)


def _describe_tool_permission(text):
    """If text looks like a Claude Code tool-permission prompt, return a
    first-person plain-language announcement suitable for TTS. Else None.

    The prompt box renders the tool call (e.g. "Bash(git status)") plus a
    numbered options list. We replace the whole thing with one sentence so the
    user hears what they're approving in natural speech instead of raw syntax.
    """
    low = text.lower()
    if not any(s in low for s in _PERMISSION_SIGNATURES):
        return None

    # Flatten box-drawing so the tool-call regex can span wrapped lines.
    flat = re.sub(r"[\u2500-\u259F]+", " ", text)
    m = re.search(r"\b([A-Z][A-Za-z]+)\((.*?)\)", flat, flags=re.DOTALL)
    if not m:
        return "I want to use a tool. Approve, deny, or always allow?"

    tool = m.group(1)
    args_raw = re.sub(r"\s+", " ", m.group(2)).strip()

    def strip_kw(s: str) -> str:
        s = s.strip()
        kw = re.match(r"^([a-z_]+)\s*[:=]\s*(.*)$", s, flags=re.DOTALL)
        return kw.group(2).strip() if kw else s

    def basename_of(s: str) -> str:
        s = strip_kw(s).strip("`'\"")
        return s.rsplit("/", 1)[-1] if s else ""

    first_arg = args_raw.split(",", 1)[0]

    if tool == "Bash":
        cmd = strip_kw(args_raw).strip("`'\"")
        tokens = cmd.split()
        if not tokens:
            return "I want to run a shell command. Approve, deny, or always allow?"
        first = tokens[0].rsplit("/", 1)[-1]
        if not re.match(r"^[a-zA-Z][a-zA-Z0-9_.-]*$", first):
            return "I want to run a shell command. Approve, deny, or always allow?"
        second = None
        if len(tokens) > 1:
            t = tokens[1].strip("`'\"")
            if re.match(r"^[a-z][a-z0-9_-]{0,20}$", t):
                second = t
        if second:
            return f"I want to run {first} {second}. Approve, deny, or always allow?"
        return f"I want to run a {first} command. Approve, deny, or always allow?"

    if tool in ("Edit", "MultiEdit"):
        f = basename_of(first_arg)
        return (f"I want to edit {f}. Approve, deny, or always allow?"
                if f else "I want to edit a file. Approve, deny, or always allow?")
    if tool == "Write":
        f = basename_of(first_arg)
        return (f"I want to write to {f}. Approve, deny, or always allow?"
                if f else "I want to write a file. Approve, deny, or always allow?")
    if tool == "Read":
        f = basename_of(first_arg)
        return (f"I want to read {f}. Approve, deny, or always allow?"
                if f else "I want to read a file. Approve, deny, or always allow?")
    if tool == "Glob":
        return "I want to find files by pattern. Approve, deny, or always allow?"
    if tool == "Grep":
        return "I want to search through code. Approve, deny, or always allow?"
    if tool == "WebFetch":
        return "I want to fetch a web page. Approve, deny, or always allow?"
    if tool == "WebSearch":
        return "I want to search the web. Approve, deny, or always allow?"

    spoken = re.sub(r"([a-z])([A-Z])", r"\1 \2", tool).lower()
    return f"I want to use the {spoken} tool. Approve, deny, or always allow?"


# Common code-file extensions worth dropping in prose (e.g. "main_window.rs" →
# "main_window"). Tail-anchored at a word boundary so we only drop trailing
# extensions and don't mangle dotted module references like "foo.bar".
_CODE_EXT_RE = re.compile(
    r"(\b[A-Za-z][\w]*?)\.(?:rs|py|swift|ts|tsx|js|jsx|go|cpp|hpp|java|kt|md|"
    r"json|yaml|yml|toml|sh|cc|hh|rb|sql|css|scss|html|xml|c|h)\b"
)

# 7-12 contiguous lowercase-hex chars containing at least one digit (commit
# SHAs always do). The digit gate avoids rewriting real English words that
# happen to be all-hex, e.g. "defaced", "facaded". Word boundaries on both
# sides keep this from chopping into longer identifiers.
_HEX_HASH_RE = re.compile(r"(?<![\w.])(?=[0-9a-f]*[0-9])[0-9a-f]{7,12}(?![\w.])")


def _split_identifier(tok: str) -> str:
    """Make snake_case / CamelCase identifiers more pronounceable.

    No-op on normal English words and short tokens. Splits when:
      * 2+ underscores, OR a single underscore in a token of length ≥ 8
      * 3+ uppercase letters mixed with at least one lowercase

    Examples:
        portal_client            → "portal client"
        TrackingTokensConfigured → "Tracking Tokens Configured"
        XMLParser                → "XML Parser"
        iOS                      → "iOS"      (only 2 uppercase, untouched)
        Anthropomorphism         → unchanged  (only 1 uppercase)
    """
    if "_" in tok and (tok.count("_") >= 2 or len(tok) >= 8):
        tok = tok.replace("_", " ")
    upper = sum(1 for c in tok if c.isupper())
    if upper >= 3 and any(c.islower() for c in tok):
        # Insert space before each interior capital that follows a lower/digit.
        tok = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", tok)
        # Also handle ALLCAPS->Word transitions, e.g. XMLParser → XML Parser.
        tok = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", tok)
    return tok


def filter_text(text: str) -> str:
    """Strip Claude Code TUI chrome, code, diffs, prompts, markdown. Keep prose."""
    # ANSI escape codes
    text = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", text)
    text = re.sub(r"\x1b\][^\x07]*\x07", "", text)

    # Tool-permission prompts get replaced wholesale with a spoken description.
    perm = _describe_tool_permission(text)
    if perm is not None:
        return perm

    # Find Claude's last response: locate the LAST "⏺ <prose>" line that's actual
    # response text (not a tool call or tool summary). Take content from there onward.
    lines_raw = text.split("\n")
    _tool_verbs = {"searched", "read", "edited", "wrote", "created", "deleted",
                   "moved", "copied", "found", "listed", "ran", "executed",
                   "updated", "modified", "fetched", "checked"}
    last_response_idx = None
    for idx, line in enumerate(lines_raw):
        stripped = line.strip()
        if not stripped.startswith("⏺"):
            continue
        rest = stripped[1:].strip()
        if not rest:
            continue
        # Tool call pattern: "CapitalWord(...)" — skip
        if re.match(r"^[A-Z][A-Za-z]*\(", rest):
            continue
        # Tool summary pattern: "Searched for...", "Read N files", etc — skip
        first_word = rest.split(None, 1)[0].lower() if rest.split() else ""
        if first_word in _tool_verbs:
            continue
        # Looks like actual prose — remember this index
        last_response_idx = idx
    if last_response_idx is not None:
        text = "\n".join(lines_raw[last_response_idx:])

    # Fenced code blocks
    text = re.sub(r"```[^\n]*\n.*?```", "", text, flags=re.DOTALL)

    # Leading symbols that just decorate a response line — strip them, keep the text
    STRIP_SYMBOLS = "⏺●✻✳✢⚡⚠◆◇◈◉○◎◐◑◒◓⏵⏴▶◀►◄▲▼▸▹▾▿⟦⟧⌁⌂⌃⌄⌇✦✧✩✪✫✶✴✷✸✹✺✻★☆"
    # Leading symbols that mean "drop the whole line" (tool result output,
    # checklist items from TaskCreate/TodoWrite, etc.)
    DROP_LINE_SYMBOLS = "⎿⊢⊣⊤⊥✔✓✗◼◻◾◽"

    kept = []
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped:
            kept.append(line)
            continue

        # Lines starting with tool-result markers are dropped entirely
        if stripped[0] in DROP_LINE_SYMBOLS:
            continue

        # Strip any run of leading decoration symbols + whitespace, keep the text
        while stripped and stripped[0] in STRIP_SYMBOLS:
            stripped = stripped[1:].lstrip()
        if not stripped:
            continue

        # Box-drawing characters (TUI frames/separators)
        if any(0x2500 <= ord(c) <= 0x259F for c in stripped):
            continue

        # Tool call pattern (e.g. "Read(file.txt)", "Bash(ls)")
        if re.match(r"^[A-Z][A-Za-z]*\(", stripped):
            continue

        # Status line heuristic: contains middle-dot AND status keywords together
        low = stripped.lower()
        is_status = (
            "·" in stripped and (
                "tokens" in low or "context" in low or "shortcuts" in low
                or "esc to interrupt" in low or "bypass permissions" in low
            )
        )
        if is_status:
            continue
        if "? for shortcuts" in low:
            continue
        if "esc to interrupt" in low:
            continue
        # Thinking indicators — match "<Verb>ed/ing for <N>m/s" anywhere in line.
        # Works for Claude Code's "Thought for", "Cogitated for"/"Churned for", etc.
        if re.search(r"\b\w{4,}(ed|ing)\s+for\s+\d+\s*[mhs]", stripped):
            continue
        # Bare "-ing..." thinking indicators, optionally followed by a
        # parenthetical aside e.g. "Fiddle-faddling… (almost done thinking …)".
        if re.match(r"^[\w\-]{4,}ing\s*[…\.]+(\s*\([^)]*\))?\s*$", stripped):
            continue
        if re.match(r"^(thinking|pondering|mulling|musing|considering|cogitating|ruminating|crunching|working|processing|analyzing|churning|cogitated|churned|skedaddling)\b", low):
            continue

        # Compiler/build diagnostic prefixes (rustc / clang / gcc / cargo).
        # Catches "warning: unused import: …", "error: …", "note: …", "help: …".
        if re.match(r"^(warning|error|note|help)\s*:", low):
            continue
        # Cargo-style "unused …" continuations of the prior diagnostic.
        if re.match(r"^unused\s+(import|imports|variable|variables)\b", low):
            continue
        # rustc/clang code-context line: "118 | pub fn …", optionally with a
        # caret/squiggle annotation row like "    | ^^^^^".
        if re.match(r"^\s*\d{1,5}\s*\|", line):
            continue
        if re.match(r"^\s*\|", line) and ("^" in stripped or "~" in stripped):
            continue
        # git log --oneline: "037780a Wishlist: §41 volume KVO fix done…"
        if re.match(r"^[0-9a-f]{7,12}\s+\S", stripped):
            continue
        # HEREDOC delimiter lines: "<<EOF", "<<'EOF'", "<<-PYTHON".
        if re.match(r"^<<-?['\"]?\w+['\"]?\s*$", stripped):
            continue

        # Shell status: "N shells", "accept edits on · 3 shells"
        if re.search(r"\b\d+\s+shells?\b", low):
            continue
        if re.search(r"\bshells?\s+(still\s+)?running\b", low):
            continue

        # Claude Code footer keywords
        if any(kw in low for kw in (
            "auto-accept", "accept edits", "shift+tab", "⇧ tab", "yolo mode",
            "bypass permissions",
        )):
            continue

        # Claude Code tool summary lines
        # e.g. "Searched for 1 pattern, read 1 file (ctrl+o to expand)"
        # e.g. "Read 3 files" / "Edited file foo.py" / "Wrote file bar.md"
        if "ctrl+o to expand" in low or "ctrl+r to expand" in low or "to expand" in low:
            continue

        # Claude Code feedback prompt and numbered menus
        if "how is claude doing" in low:
            continue
        # Numbered menu option pattern: "1: X  2: Y  3: Z" (3+ numbered options on one line)
        if len(re.findall(r"\b\d+[:.]\s*\w", stripped)) >= 3:
            continue
        if re.match(r"^(searched|read|edited|wrote|created|deleted|moved|copied|found|listed|ran|executed|updated|modified)\s+(\d+|file|files|for|the|a|an)\b", low):
            continue

        # Task-list headers from TaskCreate/TodoWrite summaries
        # e.g. "7 tasks (2 done, 1 in progress, 4 open)"
        if re.match(r"^\d+\s+tasks?\s*\(\d+\s+(done|completed|in\s*progress|open|pending)", low):
            continue

        # tmux/terminal status bar pattern: contains multiple │ separators
        # e.g. "⟦ λ ⟧ │ [Opus 4.6 (1M context)] │ Quip │ ██░░░ 45% │ ..."
        if stripped.count("│") >= 2 or stripped.count("|") >= 3:
            continue
        # Percentage bar pattern like "██░░░ 45%"
        if re.search(r"[█▓▒░▌▐]{2,}", stripped):
            continue
        # Lines that are mostly model-info noise
        if re.search(r"\[(opus|sonnet|haiku)[\s\d.]+(\([^)]*\))?\]", low):
            continue

        # Input prompt indicators
        if stripped in (">", "> _"):
            continue
        if stripped.startswith("> ") and len(stripped) < 4:
            continue

        # Shell prompts
        if stripped[0] in ("➜", "❯", "»"):
            continue
        if re.match(r"^[\w.-]+@[\w.-]+[:\s]", stripped):
            continue
        if re.match(r"^[~/][\w./-]*\s*[%$#]\s*$", stripped):
            continue
        if stripped in ("$", "%", "#"):
            continue

        # Diff lines
        if stripped.startswith(("+++ ", "--- ", "@@ ")):
            continue
        # Line-numbered diff rows from Claude Code edit output:
        # "   113          # text" or "   109 +        # text" or "   115 -        # text"
        if re.match(r"^\s*\d{1,5}\s+[+\-]?\s", line):
            continue

        # Lone file path lines
        if re.match(r"^/?[\w./-]+\.\w+(:\d+)?$", stripped):
            continue

        # Indented code (4+ spaces with code-like patterns)
        if line.startswith("    ") or line.startswith("\t"):
            if re.search(r"[{}()]|=>|->|import |def |fn |class |let |var |const |function", stripped):
                continue

        kept.append(line)

    text = "\n".join(kept)

    # Markdown stripping
    text = re.sub(r"(?m)^#{1,6}\s+", "", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"\*(.+?)\*", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"(?m)^[\-\*]\s+", "", text)
    # Numbered list prefixes (allow leading whitespace)
    text = re.sub(r"(?m)^\s*\d+\.\s+", "", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = text.strip()

    # Unicode symbols → speakable replacements
    text = text.replace("→", " to ")
    text = text.replace("←", " from ")
    text = text.replace("—", ", ")
    text = text.replace("–", ", ")
    text = text.replace("…", "...")

    # Drop common code-file extensions: "main_window.rs" → "main_window".
    # Without this, the word.word transform below would emit "main_window rs"
    # and Kokoro would say "R S" — awkward in prose contexts.
    text = _CODE_EXT_RE.sub(r"\1", text)

    # Replace 7-12 char hex tokens (commit SHAs) with a spoken word so Kokoro
    # doesn't try to pronounce "037780a" letter by letter.
    text = _HEX_HASH_RE.sub("the commit", text)

    # Code-like patterns → natural speech:
    #   "dht.toArray()" → "dht toArray"
    #   "dht.table.toArray()" → "dht table toArray"
    # Match word.word chains optionally ending with ()
    text = re.sub(r"(\w+(?:\.\w+)+)\(\)", lambda m: m.group(1).replace(".", " "), text)
    text = re.sub(r"(\w+(?:\.\w+)+)", lambda m: m.group(1).replace(".", " ") if not re.match(r"^\d+(\.\d+)+$", m.group(1)) else m.group(1), text)
    # Remaining bare parentheses around empty args
    text = re.sub(r"\(\)", "", text)
    # Version numbers: "1.3.1" → "1 point 3 point 1"
    text = re.sub(r"\b(\d+)\.(\d+)(?:\.(\d+))?\b",
                  lambda m: m.group(1) + " point " + m.group(2) + (" point " + m.group(3) if m.group(3) else ""),
                  text)

    # Split CamelCase / snake_case identifiers so Kokoro pronounces them as
    # words instead of letter blobs. Limited to multi-word identifiers — single
    # English words are untouched because the helper gates on length and case
    # transitions.
    text = re.sub(r"\b[A-Za-z][A-Za-z0-9_]+\b",
                  lambda m: _split_identifier(m.group(0)), text)

    # Strip any remaining TTS-unfriendly symbols that Kokoro would read by name
    # (e.g. ⏺ → "record button", ⎿ → "bottom left corner", etc.)
    TTS_UNSPEAKABLE = "⏺⎿●✻✳✢◆◇◈◉○◎◐◑◒◓⏵⏴▶◀►◄▲▼▸▹▾▿⟦⟧⌁⌂⌃⌄⌇✦✧✩✪✫★☆═━─│┃"
    text = "".join(c if c not in TTS_UNSPEAKABLE else " " for c in text)
    # Collapse any extra whitespace and fix punctuation spacing
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    # Fix space-before-comma from symbol replacements (e.g. "fix , text" → "fix, text")
    text = re.sub(r" +,", ",", text)
    text = text.strip()

    # Cap total text at 1000 chars so we don't stream for minutes
    if len(text) > 1000:
        text = text[:1000].rsplit(" ", 1)[0]

    return text


def synth_to_wav_bytes(text: str, voice: str, speed: float, lang: str) -> bytes:
    """Run Kokoro synthesis and return WAV bytes."""
    try:
        from kokoro_onnx import Kokoro
    except ImportError:
        sys.stderr.write(
            "ERROR: kokoro-onnx not installed. Run:\n"
            "  ~/Library/Application\\ Support/Quip/venv/bin/pip install kokoro-onnx soundfile\n"
        )
        sys.exit(2)

    if not MODEL_PATH.exists() or not VOICES_PATH.exists():
        sys.stderr.write(
            f"ERROR: Kokoro model files not found at {VOICES_DIR}\n"
            f"Download them once:\n"
            f"  mkdir -p {VOICES_DIR}\n"
            f"  cd {VOICES_DIR}\n"
            f"  curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx\n"
            f"  curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin\n"
        )
        sys.exit(3)

    kokoro = Kokoro(str(MODEL_PATH), str(VOICES_PATH))
    samples, sample_rate = kokoro.create(text, voice=voice, speed=speed, lang=lang)

    # Convert float32 samples to 16-bit PCM WAV in memory
    import numpy as np
    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype(np.int16)

    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)  # 16-bit
        wf.setframerate(sample_rate)
        wf.writeframes(pcm.tobytes())
    return buf.getvalue()


def _get_kokoro():
    """Load Kokoro model once and cache it globally.
    Tries CoreML Execution Provider first (Apple Neural Engine / GPU),
    falls back to CPU if unavailable.
    """
    global _KOKORO
    try:
        return _KOKORO
    except NameError:
        pass
    try:
        from kokoro_onnx import Kokoro
        import onnxruntime as ort
    except ImportError:
        sys.stderr.write("ERROR: kokoro-onnx not installed\n")
        sys.exit(2)
    if not MODEL_PATH.exists() or not VOICES_PATH.exists():
        sys.stderr.write(f"ERROR: model files not found at {VOICES_DIR}\n")
        sys.exit(3)

    # Try CoreML first for Apple Silicon acceleration
    avail = ort.get_available_providers()
    providers = ["CoreMLExecutionProvider", "CPUExecutionProvider"] if "CoreMLExecutionProvider" in avail else ["CPUExecutionProvider"]

    # Newer kokoro-onnx accepts a `providers` kwarg; older versions don't
    try:
        _KOKORO = Kokoro(str(MODEL_PATH), str(VOICES_PATH), providers=providers)
        sys.stderr.write(f"kokoro loaded with providers={providers}\n")
    except TypeError:
        # Monkey-patch onnxruntime.InferenceSession to inject our providers
        _orig_session = ort.InferenceSession
        def _patched_session(path, *args, **kwargs):
            kwargs.setdefault("providers", providers)
            return _orig_session(path, *args, **kwargs)
        ort.InferenceSession = _patched_session
        try:
            _KOKORO = Kokoro(str(MODEL_PATH), str(VOICES_PATH))
            sys.stderr.write(f"kokoro loaded via monkey-patched providers={providers}\n")
        finally:
            ort.InferenceSession = _orig_session
    return _KOKORO


def _synth_with_cached(text: str, voice: str, speed: float, lang: str) -> bytes:
    import numpy as np
    kokoro = _get_kokoro()
    samples, sample_rate = kokoro.create(text, voice=voice, speed=speed, lang=lang)

    # Loudness: peak-normalize, then a gentle soft-knee instead of heavy
    # compression. The previous 3.5× tanh squashed the natural dynamic range
    # and was the main reason the voice sounded flat — this preserves
    # prosody while still landing close to full scale.
    peak = float(np.abs(samples).max()) if samples.size else 0.0
    if peak > 1e-6:
        samples = samples * (0.95 / peak)  # peak normalize to near-full
    samples = np.tanh(samples * 1.6) * 0.95

    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm.tobytes())
    return buf.getvalue()


def _add_prosody_hints(text: str) -> str:
    """Insert commas at natural pause points to help Kokoro breathe.
    Adds pauses before conjunctions and after introductory phrases."""
    # Add comma before conjunctions when missing (but not if already punctuated)
    text = re.sub(r"(?<=[a-z]) (but|however|although|though|since|because|so that|which means) ",
                  r", \1 ", text)
    # Add comma after common introductory words at start of clause
    text = re.sub(r"(?:^|(?<=\. ))(Also|Additionally|However|Meanwhile|Finally|Overall|Instead|Basically|Essentially) ",
                  r"\1, ", text)
    # Parenthetical asides: "text (aside) more" → "text, aside, more". Helps
    # Kokoro breathe around interjections instead of barreling through.
    # Cap aside length so we don't fold long parentheses onto the main clause.
    text = re.sub(r"\s*\(([^()\n]{2,80})\)\s*", r", \1, ", text)
    # Collapse double-commas the substitution may have created.
    text = re.sub(r",(\s*,)+", ",", text)
    return text


# Chunk size limits for streaming synthesis. Kokoro's prosody improves with
# longer inputs, so we use a generous 250-char cap for everything *except* the
# very first chunk, which we keep short to minimize first-audio latency.
_CHUNK_MAX_CHARS = 250
_FIRST_CHUNK_MAX_CHARS = 80


def _split_sentences(text: str):
    """Split text into sentences for streaming synthesis.

    Strategy:
      * 250-char cap on every chunk for better Kokoro prosody than the old 150.
      * First chunk is force-split to ≤ 80 chars so first-audio latency stays
        roughly the same as before — subsequent chunks overlap with playback.
      * Each chunk gets terminal punctuation if it lacks any, since Kokoro
        inflects ends-of-sentence downward, which sounds more natural.
    """
    text = _add_prosody_hints(text)

    # Split on newlines first — each line is a natural thought/clause
    lines = [l.strip() for l in text.strip().split("\n") if l.strip()]

    # Then split each line on sentence boundaries (.!?) but NOT after "digit."
    parts = []
    for line in lines:
        parts.extend(re.split(r"(?<=[.!?])(?<!\d\.)\s+", line))

    # Then split long parts at clause boundaries (semicolons, colons, dashes)
    clause_split = []
    for p in parts:
        if len(p) > _CHUNK_MAX_CHARS:
            # Split at semicolons, colons, em-dashes, and " - " as clause boundaries
            sub = re.split(r"(?<=[;:])\s+|(?<=,)\s+(?=and |or |but |so |yet )|(?:\s+-\s+)", p)
            clause_split.extend(s.strip() for s in sub if s.strip())
        else:
            clause_split.append(p)

    # Merge very short fragments with neighbors to avoid choppy playback
    merged = []
    for p in clause_split:
        p = p.strip()
        if not p:
            continue
        if merged and (len(merged[-1]) < 25 or len(p) < 12):
            merged[-1] = merged[-1] + " " + p
        else:
            merged.append(p)

    # Break up anything still over the cap at comma boundaries
    final = []
    for p in merged:
        while len(p) > _CHUNK_MAX_CHARS:
            cut = p.rfind(", ", 60, _CHUNK_MAX_CHARS)
            if cut < 40:
                cut = p.rfind(" ", 100, _CHUNK_MAX_CHARS)
            if cut < 40:
                cut = _CHUNK_MAX_CHARS
            final.append(p[:cut].strip())
            p = p[cut:].strip()
            # Strip leading comma from remainder
            if p.startswith(", "):
                p = p[2:]
        if p:
            final.append(p)

    # Force-split the first chunk if it's longer than _FIRST_CHUNK_MAX_CHARS:
    # take the first sentence boundary, comma, or word boundary we can find.
    # This keeps first-audio fast even though the cap above is larger.
    if final and len(final[0]) > _FIRST_CHUNK_MAX_CHARS:
        first = final[0]
        cut = first.find(". ", 30, _FIRST_CHUNK_MAX_CHARS)
        if cut < 0:
            cut = first.rfind(", ", 30, _FIRST_CHUNK_MAX_CHARS)
        if cut < 0:
            cut = first.rfind(" ", 30, _FIRST_CHUNK_MAX_CHARS)
        if cut < 0:
            cut = _FIRST_CHUNK_MAX_CHARS
        head = first[:cut + 1].strip().rstrip(",")
        tail = first[cut + 1:].strip()
        final = [head] + ([tail] if tail else []) + final[1:]

    # Ensure each chunk ends with terminal punctuation so Kokoro inflects down.
    final = [(c if c[-1:] in ".!?,;:" else c + ".") for c in final if c]

    return final


def _daemon_loop(voice: str, speed: float, lang: str):
    """Streaming request/response loop over stdin/stdout.

    Request:  <4-byte big-endian length><UTF-8 text>
    Response: stream of <4-byte length><WAV bytes> chunks, terminated by <4-byte 0>.
              Each chunk is one sentence's synthesis. Length=0 means end-of-stream.
    """
    import struct
    _get_kokoro()
    sys.stderr.write("READY\n")
    sys.stderr.flush()

    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    while True:
        hdr = stdin.read(4)
        if not hdr or len(hdr) < 4:
            return
        n = struct.unpack(">I", hdr)[0]
        if n == 0:
            continue
        raw = stdin.read(n).decode("utf-8", errors="replace")

        text = filter_text(raw)

        # Debug log
        try:
            with open("/tmp/quip-kokoro-filter.log", "a") as f:
                f.write(f"--- {len(raw)}->{len(text)} ---\n")
                f.write(f"RAW: {raw!r}\n")
                f.write(f"FILTERED: {text!r}\n\n")
        except Exception:
            pass

        if not text:
            stdout.write(struct.pack(">I", 0))  # end-of-stream, no chunks
            stdout.flush()
            continue

        # Split into sentences and stream each one as it finishes synth
        sentences = _split_sentences(text)
        for sent in sentences:
            try:
                wav = _synth_with_cached(sent, voice, speed, lang)
            except Exception as e:
                sys.stderr.write(f"synth error on '{sent[:40]}...': {e}\n")
                sys.stderr.flush()
                continue
            stdout.write(struct.pack(">I", len(wav)))
            stdout.write(wav)
            stdout.flush()  # Critical — flush after each chunk so Swift gets it immediately

        # End-of-stream marker
        stdout.write(struct.pack(">I", 0))
        stdout.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--text", help="Text to synthesize (otherwise reads stdin)")
    parser.add_argument("--voice", default=DEFAULT_VOICE)
    parser.add_argument("--speed", type=float, default=DEFAULT_SPEED)
    parser.add_argument("--lang", default=DEFAULT_LANG)
    parser.add_argument("--no-filter", action="store_true")
    parser.add_argument("--daemon", action="store_true", help="Length-prefixed stdin/stdout loop")
    args = parser.parse_args()

    if args.daemon:
        _daemon_loop(args.voice, args.speed, args.lang)
        return

    # One-shot mode (used for testing)
    if args.text is not None:
        raw = args.text
    else:
        raw = sys.stdin.read()
    text = raw.strip() if args.no_filter else filter_text(raw)
    if not text:
        sys.exit(1)
    wav_bytes = synth_to_wav_bytes(text, args.voice, args.speed, args.lang)
    sys.stdout.buffer.write(wav_bytes)


if __name__ == "__main__":
    main()
