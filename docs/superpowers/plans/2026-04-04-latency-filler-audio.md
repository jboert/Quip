# Latency Filler Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add phone-side filler audio (non-verbal ambient sounds + Kokoro-voiced "hold on" phrases) to QuipiOS that starts instantly when the user releases PTT and stops cleanly when Claude's real response begins playing — masking the dead-air gap during thinking/tool-use latency.

**Architecture:** Four focused Swift files under `QuipiOS/Services/Filler/`. A `FillerController` state machine subscribes to the existing `HardwareButtonHandler.onPTTStop` event and a new `SpeechService.onFirstAudioChunk` event. It drives a `FillerPlayer` (real `AVAudioPlayer` wrapper, behind a `FillerAudioPlaying` protocol for testability) which plays from a `FillerAssetLibrary` pool of pre-synthesized WAV files bundled in `QuipiOS/Resources/FillerAudio/`. An offline Python script hits the existing Mac-side Kokoro daemon script to generate the phrase WAVs.

**Tech Stack:** Swift 6 / SwiftUI / AVFoundation / XCTest / Kokoro TTS (via existing `kokoro_tts.py --text` one-shot mode)

**Spec:** `docs/superpowers/specs/2026-04-04-latency-filler-audio-design.md`

## Build System Note

The QuipiOS project is generated from `QuipiOS/project.yml` via `xcodegen`. The project uses `sources: - path: .` which picks up new files by file-system walk, but the generated `QuipiOS.xcodeproj/project.pbxproj` must be regenerated any time you add or remove a file. **Before every `xcodebuild` call in this plan, first run:**

```bash
(cd QuipiOS && xcodegen generate)
```

Each task that adds new files includes this step explicitly.

---

## File Structure

**New files:**
- `QuipiOS/Services/Filler/FillerAssetLibrary.swift` — owns the two audio-file pools, random selection with anti-repetition
- `QuipiOS/Services/Filler/FillerAudioPlaying.swift` — `FillerAudioPlaying` protocol + `StopMode` enum (test seam)
- `QuipiOS/Services/Filler/FillerPlayer.swift` — real `AVAudioPlayer` implementation of `FillerAudioPlaying`, handles ducking and smart cut
- `QuipiOS/Services/Filler/FillerController.swift` — state machine, timers, event handlers
- `QuipiOS/Resources/FillerAudio/spoken/` — 25 bundled WAV files for spoken phrases
- `QuipiOS/Resources/FillerAudio/ambient/` — ~10-15 bundled WAV files for ambient clips
- `QuipiOS/Resources/FillerAudio/manifest.json` — lists files by category so the library doesn't have to hardcode filenames
- `scripts/generate_filler_audio.sh` — regenerates the spoken + Kokoro-voiced ambient WAVs
- `QuipiOS/Tests/FillerAssetLibraryTests.swift`
- `QuipiOS/Tests/FillerControllerTests.swift`
- `QuipiOS/Tests/FakeFillerPlayer.swift` — test double

