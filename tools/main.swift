import Foundation

// Foundation-only assertion harness for the Shared multi-select logic
// (NumberedPromptDetector checked/cursor state + MultiSelectSync diff/keystrokes).
// Compiled with the Shared sources by tools/run-multiselect-tests.sh — no Xcode,
// simulator, or code signing needed. Exits non-zero on any failed assertion.

var failures = 0
var checks = 0

func check(_ cond: Bool, _ label: String) {
    checks += 1
    if cond {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

func eq<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    checks += 1
    if got == want {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)  got=\(got) want=\(want)")
    }
}

// The real screenshot content: options 1 & 2 rendered [✓] (Recommended), 3 & 4
// rendered [ ], cursor › on option 2, with an interactive nav/confirm footer.
let screenshot = """
Which files should I clean up?

  1. [✓] config.cache  (Recommended)
› 2. [✓] build.artifacts  (Recommended)
  3. [ ] logs.txt
  4. [ ] user.data

↑/↓ to navigate · space to toggle · Enter to confirm
"""

// A markdown task list scrolled in the buffer under a heading — checkbox shape
// but NO choice cue, so detect(in:) must return nil.
let taskList = """
## Progress
1. [x] Write the detector
2. [ ] Wire the injector
3. [ ] Celebrate

Plenty more prose follows here.
And still more output after that.
"""

let noPrompt = """
Just some ordinary terminal output.
Nothing to pick here at all.
"""

// MARK: - US-001 — checkedOptions + cursorOption

print("US-001: checkedOptions + cursorOption")
eq(NumberedPromptDetector.checkedOptions(in: screenshot), Set([1, 2]),
   "screenshot checkedOptions == {1,2}")
eq(NumberedPromptDetector.cursorOption(in: screenshot), 2,
   "screenshot cursorOption == 2")
eq(NumberedPromptDetector.detect(in: screenshot).map { Set($0) }, Set([1, 2, 3, 4]),
   "screenshot detect == [1,2,3,4]")
check(NumberedPromptDetector.isMultiSelect(in: screenshot),
      "screenshot isMultiSelect")

check(NumberedPromptDetector.detect(in: taskList) == nil,
      "task list detect == nil (no choice cue)")
eq(NumberedPromptDetector.checkedOptions(in: taskList), Set<Int>(),
   "task list checkedOptions == {} (matches detect == nil)")

check(NumberedPromptDetector.detect(in: noPrompt) == nil,
      "no-prompt detect == nil")
eq(NumberedPromptDetector.checkedOptions(in: noPrompt), Set<Int>(),
   "no-prompt checkedOptions == {}")
check(NumberedPromptDetector.cursorOption(in: noPrompt) == nil,
      "no-prompt cursorOption == nil")

print("US-002: togglesToReach")
eq(MultiSelectSync.togglesToReach(desired: Set([1, 2]), from: Set([1, 2])), [],
   "already-correct pre-checked set needs zero toggles")
eq(MultiSelectSync.togglesToReach(desired: Set([3]), from: Set([1, 2])), [1, 2, 3],
   "turn off 1 & 2, turn on 3")
eq(MultiSelectSync.togglesToReach(desired: Set([1, 2, 3]), from: Set([1, 2])), [3],
   "keep pre-checked, add one")
eq(MultiSelectSync.togglesToReach(desired: Set<Int>(), from: Set<Int>()), [],
   "empty desired from empty current == []")
eq(MultiSelectSync.togglesToReach(desired: Set([2, 4]), from: Set([1, 2, 3])), [1, 3, 4],
   "mixed diff returns ascending symmetric difference")

print("US-003: keystrokes")
// A submit ALWAYS confirms with Return — even when nothing needs toggling.
eq(MultiSelectSync.keystrokes(desired: Set([1, 2]), liveContent: screenshot), ["return"],
   "desired equals live checked set => just Return (confirm), never empty")
