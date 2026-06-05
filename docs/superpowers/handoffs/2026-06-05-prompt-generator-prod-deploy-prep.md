# Session Handoff — 2026-06-05 Prompt Generator Prod Deploy Prep

User first asked to push the latest iPhone prompt generator code to prod and deploy, then redirected to prep for next session. No prod push or deploy was run after that redirect.

## Current Branch State

- Repo: `/Users/erickbzovi/Projects/Quip`
- Branch: `eb-branch`
- Local status at handoff: clean
- Remote state: `eb-branch` is aligned with `origin/eb-branch`
- Latest prompt-generator commit: `ef71286 Add prompt generator and tidy settings`
- Full hash: `ef712865f5cb75a3414d65b6dd0ab7cb51aa8ec3`
- `origin/main..eb-branch`: 4 commits ahead, 0 behind

Commits queued for prod promotion:

```text
eaeb380 Improve prompt sync and window list performance
d307369 Plan review hardening loop
0b38733 Confirm prompt saves from mobile
ef71286 Add prompt generator and tidy settings
```

Top prompt-generator files in the latest commit:

```text
QuipiOS/Services/PromptGenerator.swift
QuipiOS/Views/PromptGeneratorSheet.swift
QuipiOS/Tests/PromptGeneratorTests.swift
QuipiOS/Services/LabsFlags.swift
Shared/MessageProtocol.swift
Shared/Tests/MessageProtocolTests.swift
QuipMac/Views/SettingsView.swift
QuipMac/Views/MenuBarView.swift
```

## Scope Waiting To Promote

Diff from `origin/main` to `eb-branch` is 21 files:

```text
QuipMac/QuipMacApp.swift
QuipMac/Services/PromptLibrary.swift
QuipMac/Services/TerminalStateDetector.swift
QuipMac/Tests/PromptFrontMatterTests.swift
QuipMac/Views/LayoutPreview.swift
QuipMac/Views/MainWindow.swift
QuipMac/Views/MenuBarView.swift
QuipMac/Views/SettingsView.swift
QuipMac/Views/WindowListSidebar.swift
QuipiOS/QuipApp.swift
QuipiOS/QuipiOS.xcodeproj/project.pbxproj
QuipiOS/Services/LabsFlags.swift
QuipiOS/Services/PromptGenerator.swift
QuipiOS/Services/WebSocketClient.swift
QuipiOS/Tests/PromptGeneratorTests.swift
QuipiOS/Views/PromptGeneratorSheet.swift
Shared/MessageProtocol.swift
Shared/Tests/MessageProtocolTests.swift
docs/protocol.md
docs/superpowers/plans/2026-06-04-review-hardening-loop.md
docs/superpowers/wishlist.md
```

## What Is Already Known

- `ef71286` is already pushed to `origin/eb-branch`.
- It is not on `origin/main` yet.
- The PopClip repo has unrelated local planning/docs changes; ignore them for Quip prod work.
- The previous prompt-save hardening path used ack-driven prompt mutations:
  - `PutPromptMessage` / `DeletePromptMessage`
  - `PutPromptAckMessage` / `DeletePromptAckMessage`
  - `messageId`
  - `MessageDedupeTable`
- The prompt-generator work should be treated as iOS-facing and Mac protocol/settings-facing.

## Next Session Resume Order

1. Refresh and confirm state:

```sh
cd /Users/erickbzovi/Projects/Quip
git fetch --all --prune
git status --short --branch
git log --oneline --decorate --max-count=8
git rev-list --left-right --count origin/main...eb-branch
```

2. Run pre-promotion checks:

```sh
git diff --check origin/main..eb-branch
xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -only-testing:QuipMacTests/PromptFrontMatterTests -destination platform=macOS
xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -only-testing:QuipMacTests/MessageProtocolTests -destination platform=macOS
xcodebuild -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'generic/platform=iOS' -derivedDataPath QuipiOS/build build
```

3. Promote to prod if checks pass:

```sh
git switch main
git pull --ff-only origin main
git merge --ff-only eb-branch
git push origin main
git switch eb-branch
```

If `main` moved and fast-forward fails, stop and inspect instead of forcing.

4. Deploy Mac app:

```sh
xcodebuild -project QuipMac/QuipMac.xcodeproj -scheme QuipMac build
```

Then install the built `.app` into `/Applications/Quip.app` using the repo's established packaging/copy path from the current build output. Re-check Accessibility and Screen Recording if the installed app signature/path changes.

5. Deploy iPhone app:

```sh
xcrun devicectl list devices
xcrun devicectl device install app --device "<paired-iphone>" QuipiOS/build/Build/Products/Debug-iphoneos/Quip.app
xcrun devicectl device process launch --device "<paired-iphone>" com.quip.QuipiOS
```

The earlier successful physical-phone build path was:

```sh
xcodebuild -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination generic/platform=iOS -derivedDataPath QuipiOS/build build
xcrun devicectl device install app --device <device-id> QuipiOS/build/Build/Products/Debug-iphoneos/Quip.app
xcrun devicectl device process launch --device <device-id> com.quip.QuipiOS
```

## Manual Smoke To Prioritize

After install:

1. Open Quip on iPhone.
2. Open the prompt generator sheet.
3. Generate a prompt from a rough selected/entered idea.
4. Save it.
5. Confirm the Mac prompt library receives it without waiting for a watcher delay.
6. Edit/delete a prompt from iPhone and confirm ack-driven UX does not dismiss before Mac confirmation.
7. Confirm Settings and menu bar still render cleanly after the prompt-generator/tidy-settings changes.

## Final Answer Shape For Next Session

When done, report:

- Commit promoted to `origin/main`.
- Mac app build/install status.
- iPhone install and launch status.
- Tests/builds run.
- Any manual smoke results or blocker.