**Modified files:**
- `QuipiOS/Services/SpeechService.swift` — add `onFirstAudioChunk: (() -> Void)?` callback, fire from first `playNextChunk()` of a new session
- `QuipiOS/QuipApp.swift` — instantiate `FillerController`, wire it to `HardwareButtonHandler.onPTTStop` and `speech.onFirstAudioChunk`
- `QuipiOS/project.yml` — ensure `Resources/FillerAudio/**` is included in the bundle (it should be by default since `sources: - path: .` includes everything not excluded, but we'll verify)

**Note on directory split:** A `Filler/` subfolder under `Services/` keeps the new four files together without polluting the flat `Services/` list. The project uses `createIntermediateGroups: true` so subfolders show up in Xcode automatically.

---

## Task 1: Scaffold FillerAudio resource directory and manifest

**Files:**
- Create: `QuipiOS/Resources/FillerAudio/spoken/.gitkeep`
- Create: `QuipiOS/Resources/FillerAudio/ambient/.gitkeep`
- Create: `QuipiOS/Resources/FillerAudio/manifest.json`

- [ ] **Step 1: Create the directory skeleton**

```bash
mkdir -p QuipiOS/Resources/FillerAudio/spoken
mkdir -p QuipiOS/Resources/FillerAudio/ambient
touch QuipiOS/Resources/FillerAudio/spoken/.gitkeep
touch QuipiOS/Resources/FillerAudio/ambient/.gitkeep
```

- [ ] **Step 2: Write the manifest**

Create `QuipiOS/Resources/FillerAudio/manifest.json` with the complete phrase map. This lets `FillerAssetLibrary` load files by category without hardcoding names in Swift:

```json
{
  "spoken": {
    "initial_short": [
      { "file": "initial_short_01.wav", "text": "Hmm..." },
      { "file": "initial_short_02.wav", "text": "Let's see..." },
      { "file": "initial_short_03.wav", "text": "Okay..." },
      { "file": "initial_short_04.wav", "text": "Right..." },
      { "file": "initial_short_05.wav", "text": "One sec..." }
    ],
    "initial_medium": [
      { "file": "initial_medium_01.wav", "text": "Hold on a sec." },
      { "file": "initial_medium_02.wav", "text": "Let me check." },
      { "file": "initial_medium_03.wav", "text": "Give me a moment." },
      { "file": "initial_medium_04.wav", "text": "Let me think." },
      { "file": "initial_medium_05.wav", "text": "Bear with me." },
      { "file": "initial_medium_06.wav", "text": "Working on it." },
      { "file": "initial_medium_07.wav", "text": "Looking into it." }
    ],
    "initial_long": [
      { "file": "initial_long_01.wav", "text": "Hold on, let me check on that." },
      { "file": "initial_long_02.wav", "text": "Give me just a second here." },
      { "file": "initial_long_03.wav", "text": "Let me take a look at that." },
      { "file": "initial_long_04.wav", "text": "Alright, let me figure this out." },
      { "file": "initial_long_05.wav", "text": "Hmm, let me think about that for a second." }
    ],
    "continuation": [
      { "file": "continuation_01.wav", "text": "Still checking..." },
      { "file": "continuation_02.wav", "text": "Almost there..." },
      { "file": "continuation_03.wav", "text": "Just a moment more." },
      { "file": "continuation_04.wav", "text": "Working on it..." },
      { "file": "continuation_05.wav", "text": "Still looking." }
    ],
    "error": [
      { "file": "error_01.wav", "text": "Hmm, something's not quite right. Try again?" },
      { "file": "error_02.wav", "text": "I'm having trouble here, give it another shot." },
      { "file": "error_03.wav", "text": "Something's off — try me again." }
    ]
  },
  "ambient_voice": [
    { "file": "ambient_voice_01.wav", "text": "Mm." },
    { "file": "ambient_voice_02.wav", "text": "Mmhm." },
    { "file": "ambient_voice_03.wav", "text": "Uh..." },
    { "file": "ambient_voice_04.wav", "text": "Ah." },
    { "file": "ambient_voice_05.wav", "text": "Hmmm." }
  ],
  "ambient_typing": [
    { "file": "ambient_typing_01.wav", "source": "stock" },
    { "file": "ambient_typing_02.wav", "source": "stock" },
    { "file": "ambient_typing_03.wav", "source": "stock" }
  ]
}
```

- [ ] **Step 3: Commit**

```bash
git add QuipiOS/Resources/FillerAudio/
git commit -m "Put up the shelves in the back room for them hold-music audio files"
```

---

## Task 2: Write the filler audio generator script

**Files:**
- Create: `scripts/generate_filler_audio.sh`

This script reads `manifest.json`, calls the existing `kokoro_tts.py` one-shot mode for every entry that has a `text` field, and writes the resulting WAV files into `QuipiOS/Resources/FillerAudio/spoken/` and `ambient/`. Stock typing samples are NOT generated here — they must be manually sourced and dropped in (see Task 3).

- [ ] **Step 1: Write the script**

Create `scripts/generate_filler_audio.sh`:

```bash
#!/bin/bash
# Regenerates filler audio WAV files from the manifest by hitting the existing
# Kokoro TTS one-shot mode. Run from the repo root.
#
# Prereqs: the Kokoro venv and model files must already be installed per the
# QuipMac setup (see QuipMac/Services/KokoroTTS.swift header comment).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/QuipiOS/Resources/FillerAudio/manifest.json"
SPOKEN_DIR="$REPO_ROOT/QuipiOS/Resources/FillerAudio/spoken"
AMBIENT_DIR="$REPO_ROOT/QuipiOS/Resources/FillerAudio/ambient"
KOKORO_SCRIPT="$REPO_ROOT/QuipMac/Resources/kokoro_tts.py"
VENV_PYTHON="$HOME/Library/Application Support/Quip/venv/bin/python3"
VOICE="af_heart"

if [ ! -f "$MANIFEST" ]; then
    echo "Manifest not found: $MANIFEST" >&2
    exit 1
fi

if [ ! -x "$VENV_PYTHON" ]; then
    echo "Kokoro venv python not found at: $VENV_PYTHON" >&2
    echo "Install per QuipMac/Services/KokoroTTS.swift setup instructions." >&2
    exit 1
fi

if [ ! -f "$KOKORO_SCRIPT" ]; then
    echo "Kokoro script not found: $KOKORO_SCRIPT" >&2
    exit 1
fi

gen() {
    local text="$1"
    local out="$2"
    echo "  -> $out"
    "$VENV_PYTHON" "$KOKORO_SCRIPT" --voice "$VOICE" --text "$text" > "$out"
    if [ ! -s "$out" ]; then
        echo "ERROR: generated file is empty: $out" >&2
        exit 1
    fi
}

# Spoken categories
for category in initial_short initial_medium initial_long continuation error; do
    echo "Generating spoken/$category..."
    count=$(python3 -c "import json; print(len(json.load(open('$MANIFEST'))['spoken']['$category']))")
    for ((i=0; i<count; i++)); do
        file=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['spoken']['$category'][$i]['file'])")
        text=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['spoken']['$category'][$i]['text'])")
        gen "$text" "$SPOKEN_DIR/$file"
    done
done

# Kokoro-voiced ambient clips
echo "Generating ambient_voice..."
count=$(python3 -c "import json; print(len(json.load(open('$MANIFEST'))['ambient_voice']))")
for ((i=0; i<count; i++)); do
    file=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['ambient_voice'][$i]['file'])")
    text=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['ambient_voice'][$i]['text'])")
    gen "$text" "$AMBIENT_DIR/$file"
done

echo ""
echo "Done. Stock typing samples (ambient_typing_*.wav) must be sourced manually"
echo "and placed in: $AMBIENT_DIR"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/generate_filler_audio.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/generate_filler_audio.sh
git commit -m "Wrote a little helper script that cranks out all them hold-music clips in one go"
```

---

## Task 3: Generate the audio files (manual run + stock typing)

**Files:**
- Generated: `QuipiOS/Resources/FillerAudio/spoken/*.wav` (25 files)
- Generated: `QuipiOS/Resources/FillerAudio/ambient/ambient_voice_*.wav` (5 files)
- Manual: `QuipiOS/Resources/FillerAudio/ambient/ambient_typing_{01,02,03}.wav`

- [ ] **Step 1: Run the generator**

```bash
./scripts/generate_filler_audio.sh
```

Expected output: logs "Generating..." for each category, then "Done." at the end. Verify:

```bash
ls QuipiOS/Resources/FillerAudio/spoken/ | wc -l
# Expected: 25 (plus .gitkeep = 26)
ls QuipiOS/Resources/FillerAudio/ambient/ambient_voice_*.wav | wc -l
# Expected: 5
```

- [ ] **Step 2: Source stock typing samples**

Find or record 3 short (1-2 second) quiet keyboard typing loops in WAV format. Good sources: freesound.org (CC0), macOS built-in sound effects, or record from any mechanical keyboard with QuickTime. They must be:
- WAV format (AVAudioPlayer plays WAV natively)
- Mono or stereo, 44.1 kHz
- 1-2 seconds long
- Quiet — will be mixed at ~30% volume

Save as:
- `QuipiOS/Resources/FillerAudio/ambient/ambient_typing_01.wav`
- `QuipiOS/Resources/FillerAudio/ambient/ambient_typing_02.wav`
- `QuipiOS/Resources/FillerAudio/ambient/ambient_typing_03.wav`

- [ ] **Step 3: Spot-check a few files audibly**

```bash
afplay QuipiOS/Resources/FillerAudio/spoken/initial_long_01.wav
afplay QuipiOS/Resources/FillerAudio/ambient/ambient_voice_01.wav
afplay QuipiOS/Resources/FillerAudio/ambient/ambient_typing_01.wav
```

Verify: spoken phrase sounds natural in Claude's voice, ambient "mm" sounds like same speaker, typing sounds mechanical and quiet.

- [ ] **Step 4: Commit the generated files**

```bash
git add QuipiOS/Resources/FillerAudio/spoken/ QuipiOS/Resources/FillerAudio/ambient/
git commit -m "Pressed a whole batch of them hold-music records and stacked em in the closet"
```

---

## Task 4: FillerAssetLibrary — tests first

**Files:**
- Create: `QuipiOS/Tests/FillerAssetLibraryTests.swift`

`FillerAssetLibrary` loads `manifest.json` from the bundle, exposes per-category random selection, and tracks last-picked index per pool to avoid repeats.

- [ ] **Step 1: Write the failing tests**

Create `QuipiOS/Tests/FillerAssetLibraryTests.swift`:

```swift
import XCTest
@testable import QuipiOS

@MainActor
final class FillerAssetLibraryTests: XCTestCase {

    func testLoadsManifestFromBundle() {
        let library = FillerAssetLibrary()
        XCTAssertTrue(library.isLoaded, "Library should load manifest.json from bundle on init")
    }

    func testRandomPhraseReturnsValidURLForEachCategory() {
        let library = FillerAssetLibrary()
        for category in FillerPhraseCategory.allCases {
            let url = library.randomPhrase(category: category)
            XCTAssertNotNil(url, "Expected a URL for \(category)")
            if let url {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                              "File must exist on disk: \(url.path)")
            }
        }
    }

    func testRandomAmbientReturnsValidURL() {
        let library = FillerAssetLibrary()
        let url = library.randomAmbient()
        XCTAssertNotNil(url)
        if let url {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testAntiRepetitionSpokenPhrases() {
        let library = FillerAssetLibrary()
        // initial_short has 5 entries; pull 50 times and verify no two consecutive are equal
        var last: URL?
        for _ in 0..<50 {
            let url = library.randomPhrase(category: .initialShort)
            XCTAssertNotNil(url)
            if let url, let last {
                XCTAssertNotEqual(url, last, "Consecutive picks must differ")
            }
            last = url
        }
    }

    func testAntiRepetitionAmbient() {
        let library = FillerAssetLibrary()
        var last: URL?
        for _ in 0..<50 {
            let url = library.randomAmbient()
            XCTAssertNotNil(url)
            if let url, let last {
                XCTAssertNotEqual(url, last)
            }
            last = url
        }
    }

    func testInitialCategoryWeightsTowardLonger() {
        let library = FillerAssetLibrary()
        // .initialWeighted should return from initial_short/medium/long with bias to long
        var longCount = 0
        let total = 400
        for _ in 0..<total {
            if let url = library.randomPhrase(category: .initialWeighted),
               url.lastPathComponent.hasPrefix("initial_long_") {
                longCount += 1
            }
        }
        // Weight is 1/1/2 short/medium/long → long ~= 50%. Allow wide margin.
        XCTAssertGreaterThan(longCount, total / 3, "Long phrases should be biased higher")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:QuipiOSTests/FillerAssetLibraryTests 2>&1 | tail -30
```

Expected: compile failure — `FillerAssetLibrary`, `FillerPhraseCategory` not defined.

- [ ] **Step 3: Implement `FillerAssetLibrary`**

Create `QuipiOS/Services/Filler/FillerAssetLibrary.swift`:

```swift
import Foundation

/// Categories for spoken filler phrases. `.initialWeighted` picks from short/medium/long
/// with weight 1/1/2 so longer phrases fire more often on the first trigger (buying more time).
enum FillerPhraseCategory: CaseIterable {
    case initialShort
    case initialMedium
    case initialLong
    case initialWeighted
    case continuation
    case error

    static var allCases: [FillerPhraseCategory] {
        [.initialShort, .initialMedium, .initialLong, .initialWeighted, .continuation, .error]
    }
}

/// Loads filler audio manifest from the bundle and picks random files per category
/// with anti-repetition (never returns the same URL twice in a row per pool).
@MainActor
final class FillerAssetLibrary {

    private struct Manifest: Decodable {
        let spoken: [String: [Entry]]
        let ambient_voice: [Entry]
        let ambient_typing: [Entry]
    }

    private struct Entry: Decodable {
        let file: String
    }

    private let spokenByCategory: [String: [URL]]
    private let ambientURLs: [URL]

    /// Last-picked index per pool key (category name or "ambient") for anti-repetition.
    private var lastPickedIndex: [String: Int] = [:]

    private(set) var isLoaded: Bool = false

    init() {
        guard let manifestURL = Bundle.main.url(forResource: "manifest",
                                                 withExtension: "json",
                                                 subdirectory: "FillerAudio"),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            self.spokenByCategory = [:]
            self.ambientURLs = []
            return
        }

        let spokenDir = manifestURL.deletingLastPathComponent().appendingPathComponent("spoken")
        let ambientDir = manifestURL.deletingLastPathComponent().appendingPathComponent("ambient")

        var spoken: [String: [URL]] = [:]
        for (key, entries) in manifest.spoken {
            spoken[key] = entries.map { spokenDir.appendingPathComponent($0.file) }
        }
        self.spokenByCategory = spoken

        let voice = manifest.ambient_voice.map { ambientDir.appendingPathComponent($0.file) }
        let typing = manifest.ambient_typing.map { ambientDir.appendingPathComponent($0.file) }
        self.ambientURLs = voice + typing

        self.isLoaded = !spoken.isEmpty && !self.ambientURLs.isEmpty
    }

    func randomPhrase(category: FillerPhraseCategory) -> URL? {
        switch category {
        case .initialShort:     return pick(from: spokenByCategory["initial_short"] ?? [], poolKey: "initial_short")
        case .initialMedium:    return pick(from: spokenByCategory["initial_medium"] ?? [], poolKey: "initial_medium")
        case .initialLong:      return pick(from: spokenByCategory["initial_long"] ?? [], poolKey: "initial_long")
        case .continuation:     return pick(from: spokenByCategory["continuation"] ?? [], poolKey: "continuation")
        case .error:            return pick(from: spokenByCategory["error"] ?? [], poolKey: "error")
        case .initialWeighted:
            // 1/1/2 weight — build a virtual pool
            let short = spokenByCategory["initial_short"] ?? []
            let medium = spokenByCategory["initial_medium"] ?? []
            let long = spokenByCategory["initial_long"] ?? []
            let weighted = short + medium + long + long
            return pick(from: weighted, poolKey: "initial_weighted")
        }
    }

    func randomAmbient() -> URL? {
        pick(from: ambientURLs, poolKey: "ambient")
    }

    private func pick(from pool: [URL], poolKey: String) -> URL? {
        guard !pool.isEmpty else { return nil }
        if pool.count == 1 { return pool[0] }
        let lastIdx = lastPickedIndex[poolKey] ?? -1
        var idx = Int.random(in: 0..<pool.count)
        if idx == lastIdx {
            idx = (idx + 1) % pool.count
        }
        lastPickedIndex[poolKey] = idx
        return pool[idx]
    }
}
```

- [ ] **Step 4: Ensure bundle resources are wired**

Check that `project.yml` already includes `Resources/FillerAudio/**` in the bundle. The current `sources: - path: .` block picks up everything under the project directory except the listed excludes, so new files under `Resources/FillerAudio/` should be included automatically. Verify by regenerating the project:

```bash
cd QuipiOS && xcodegen generate && cd ..
```

Expected: no errors, and the generated `QuipiOS.xcodeproj/project.pbxproj` references the new WAV files and `manifest.json`.

If the manifest doesn't end up in the bundle as a blue-folder reference (preserving the `FillerAudio` subdirectory), add this to `project.yml` under the `QuipiOS` target's `sources:`:

```yaml
      - path: Resources/FillerAudio
        type: folder
```

Then regenerate.

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:QuipiOSTests/FillerAssetLibraryTests 2>&1 | tail -30
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add QuipiOS/Services/Filler/FillerAssetLibrary.swift QuipiOS/Tests/FillerAssetLibraryTests.swift QuipiOS/project.yml QuipiOS/QuipiOS.xcodeproj
git commit -m "Taught the app how to pick a random record off the hold-music shelf without playing the same one twice in a row"
```

---

## Task 5: Define the FillerAudioPlaying protocol and StopMode

**Files:**
- Create: `QuipiOS/Services/Filler/FillerAudioPlaying.swift`

This is the seam that lets `FillerController` be unit-tested with a fake. No tests for this file itself — it's just a protocol.

- [ ] **Step 1: Write the protocol**

Create `QuipiOS/Services/Filler/FillerAudioPlaying.swift`:

```swift
import Foundation

/// How to stop the filler tracks when Claude's real audio arrives.
enum FillerStopMode {
    /// Hard cut, zero fade. Used for ambient track (it's just noise).
    case hardCut
    /// Let current word finish (~150-300ms) then fade over 150ms. Used for spoken track
    /// so the interruption doesn't slice a word in half.
    case fadeOut
}

/// Abstraction over the filler audio playback layer. Real impl is `FillerPlayer`
/// (wraps two AVAudioPlayers). Tests use `FakeFillerPlayer`.
@MainActor
protocol FillerAudioPlaying: AnyObject {
    /// Start looping ambient clips continuously.
    func startAmbient()

    /// Stop the ambient track.
    func stopAmbient()

    /// Play a single spoken phrase on the spoken track. Automatically ducks ambient
    /// to ~30% volume for the duration, restores when the phrase finishes.
    func playPhrase(url: URL)

    /// Stop both tracks. Ambient is always hard-cut. Spoken uses the given mode.
    func stopAll(spokenMode: FillerStopMode)
}
```

- [ ] **Step 2: Commit**

```bash
git add QuipiOS/Services/Filler/FillerAudioPlaying.swift
git commit -m "Drew up the blueprint for the hold-music jukebox so I can fake one for the tests"
```

---

## Task 6: FakeFillerPlayer test double

**Files:**
- Create: `QuipiOS/Tests/FakeFillerPlayer.swift`

- [ ] **Step 1: Write the fake**

Create `QuipiOS/Tests/FakeFillerPlayer.swift`:

```swift
import Foundation
@testable import QuipiOS

/// Test double that records all calls for assertion in FillerController tests.
/// No real audio — just an event log.
@MainActor
final class FakeFillerPlayer: FillerAudioPlaying {

    enum Event: Equatable {
        case startAmbient
        case stopAmbient
        case playPhrase(URL)
        case stopAll(FillerStopMode)
    }

    private(set) var events: [Event] = []

    func startAmbient() { events.append(.startAmbient) }
    func stopAmbient() { events.append(.stopAmbient) }
    func playPhrase(url: URL) { events.append(.playPhrase(url)) }
    func stopAll(spokenMode: FillerStopMode) { events.append(.stopAll(spokenMode)) }

    func reset() { events.removeAll() }
}
```

Note: `FillerStopMode` is an enum without associated values, so Swift synthesizes `Equatable` automatically. `FakeFillerPlayer.Event` gets synthesized `Equatable` too because all associated types (`URL`, `FillerStopMode`) are Equatable.

- [ ] **Step 2: Regenerate project and verify it compiles**

```bash
(cd QuipiOS && xcodegen generate)
xcodebuild build-for-testing -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add QuipiOS/Tests/FakeFillerPlayer.swift QuipiOS/QuipiOS.xcodeproj
git commit -m "Built me a wooden-dummy jukebox for the test bench — writes down every button it gets pressed"
```

(Note: `FillerAudioPlaying.swift` was committed in Task 5 as a source-only change; this commit includes the regenerated `.xcodeproj` that now references both `FillerAudioPlaying.swift` and `FakeFillerPlayer.swift`.)

---

## Task 7: FillerController state machine — tests first

**Files:**
- Create: `QuipiOS/Tests/FillerControllerTests.swift`

The controller is the brain: timers, state transitions, event handlers. Tests inject `FakeFillerPlayer` and a controllable clock so no real time passes.

- [ ] **Step 1: Write the failing tests**

Create `QuipiOS/Tests/FillerControllerTests.swift`:

```swift
import XCTest
@testable import QuipiOS

@MainActor
final class FillerControllerTests: XCTestCase {

    // MARK: - Test clock

    /// Injectable clock for deterministic timer tests.
    final class TestClock: FillerClock {
        private(set) var now: TimeInterval = 0
        private var scheduled: [(deadline: TimeInterval, id: UUID, fire: () -> Void)] = []

        func scheduleAfter(_ interval: TimeInterval, handler: @escaping () -> Void) -> UUID {
            let id = UUID()
            scheduled.append((now + interval, id, handler))
            return id
        }

        func cancel(_ id: UUID) {
            scheduled.removeAll { $0.id == id }
        }

        func advance(by seconds: TimeInterval) {
            now += seconds
            // Fire any due timers in order
            while let next = scheduled.first(where: { $0.deadline <= now }) {
                scheduled.removeAll { $0.id == next.id }
                next.fire()
            }
        }
    }

    // MARK: - Helpers

    private func makeController() -> (FillerController, FakeFillerPlayer, TestClock, FillerAssetLibrary) {
        let player = FakeFillerPlayer()
        let clock = TestClock()
        let library = FillerAssetLibrary()
        let controller = FillerController(player: player, library: library, clock: clock)
        return (controller, player, clock, library)
    }

    // MARK: - Fast path

    func testFastPathStartsAmbientAndStopsOnFirstAudio() {
        let (controller, player, clock, _) = makeController()

        controller.onPTTReleased()
        XCTAssertEqual(player.events, [.startAmbient])

        clock.advance(by: 0.4)
        controller.onFirstRealAudioChunk()

        XCTAssertEqual(player.events, [.startAmbient, .stopAll(.hardCut)])
    }

    // MARK: - Slow path: initial phrase fires at 2s

    func testInitialPhraseFiresAfterTwoSeconds() {
        let (controller, player, clock, _) = makeController()

        controller.onPTTReleased()
        clock.advance(by: 1.9)
        XCTAssertEqual(player.events, [.startAmbient], "Phrase should not have fired yet")

        clock.advance(by: 0.2) // now at 2.1s
        XCTAssertEqual(player.events.count, 2)
        if case .playPhrase = player.events[1] {} else {
            XCTFail("Expected playPhrase, got \(player.events[1])")
        }
    }

    // MARK: - Slow path: recurrence fires ~3.5s after initial

    func testRecurrenceFires() {
        let (controller, player, clock, _) = makeController()
        controller.onPTTReleased()
        clock.advance(by: 2.0) // initial phrase fires
        clock.advance(by: 3.5) // recurrence fires

        let phraseCount = player.events.filter { if case .playPhrase = $0 { return true }; return false }.count
        XCTAssertEqual(phraseCount, 2, "Expected initial + one recurrence")
    }

    // MARK: - 20s hard cap fires error phrase

    func testErrorCapAtTwentySeconds() {
        let (controller, player, clock, _) = makeController()
        controller.onPTTReleased()
        clock.advance(by: 20.0)

        // Should have fired the error phrase somewhere in here
        let phrases = player.events.compactMap { event -> URL? in
            if case .playPhrase(let url) = event { return url }
            return nil
        }
        let errorFired = phrases.contains { $0.lastPathComponent.hasPrefix("error_") }
        XCTAssertTrue(errorFired, "Expected an error phrase by 20s. Got phrases: \(phrases.map { $0.lastPathComponent })")
    }

    // MARK: - First audio chunk cancels pending timer

    func testFirstAudioChunkBeforeTwoSecondsCancelsPhraseTimer() {
        let (controller, player, clock, _) = makeController()
        controller.onPTTReleased()
        clock.advance(by: 1.0)
        controller.onFirstRealAudioChunk()
        clock.advance(by: 5.0) // would have fired by now

        let phraseCount = player.events.filter { if case .playPhrase = $0 { return true }; return false }.count
        XCTAssertEqual(phraseCount, 0, "No phrase should fire after cancellation")
    }

    // MARK: - PTT pressed again while filler playing resets state

    func testPTTPressedDuringFillerResets() {
        let (controller, player, clock, _) = makeController()
        controller.onPTTReleased()
        clock.advance(by: 2.5) // initial phrase has fired
        player.reset()

        controller.onPTTPressed()
        XCTAssertEqual(player.events, [.stopAll(.hardCut)])
    }

    // MARK: - Audio session interruption stops everything

    func testAudioSessionInterruptionStopsAll() {
        let (controller, player, clock, _) = makeController()
        controller.onPTTReleased()
        clock.advance(by: 0.5)
        player.reset()

        controller.onAudioSessionInterrupted()
        XCTAssertEqual(player.events, [.stopAll(.hardCut)])

        // And no further phrases should fire
        clock.advance(by: 10.0)
        XCTAssertEqual(player.events, [.stopAll(.hardCut)])
    }

    // MARK: - Stop mode is fadeOut when spoken was playing, hardCut when only ambient

    func testStopModeFadeOutIfSpokenIsActive() {
        let (controller, player, clock, _) = makeController()
        controller.onPTTReleased()
        clock.advance(by: 2.5) // initial phrase has fired — assume still playing
        player.reset()

        controller.onFirstRealAudioChunk()
        XCTAssertEqual(player.events, [.stopAll(.fadeOut)])
    }

    func testStopModeHardCutIfOnlyAmbientActive() {
        let (controller, player, clock, _) = makeController()
        controller.onPTTReleased()
        clock.advance(by: 0.5)
        player.reset()

        controller.onFirstRealAudioChunk()
        XCTAssertEqual(player.events, [.stopAll(.hardCut)])
    }
}
```

- [ ] **Step 2: Regenerate project and run tests to verify they fail**

```bash
(cd QuipiOS && xcodegen generate)
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:QuipiOSTests/FillerControllerTests 2>&1 | tail -30
```

Expected: compile failure — `FillerController`, `FillerClock` not defined.

- [ ] **Step 3: Implement `FillerClock` and `FillerController`**

Create `QuipiOS/Services/Filler/FillerController.swift`:

```swift
import Foundation

/// Clock abstraction so FillerController's timers can be unit-tested with a virtual clock.
@MainActor
protocol FillerClock {
    /// Schedule a handler to run after `interval` seconds. Returns a cancellation token.
    func scheduleAfter(_ interval: TimeInterval, handler: @escaping () -> Void) -> UUID
    func cancel(_ id: UUID)
}

/// Real-clock implementation using DispatchQueue.main.
@MainActor
final class DispatchFillerClock: FillerClock {
    private var tokens: [UUID: DispatchWorkItem] = [:]

    func scheduleAfter(_ interval: TimeInterval, handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        let work = DispatchWorkItem { [weak self] in
            self?.tokens.removeValue(forKey: id)
            handler()
        }
        tokens[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
        return id
    }

    func cancel(_ id: UUID) {
        tokens[id]?.cancel()
        tokens.removeValue(forKey: id)
    }
}

/// State machine that decides when to play filler audio between PTT release and
/// Claude's first real audio chunk. Drives a FillerAudioPlaying (real or fake).
///
/// Timing:
///   - PTT release → startAmbient immediately, arm 2.0s phrase timer
///   - 2.0s elapsed, no real audio → play initial phrase, arm 3.5s recurrence timer
///   - Every 3.5s after → play continuation phrase
///   - 20.0s total → play error phrase, reset state
///   - First real audio chunk → stopAll (fadeOut if spoken active, hardCut otherwise)
@MainActor
final class FillerController {

    private let player: FillerAudioPlaying
    private let library: FillerAssetLibrary
    private let clock: FillerClock

    // Timing constants
    static let initialPhraseDelay: TimeInterval = 2.0
    static let recurrenceInterval: TimeInterval = 3.5
    static let errorCap: TimeInterval = 20.0

    // State
    private var isFilling = false
    private var spokenPhraseActive = false
    private var startedAt: TimeInterval = 0
    private var phraseTimerId: UUID?
    private var errorCapTimerId: UUID?

    /// Approximate last-phrase duration so we know when the spoken track is idle again.
    /// We don't have a finish callback from the fake, so controller tracks it by time.
    /// For simplicity here, we treat spokenPhraseActive as true from the moment we fire
    /// a phrase until the next event (good enough for stop-mode decision making).
    init(player: FillerAudioPlaying, library: FillerAssetLibrary, clock: FillerClock) {
        self.player = player
        self.library = library
        self.clock = clock
    }

    // MARK: - Events

    func onPTTReleased() {
        cancelAllTimers()
        isFilling = true
        spokenPhraseActive = false
        player.startAmbient()

        phraseTimerId = clock.scheduleAfter(Self.initialPhraseDelay) { [weak self] in
            self?.fireInitialPhrase()
        }
        errorCapTimerId = clock.scheduleAfter(Self.errorCap) { [weak self] in
            self?.fireErrorPhrase()
        }
    }

    func onFirstRealAudioChunk() {
        guard isFilling else { return }
        let mode: FillerStopMode = spokenPhraseActive ? .fadeOut : .hardCut
        stopAndReset(mode: mode)
    }

    func onPTTPressed() {
        guard isFilling else { return }
        stopAndReset(mode: .hardCut)
    }

    func onAudioSessionInterrupted() {
        guard isFilling else { return }
        stopAndReset(mode: .hardCut)
    }

    // MARK: - Internal transitions

    private func fireInitialPhrase() {
        guard isFilling else { return }
        if let url = library.randomPhrase(category: .initialWeighted) {
            player.playPhrase(url: url)
            spokenPhraseActive = true
        }
        phraseTimerId = clock.scheduleAfter(Self.recurrenceInterval) { [weak self] in
            self?.fireRecurrence()
        }
    }

    private func fireRecurrence() {
        guard isFilling else { return }
        if let url = library.randomPhrase(category: .continuation) {
            player.playPhrase(url: url)
            spokenPhraseActive = true
        }
        phraseTimerId = clock.scheduleAfter(Self.recurrenceInterval) { [weak self] in
            self?.fireRecurrence()
        }
    }

    private func fireErrorPhrase() {
        guard isFilling else { return }
        if let url = library.randomPhrase(category: .error) {
            player.playPhrase(url: url)
            spokenPhraseActive = true
        }
        // After the error phrase, stop filling entirely.
        if let id = phraseTimerId { clock.cancel(id); phraseTimerId = nil }
    }

    private func stopAndReset(mode: FillerStopMode) {
        player.stopAll(spokenMode: mode)
        cancelAllTimers()
        isFilling = false
        spokenPhraseActive = false
    }

    private func cancelAllTimers() {
        if let id = phraseTimerId { clock.cancel(id); phraseTimerId = nil }
        if let id = errorCapTimerId { clock.cancel(id); errorCapTimerId = nil }
    }
}
```

- [ ] **Step 4: Regenerate project and run tests to verify they pass**

```bash
(cd QuipiOS && xcodegen generate)
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:QuipiOSTests/FillerControllerTests 2>&1 | tail -40
```

Expected: all 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Services/Filler/FillerController.swift QuipiOS/Tests/FillerControllerTests.swift QuipiOS/QuipiOS.xcodeproj
git commit -m "The hold-music brain knows when to drop the needle and when to pick it back up"
```

---

## Task 8: FillerPlayer — real AVAudioPlayer implementation

**Files:**
- Create: `QuipiOS/Services/Filler/FillerPlayer.swift`

Real playback using two `AVAudioPlayer` instances — one for ambient (looped), one for spoken. Handles ducking (ambient volume drops while spoken plays) and smart cut (ambient hard-stops, spoken fades).

Unit-testing real `AVAudioPlayer` is tricky (needs real audio hardware/session). We test this component via the manual on-device checklist (Task 11), not XCTest. The protocol seam makes this acceptable — `FillerController` is fully tested with the fake.

- [ ] **Step 1: Write the implementation**

Create `QuipiOS/Services/Filler/FillerPlayer.swift`:

```swift
import AVFoundation

/// Real implementation of FillerAudioPlaying using two AVAudioPlayer instances.
///
/// - Ambient track: loops continuously; the library picks the next clip when the
///   current one finishes. Ducks to 30% while a spoken phrase is playing.
/// - Spoken track: one-shot per phrase. On fadeOut stop, fades over 150ms.
@MainActor
final class FillerPlayer: NSObject, FillerAudioPlaying {

    private let library: FillerAssetLibrary

    private var ambientPlayer: AVAudioPlayer?
    private var spokenPlayer: AVAudioPlayer?
    private var ambientDelegate: AmbientLoopDelegate?
    private var spokenDelegate: SpokenFinishDelegate?

    private static let ambientNormalVolume: Float = 0.7
    private static let ambientDuckedVolume: Float = 0.3  // ~30% per spec
    private static let fadeOutDuration: TimeInterval = 0.15

    init(library: FillerAssetLibrary) {
        self.library = library
        super.init()
    }

    // MARK: - FillerAudioPlaying

    func startAmbient() {
        stopAmbient()
        guard let url = library.randomAmbient() else { return }
        playAmbient(url: url)
    }

    func stopAmbient() {
        ambientPlayer?.stop()
        ambientPlayer = nil
        ambientDelegate = nil
    }

    func playPhrase(url: URL) {
        // Duck ambient
        ambientPlayer?.volume = Self.ambientDuckedVolume

        // Stop any in-flight spoken phrase instantly
        spokenPlayer?.stop()
        spokenPlayer = nil
        spokenDelegate = nil

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = SpokenFinishDelegate { [weak self] in
                guard let self else { return }
                self.spokenPlayer = nil
                self.spokenDelegate = nil
                // Restore ambient volume
                self.ambientPlayer?.volume = Self.ambientNormalVolume
            }
            self.spokenDelegate = delegate
            player.delegate = delegate
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            self.spokenPlayer = player
        } catch {
            NSLog("[Quip] FillerPlayer failed to play phrase: %@", error.localizedDescription)
            ambientPlayer?.volume = Self.ambientNormalVolume
        }
    }

    func stopAll(spokenMode: FillerStopMode) {
        // Ambient: always hard cut
        stopAmbient()

        // Spoken: hard cut or fade
        guard let spoken = spokenPlayer else { return }
        switch spokenMode {
        case .hardCut:
            spoken.stop()
            spokenPlayer = nil
            spokenDelegate = nil
        case .fadeOut:
            spoken.setVolume(0.0, fadeDuration: Self.fadeOutDuration)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOutDuration) { [weak self] in
                self?.spokenPlayer?.stop()
                self?.spokenPlayer = nil
                self?.spokenDelegate = nil
            }
        }
    }

    // MARK: - Ambient looping

    private func playAmbient(url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = AmbientLoopDelegate { [weak self] in
                guard let self else { return }
                // Pick next random ambient clip and keep going
                if let next = self.library.randomAmbient() {
                    self.playAmbient(url: next)
                }
            }
            self.ambientDelegate = delegate
            player.delegate = delegate
            player.volume = Self.ambientNormalVolume
            player.prepareToPlay()
            player.play()
            self.ambientPlayer = player
        } catch {
            NSLog("[Quip] FillerPlayer failed to play ambient: %@", error.localizedDescription)
        }
    }
}

private final class AmbientLoopDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}

private final class SpokenFinishDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
```

- [ ] **Step 2: Regenerate project and verify it builds**

```bash
(cd QuipiOS && xcodegen generate)
xcodebuild build -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add QuipiOS/Services/Filler/FillerPlayer.swift QuipiOS/QuipiOS.xcodeproj
git commit -m "Dropped the real jukebox into the back room — one turntable for the background hum, another for when it's gotta actually say something"
```

---

## Task 9: Add onFirstAudioChunk callback to SpeechService

**Files:**
- Modify: `QuipiOS/Services/SpeechService.swift`

Add a callback that fires exactly once per session — the first time `playNextChunk()` actually plays something after a new `sessionId` arrives. This is the signal `FillerController` needs to stop the filler.

- [ ] **Step 1: Add a test for the new callback**

Add to `QuipiOS/Tests/PTTStressTests.swift` (or create `QuipiOS/Tests/SpeechServiceTests.swift` if preferred). For consistency with existing test layout, create a new file:

Create `QuipiOS/Tests/SpeechServiceTests.swift`:

```swift
import XCTest
@testable import QuipiOS

@MainActor
final class SpeechServiceTests: XCTestCase {

    func testOnFirstAudioChunkFiresOnceForNewSession() {
        let speech = SpeechService()
        var fireCount = 0
        speech.onFirstAudioChunk = { fireCount += 1 }

        // Empty data triggers the final-marker path and doesn't enqueue — skip those
        let sampleWAV = Self.makeSilentWAV()

        speech.enqueueAudio(sampleWAV, sessionId: "session-A", isFinal: false)
        XCTAssertEqual(fireCount, 1, "First chunk of new session should fire callback")

        speech.enqueueAudio(sampleWAV, sessionId: "session-A", isFinal: false)
        XCTAssertEqual(fireCount, 1, "Subsequent chunks of same session should not re-fire")

        speech.enqueueAudio(sampleWAV, sessionId: "session-B", isFinal: false)
        XCTAssertEqual(fireCount, 2, "New session should fire again")
    }

    /// Build a minimal valid WAV (44.1 kHz mono, 100 samples of silence) so AVAudioPlayer
    /// init won't throw. We don't actually care about the audio — just the control flow.
    static func makeSilentWAV() -> Data {
        let sampleRate: UInt32 = 44100
        let sampleCount: UInt32 = 100
        let dataSize = sampleCount * 2 // 16-bit mono
        let fileSize = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Data($0) })
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // mono
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) }) // block align
        data.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) }) // bits
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        data.append(Data(count: Int(dataSize))) // silence
        return data
    }
}
```

- [ ] **Step 2: Regenerate project and run the test to verify it fails**

```bash
(cd QuipiOS && xcodegen generate)
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:QuipiOSTests/SpeechServiceTests 2>&1 | tail -20
```

Expected: compile failure — `onFirstAudioChunk` not a member of `SpeechService`.

- [ ] **Step 3: Modify SpeechService**

Edit `QuipiOS/Services/SpeechService.swift`:

Add a new property after line 24 (`@ObservationIgnored private var currentSessionId: String?`):

```swift
    /// Fires exactly once per session — the first time a chunk arrives for a new sessionId.
    /// Used by FillerController to know when Claude's real audio is starting.
    @ObservationIgnored var onFirstAudioChunk: (() -> Void)?

    @ObservationIgnored private var firstChunkFiredForSession: String?
```

Modify `enqueueAudio(_:sessionId:isFinal:)` to fire the callback. Replace the existing function body:

```swift
    func enqueueAudio(_ data: Data, sessionId: String, isFinal: Bool) {
        guard !isRecording else { return }

        // New session? Drop everything and start fresh.
        if sessionId != currentSessionId {
            stopSpeaking()
            currentSessionId = sessionId
        }

        // Final-marker messages arrive with empty audio — just signal no more chunks coming
        if !data.isEmpty {
            // Fire first-chunk callback exactly once per session, before enqueueing,
            // so the controller can stop filler audio before real playback begins.
            if firstChunkFiredForSession != sessionId {
                firstChunkFiredForSession = sessionId
                onFirstAudioChunk?()
            }

            audioQueue.append(data)
            if audioPlayer == nil {
                playNextChunk()
            }
        }
    }
```

Also reset `firstChunkFiredForSession` in `stopSpeaking()`. Edit `stopSpeaking()`:

```swift
    func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
        playerDelegate = nil
        audioQueue.removeAll()
        currentSessionId = nil
        firstChunkFiredForSession = nil
        isSpeaking = false
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:QuipiOSTests/SpeechServiceTests 2>&1 | tail -20
```

Expected: test passes.

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Services/SpeechService.swift QuipiOS/Tests/SpeechServiceTests.swift QuipiOS/QuipiOS.xcodeproj
git commit -m "The speech doohickey now rings a bell the exact second it's got a fresh batch from Claude to play"
```

---

## Task 10: Wire FillerController in QuipApp and add audio session interruption observer

**Files:**
- Modify: `QuipiOS/QuipApp.swift`
- Modify: `QuipiOS/Services/Filler/FillerController.swift` (add interruption observer helper)

- [ ] **Step 1: Add audio session interruption observer to FillerController**

Edit `QuipiOS/Services/Filler/FillerController.swift`. Add this method to the `FillerController` class:

```swift
    /// Install an observer that calls `onAudioSessionInterrupted()` when the iOS audio
    /// session is interrupted (phone call, Siri, etc.). Call once during app setup.
    func installAudioSessionObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            if type == .began {
                Task { @MainActor [weak self] in
                    self?.onAudioSessionInterrupted()
                }
            }
        }
    }