// Add 3 (below the cursor): walk down to it, toggle, confirm.
eq(MultiSelectSync.keystrokes(desired: Set([1, 2, 3]), liveContent: screenshot),
   ["down", "space", "return"],
   "cursor 2 + {1,2} pre-checked, add 3 => down to 3, space, return")
// Replace with {3}: option 1 is ABOVE the cursor (2) so the walk must go UP,
// not clamp to zero — the old down-only code toggled the wrong rows.
eq(MultiSelectSync.keystrokes(desired: Set([3]), liveContent: screenshot),
   ["up", "space", "down", "space", "down", "space", "return"],
   "desired {3}: up to 1, down to 2, down to 3 — toggle each, then return")
let ks = MultiSelectSync.keystrokes(desired: Set([3]), liveContent: screenshot)
check(ks.allSatisfy { ["up", "down", "space", "return"].contains($0) },
      "keystrokes only ever emit up/down/space/return")

// H3 — assert the RESULTING widget state, not just the key array. Replay the
// keys against a model widget (cursor + checked set) and confirm the final
// checked set equals the desired set. This is what actually proves correctness;
// the old array-only checks blessed a buggy sequence.
func replay(_ keys: [String], startCursor: Int, checked: Set<Int>, optionCount: Int) -> Set<Int> {
    var cur = startCursor
    var set = checked
    for k in keys {
        switch k {
        case "down":   cur = min(optionCount, cur + 1)
        case "up":     cur = max(1, cur - 1)
        case "space":  if set.contains(cur) { set.remove(cur) } else { set.insert(cur) }
        case "return": break
        default:       break
        }
    }
    return set
}
// screenshot: cursor starts on option 2, {1,2} pre-checked, 4 options.
for desired in [Set([1, 2]), Set([1, 2, 3]), Set([3]), Set([2, 4]), Set([1, 3, 4])] {
    let keys = MultiSelectSync.keystrokes(desired: desired, liveContent: screenshot)
    let final = replay(keys, startCursor: 2, checked: Set([1, 2]), optionCount: 4)
    eq(final, desired, "replay reaches desired \(desired.sorted()) from pre-checked {1,2} cursor@2")
}

print("US-005: initialPicks")
eq(MultiSelectSync.initialPicks(liveContent: screenshot), Set([1, 2]),
   "screenshot initialPicks == {1,2} (seed from pre-checked boxes)")
eq(MultiSelectSync.initialPicks(liveContent: noPrompt), Set<Int>(),
   "no-checked content initialPicks == {}")
eq(MultiSelectSync.initialPicks(liveContent: taskList), Set<Int>(),
   "task list (no choice cue) initialPicks == {}")

// MARK: - Live Claude Code widget (captured 2026-08-03, Claude Code v2.1.220)

// Verbatim capture of a REAL AskUserQuestion multi-select, read straight off an
// iTerm2 session (trailing spaces stripped; every detector collapses whitespace).
// The fixtures above were hand-written and got three things wrong that this one
// gets right, each of which broke multi-select on a device:
//   • the checked box renders `[✔]` (U+2714), not `[✓]` / `[x]`
//   • options carry description lines between them
//   • the widget commits via an unnumbered "Submit" ROW — Return on an option
//     row TOGGLES that option (footer: "Enter to select"), it does not submit.
let liveWidget = """
←  ☒ Fruit  ✔ Submit  →

Which fruits do you want?

❯ 1. [✔] Apple
  Crisp, common, keeps well.
  2. [ ] Banana
  Soft, sweet, no peel tools needed.
  3. [ ] Cherry
  Small, tart-sweet, has pits.
  4. [ ] Durian
  Strong smell, custard texture, divisive.
  5. [ ] Type something
     Submit
──────────────────────────────────────────────
  6. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""

// The review step the widget shows after Submit. The Mac presses Return again
// only when it can SEE this screen.
let liveConfirm = """
Review your answers

 ● Which fruits do you want?
   → Apple, Cherry

Ready to submit your answers?

❯ 1. Submit answers
  2. Cancel
