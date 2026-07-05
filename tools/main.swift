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

// MARK: - Summary

print("")
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