```

Add `import AVFoundation` at the top of the file if not already present.

- [ ] **Step 2: Wire the controller in QuipApp**

Edit `QuipiOS/QuipApp.swift`:

After line 19 (`@State private var bonjourBrowser = BonjourBrowser()`), add a lazy-initialized filler controller. Because it depends on a library and player, initialize it in `setup()` rather than as a `@State` default. Add:

```swift
    @State private var fillerController: FillerController?
```

Then at the top of `setup()`, after `speech.requestAuthorization()` (line 61), add:

```swift
        // Initialize filler audio controller
        let fillerLibrary = FillerAssetLibrary()
        if fillerLibrary.isLoaded {
            let fillerPlayer = FillerPlayer(library: fillerLibrary)
            let controller = FillerController(
                player: fillerPlayer,
                library: fillerLibrary,
                clock: DispatchFillerClock()
            )
            controller.installAudioSessionObserver()
            self.fillerController = controller

            // Fire filler-stop when Claude's real audio starts
            speech.onFirstAudioChunk = { [weak controller] in
                controller?.onFirstRealAudioChunk()
            }
        } else {
            NSLog("[Quip] FillerAssetLibrary failed to load — filler audio disabled")
        }
```

Then modify the existing `volumeHandler.onPTTStart` closure (line 150) to notify the controller:

```swift
        volumeHandler.onPTTStart = { [self] in
            DispatchQueue.main.async {
                fillerController?.onPTTPressed()
                startRecording()
            }
        }
