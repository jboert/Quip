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


def filter_text(text: str) -> str:
    """Strip Claude Code TUI chrome, code, diffs, prompts, markdown. Keep prose."""
    # ANSI escape codes
    text = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", text)
    text = re.sub(r"\x1b\][^\x07]*\x07", "", text)

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
        # Bare "-ing..." thinking indicators (e.g., "Skedaddling…", "Pondering...")
        if re.match(r"^\w{4,}ing\s*[…\.]{1,3}\s*$", stripped):
            continue
        if re.match(r"^(thinking|pondering|mulling|musing|considering|cogitating|ruminating|crunching|working|processing|analyzing|churning|cogitated|churned|skedaddling)\b", low):
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

    # Loudness boost: peak-normalize then soft-clip with tanh for extra perceived loudness.
    # Kokoro's raw output is quiet (~0.3 peak); this gets it much louder without
    # harsh clipping. tanh acts as a smooth compressor on peaks.
    peak = float(np.abs(samples).max()) if samples.size else 0.0
    if peak > 1e-6:
        samples = samples * (0.95 / peak)  # peak normalize to near-full
    # Apply soft compression/limiting — higher gain lifts quieter content
    # (tanh naturally limits peaks, so no harsh clipping even at 3.5x)
    samples = np.tanh(samples * 3.5) * 0.98

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
    return text


def _split_sentences(text: str):
    """Split text into sentences for streaming synthesis.
    Keeps chunks short (under 150 chars) for better prosody — Kokoro sounds
    more natural with shorter inputs that represent single thoughts.
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
        if len(p) > 150:
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

    # Break up anything still over 150 chars at comma boundaries
    final = []
    for p in merged:
        while len(p) > 150:
            cut = p.rfind(", ", 60, 150)
            if cut < 40:
                cut = p.rfind(" ", 100, 150)
            if cut < 40:
                cut = 150
            final.append(p[:cut].strip())
            p = p[cut:].strip()
            # Strip leading comma from remainder
            if p.startswith(", "):
                p = p[2:]
        if p:
            final.append(p)
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
