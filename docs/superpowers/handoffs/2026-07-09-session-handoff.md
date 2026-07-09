# Session handoff — 2026-07-09

## Today's commits

- `af82c77` — Include VibeCut prompt packs in Quip sync. `VibeCutPromptReader` now merges `~/Library/Application Support/VibeCut/packs/*.json` (vibecutpack/1 files) after the base `<vibecut-repo>/shared/prompts.json` catalog; corrupt packs are skipped best-effort so one bad import can't block the sync. **Verified end-to-end this session (see matrix).**

(Only commit today; `e12c57b` / `c5343df` and earlier are from prior sessions.)

## Install state

- **Mac:** `/Applications/Quip.app` rebuilt + installed today from eb-branch @ `af82c77` (Release, Developer ID signed at build — team `D2PM6R797Q`, no resign step). Fresh pid verified after install. Build dirs `/tmp/quip-release` + `/tmp/quip-sim` removed and lsregister-unregistered; only /Applications copy remains. Repo tree clean (regen'd pbxproj restored).
- **iOS (physical `<your-iphone>`):** NOT reinstalled — commit was Mac-only. Phone's WS connection was dropped by the Mac restart; needs reconnect (tap X → reconnect or relaunch).
- **QA simulator:** recreated as "Quip QA — iPhone 17 Pro Max" UDID `9A204976-5E83-4909-B88C-7C06D3FD69B2` (iOS 26.4; prior clone was wiped again). Quip iOS Debug build installed and paired to the live Mac. Memory file + MEMORY.md updated.

## Verified vs install-only

| Item | Status |
|---|---|
| Pack prompts sync + land as `vibecut__*` files | ✅ hardware-verified (sim → live Mac) |
| VibeCut badge on inherited rows incl. pack prompt | ✅ verified (screenshots in session) |
| `mode:"send"` entries filtered from packs | ✅ verified |
| Corrupt pack skipped, rest still syncs | ✅ verified |
| Re-sync idempotent; deleted pack removed on next sync | ✅ verified |
| Preamble NOT prepended to bodies | ✅ verified |
| Same flow on physical iPhone | ⬜ install-only (sim-verified; phone untested but same code path) |
| Post-install push pipeline | ✅ push.log healthy, no APNs keychain orphan this time |

## Open threads

1. **23 stale Stream Deck prompt imports duplicate the inherited set** (`00-rules.txt`, `07-audit-security.txt`, … from Jun 3; preamble baked in, no badge). Library shows 47 rows with near-dupes. Decision needed: delete the old flat files?
2. **Mac runs in "no auth required" mode** — kokoro.log shows `auth_result success (no auth required)`; unauthenticated clients receive full window layout + prompt library. Pre-existing, not af82c77. Confirm intentional or re-enable PIN.
3. **Sync discoverability UX:** toolbar icon (`arrow.triangle.2.circlepath`) is unlabeled; "N synced" status clears after 3s; corrupt packs give zero user feedback; empty state (missing vibecut repo) untested.
4. Push to GitHub pending explicit confirmation (eb-branch policy).

## Resume

Fresh session: `Read docs/superpowers/handoffs/2026-07-09-session-handoff.md — pick up the open threads (stale prompt-import cleanup decision first).`