```

And modify `volumeHandler.onPTTStop` (line 154):

```swift
        volumeHandler.onPTTStop = { [self] in
            DispatchQueue.main.async {
                stopRecording()
                // Only start filler if TTS is enabled (same gate as onTTSAudio)
                if ttsEnabled {
                    fillerController?.onPTTReleased()
                }
            }
        }
```

Note: `[self]` capture in these closures is fine because `QuipApp` is a struct and the closures capture by value. The existing code already does this pattern.

- [ ] **Step 3: Regenerate project and verify it builds**

```bash
(cd QuipiOS && xcodegen generate)
xcodebuild build -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -30
```

Expected: BUILD SUCCEEDED. If there are Swift 6 strict-concurrency warnings on the closures, resolve them by wrapping closure bodies in `Task { @MainActor in ... }` or adjusting `[self]` captures — follow the same pattern already used elsewhere in `setup()` (e.g., lines 63-84 in the pre-edit QuipApp.swift).

- [ ] **Step 4: Run the full test suite to verify nothing regressed**

```bash
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -40
```

Expected: all tests pass (FillerAssetLibraryTests, FillerControllerTests, SpeechServiceTests, PTTStressTests, MessageProtocolTests).

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/QuipApp.swift QuipiOS/Services/Filler/FillerController.swift
git commit -m "Hooked the hold-music brain up to the PTT button and told it to listen for when a phone call barges in"
```

