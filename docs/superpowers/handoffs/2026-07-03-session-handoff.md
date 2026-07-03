# Session handoff — 2026-07-03

## Done this session

### 1. Finished content-share branch → merged to eb-branch
`ralph/content-share-intake` (US-001..US-006 + Bonjour TXT-fold + multi-select fix)
fast-forward merged into eb-branch. Mac ContentShare gate 43/43 green. Feature
branch deleted.

### 2. VibeCut prompt inherit — NEW feature, all 6 stories, merged to eb-branch
One-way inherit of VibeCut's prompt catalog into Quip's Prompts page + manual Sync.
Branched `ralph/vibecut-prompt-inherit`, FF-merged to eb-branch, branch deleted.

Commits (why each):
- `f60094b` US-001/002 — pure `VibeCutPromptMapper` (Shared): decode
  `vibecut/shared/prompts.json`, real-text include filter (type text|nil +
  non-empty body + mode!=send), preamble stripped, `vibecut__<slug>` ids, `vibecut`
  tag, deterministic collision suffixes. + `SyncVibeCut*` wire messages +
  `PromptEntry.isInherited`. Mac 16 tests.
- `cad2e70` US-003 — Mac engine: `VibeCutPromptReader` (`vibecutRepoPath` override,
  default `~/Projects/vibecut`) + least-flap `PromptLibrary.replaceVibeCutSet`
  (delete-only-`vibecut__`, ONE broadcast) + `handleSyncVibeCut` dispatch. Mac 19 tests.
- `cad79b6` US-004/005 — iOS: Sync button in `PromptLibrarySheet`, `VibeCut` badge,
  per-prompt hide (`hiddenPromptIDsJSON` + Shared `PromptHideState`) filtered at
  `sortedPromptsByMRU()`, prune on catalog change. iOS BUILD + 26 Mac tests.
- `5afcc95` US-006 — `docs/vibecut-prompt-inherit.md` + README + wishlist SHIPPED entry.

## Install state (both installed THIS session — INSTALL-ONLY, not exercised)

| Target | State | Detail |
|---|---|---|
| Mac `/Applications/Quip.app` | **fresh build installed + running** | Release, Developer ID (D2PM6R797Q), runtime; PID started Fri Jul 3 13:08; WS 8765 LISTENING; installed binary byte-identical to fresh build. Stale QuipMac DerivedData Debug copy unregistered+rm'd; only `/Applications` Mac copy remains. |
| iOS `com.quip.QuipiOS` | **installed to iPhone 17 Pro Max** (FA951BBB) | Debug-iphoneos via devicectl. **USER MUST force-quit + relaunch** to load new Swift (devicectl doesn't kill the running process). |

⚠️ Mac cdhash bumped this build → **may re-prompt TCC once** (Accessibility +
Screen Recording). Developer ID DR should keep grants; if keystroke/screenshot
break, re-grant once. Restarting Mac app dropped phone connections — **reconnect the phone.**

## Hardware-verified vs install-only

- **NOT hardware-verified:** the whole VibeCut sync flow (Settings → Prompts → ⟳ Sync
  → 23 prompts land, badged, hide-able; re-sync idempotent; not-found guard). All
  gates were unit/build only. Live end-to-end run still owed.
- Verify recipe: `docs/vibecut-prompt-inherit.md` (§On the phone) + the plan file
  `~/.claude/plans/cached-bubbling-mochi.md` (§Verification).

## Open threads
- Hardware-verify VibeCut sync on-device (needs phone reconnected + Sync tapped).
- Still-deferred from prior session: content-share Phase 1 persist + Phase 2 Bonjour
  hardware verify (transport-flap blocked).
- eb-branch is **27 commits ahead of `origin/eb-branch`**, UNPUSHED (never push
  without explicit confirmation).

## Resume command (fresh session)
"On eb-branch: reconnect the phone to the Mac, force-quit+relaunch Quip on the
iPhone 17 Pro Max, then Settings → Prompts → tap ⟳ Sync from VibeCut and confirm
~23 badged prompts land per `docs/vibecut-prompt-inherit.md`."