"""

print("Live widget: detection")
eq(NumberedPromptDetector.detect(in: liveWidget).map { Set($0) }, Set([1, 2, 3, 4, 5]),
   "live widget detect == [1...5] (description lines don't split the run)")
eq(NumberedPromptDetector.checkedOptions(in: liveWidget), Set([1]),
   "live widget checkedOptions == {1} — `[✔]` U+2714 counts as checked")
eq(NumberedPromptDetector.cursorOption(in: liveWidget), 1,
   "live widget cursorOption == 1")
check(NumberedPromptDetector.isMultiSelect(in: liveWidget),
      "live widget isMultiSelect")
check(NumberedPromptDetector.isInteractiveMultiSelect(in: liveWidget),
      "live widget isInteractiveMultiSelect")
check(NumberedPromptDetector.hasSubmitRow(in: liveWidget),
      "live widget hasSubmitRow (unnumbered Submit under option 5)")
check(!NumberedPromptDetector.hasSubmitRow(in: screenshot),
      "plain dialect has no Submit row — Return still confirms in place")
check(!NumberedPromptDetector.isSubmitConfirmPrompt(in: liveWidget),
      "widget screen is not the confirm step")
check(NumberedPromptDetector.isSubmitConfirmPrompt(in: liveConfirm),
      "review screen is the confirm step (cursor on 'Submit answers')")

// The blank padding a terminal returns below the last painted row pushes the
// prompt out of the detector's trailing scan window entirely. This is why the
// Mac trims it at the single read choke point (KeystrokeInjector.readContent) —
// without that, EVERY fingerprint re-validation fails and answers are dropped
// as "Prompt changed — not sent".
let paddedWidget = liveWidget + String(repeating: "\n", count: 30)
check(NumberedPromptDetector.detect(in: paddedWidget) == nil,
      "blank-padded content detects nothing — readContent MUST trim it")

print("Live widget: keystrokes")
// Verified live: from cursor 1 with {1} checked, desired {1,3} walks to 3,
// toggles it, then walks past option 5 onto Submit and confirms. Injecting this
// exact sequence into the real widget produced "→ Apple, Cherry".
eq(MultiSelectSync.keystrokes(desired: Set([1, 3]), liveContent: liveWidget),
   ["down", "down", "space", "down", "down", "down", "return"],
   "live widget {1,3}: toggle 3, then walk to Submit and Return")
// Even a no-op diff must still reach Submit — the old code's bare Return would
// have toggled option 1 back OFF and left the prompt open.
eq(MultiSelectSync.keystrokes(desired: Set([1]), liveContent: liveWidget),
   ["down", "down", "down", "down", "down", "return"],
   "live widget no-op diff still walks to Submit (bare Return would untoggle)")

// Replay against a model of the REAL widget: Return on an option row toggles;
// only Return on the Submit row (one past the last option) commits.
func replayLive(_ keys: [String], startCursor: Int, checked: Set<Int>,
                optionCount: Int) -> (checked: Set<Int>, submitted: Bool) {
    let submitRow = optionCount + 1
    var cur = startCursor
    var set = checked
    var submitted = false
    for k in keys {
        switch k {
        case "down":  cur = min(submitRow, cur + 1)
        case "up":    cur = max(1, cur - 1)
        case "space": if set.contains(cur) { set.remove(cur) } else { set.insert(cur) }
        case "return":
            if cur == submitRow { submitted = true }
            else if set.contains(cur) { set.remove(cur) } else { set.insert(cur) }
        default: break
        }
    }
    return (set, submitted)
}
for desired in [Set([1]), Set([1, 3]), Set([2, 4]), Set([3]), Set([1, 2, 3, 4])] {
    let keys = MultiSelectSync.keystrokes(desired: desired, liveContent: liveWidget)
    let out = replayLive(keys, startCursor: 1, checked: Set([1]), optionCount: 5)
    eq(out.checked, desired, "live replay reaches desired \(desired.sorted())")
    check(out.submitted, "live replay submits for desired \(desired.sorted())")
}

// MARK: - Summary

print("")
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