---

## Task 11: Manual on-device verification

**Files:** none (manual testing checklist)

Unit tests cover the state machine and the asset library, but the *feel* of filler audio can only be judged on a real device with real latency.

- [ ] **Step 1: Build and install on device**

Follow the iOS Build & Deploy memory notes:

```bash
# Build, sign, and install to the test iPhone
# (See ios_build_deploy.md in memory for the exact commands)
```

- [ ] **Step 2: Verify fast path — quick response**

1. Connect to Mac, enable TTS in settings.
2. Hold PTT, say "what is two plus two", release.
3. **Expected:** Ambient "hmm" / typing starts instantly on release. Claude's response starts within ~1s. Ambient hard-cuts cleanly when Claude starts.
4. **Fail criteria:** Noticeable delay between PTT release and ambient start; ambient audibly clicks or pops when cut.

- [ ] **Step 3: Verify slow path — tool use**

1. Hold PTT, say "read the file at path /etc/hosts and tell me what's in it", release.
2. **Expected:** Ambient starts instantly. At ~2s, a spoken phrase fires ("hold on, let me check on that..."). Ambient ducks while spoken plays. If tool use drags past ~5.5s, a continuation phrase fires ("still checking..."). When Claude's real audio arrives, the spoken filler fades out over ~150ms and real audio begins.
3. **Fail criteria:** Spoken phrase sounds robotic; interruption cuts a word in half; ambient doesn't duck; recurrence timing feels off.

- [ ] **Step 4: Verify PTT repress resets cleanly**

1. Hold PTT, say "tell me a story", release.
2. While filler is playing (before Claude responds), hold PTT again and say "never mind", release.
3. **Expected:** Filler cuts immediately on PTT press. New filler cycle starts on the second release.

- [ ] **Step 5: Verify audio session interruption**

1. Hold PTT, ask a slow question that'll fire filler.
2. While filler is playing, trigger Siri (long-press side button).
3. **Expected:** Filler stops immediately. After dismissing Siri, the session recovers normally (no stuck state).

- [ ] **Step 6: Verify error cap at 20s**

1. Put the Mac in airplane mode mid-response, or kill the back-shop process, to create a hang.
2. Hold PTT, ask anything, release.
3. **Expected:** At ~20s, an error phrase fires ("Hmm, something's not quite right. Try again?"). Filler stops after.

- [ ] **Step 7: Verify TTS disabled path**

1. Turn off TTS in the app settings.
2. Hold PTT, release.
3. **Expected:** No filler audio. No errors. Filler should only fire when TTS is enabled.

- [ ] **Step 8: Document results**

If any check fails, file a follow-up task before merging. If all pass, proceed to final commit.

- [ ] **Step 9: Final commit (if any tuning fixes made)**

```bash
git add -A
git commit -m "Tuned up the hold-music timing till it felt right in the hand"
```

---

## Verification Summary

After all tasks complete:

```bash
# All tests pass
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -20

# Project structure check
find QuipiOS/Services/Filler -type f
find QuipiOS/Resources/FillerAudio -type f | sort
```

Expected file listing:
```
QuipiOS/Services/Filler/FillerAssetLibrary.swift
QuipiOS/Services/Filler/FillerAudioPlaying.swift
QuipiOS/Services/Filler/FillerController.swift
QuipiOS/Services/Filler/FillerPlayer.swift

QuipiOS/Resources/FillerAudio/ambient/ambient_typing_01.wav
QuipiOS/Resources/FillerAudio/ambient/ambient_typing_02.wav
QuipiOS/Resources/FillerAudio/ambient/ambient_typing_03.wav
QuipiOS/Resources/FillerAudio/ambient/ambient_voice_01.wav
... (5 ambient_voice files total)
QuipiOS/Resources/FillerAudio/manifest.json
QuipiOS/Resources/FillerAudio/spoken/continuation_01.wav
... (5 continuation files)
QuipiOS/Resources/FillerAudio/spoken/error_01.wav
... (3 error files)
QuipiOS/Resources/FillerAudio/spoken/initial_long_01.wav
... (5 initial_long files)
QuipiOS/Resources/FillerAudio/spoken/initial_medium_01.wav
... (7 initial_medium files)
QuipiOS/Resources/FillerAudio/spoken/initial_short_01.wav
... (5 initial_short files)
```

Total: 25 spoken + 8 ambient = 33 WAV files + manifest.json.
