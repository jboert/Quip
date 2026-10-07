# Session Handoff — 2026-10-02 → 2026-10-06 (prompt generator, dictation engines)

Branch: `eb-branch` (local, ahead of `origin/eb-branch`; not pushed this session).

## Commits this session

| Hash | Why |
|------|-----|
| `a6b1a04` | Q-35: the prompt generator opens on the selected window's agent and the user's most-used style, and lists up to 3 most-fired prompts to seed a draft. |
| `1eeff71` | Wishlist: first observed LAN auth (`192.168.4.50`, `auth=pin`) after the Q-35 install. One data point; the "phone never auths over LAN" item stays open. |
| `45cd707` | Q-38: with the Mac unreachable, the phone dictates with iOS 26 SpeechAnalyzer instead of SFSpeech, which dropped the words before every pause. It also drives remote-path captions. SFSpeech stays as the fallback (iOS < 26, unsupported locale, model not downloaded, Labs "Older iPhone speech recognizer"). |
| `c34cf88` | Q-39: Mac Whisper moves from `small.en` to `openai_whisper-large-v3-v20240930_626MB` (large-v3 turbo) via `WhisperModelLadder`, keeping small.en as fallback. Decoding forces English. |
| `eae1c4a` | Board: Q-38 / Q-39 done, hardware checks Q-38a / Q-39a filed. |

Plan for Q-38/39: `docs/superpowers/plans/2026-10-07-better-dictation-models.md`.

## Install state

- **Mac** `/Applications/Quip.app` 1.5.6 (build 1), Release, Developer ID D2PM6R797Q, installed 2026-10-06 20:31 MST (pid 6876). Carries everything through `c34cf88`, including Q-34b placeholders. `whisper.log`: `model=openai_whisper-large-v3-v20240930_626MB loaded`, `state=ready` at 03:32:35Z. Stale builds removed; only `/Applications` is registered.
- **iPhone** (primary iPhone 17 Pro Max): Debug build 1.5.6 with everything through `45cd707` installed via `devicectl` at handoff time. User has not yet relaunched it; no phone socket on 8765 at handoff.

## Verified on hardware vs install-only

| Item | State |
|------|-------|
| Q-35 generator seeding (Q-35a) | Installed, NOT tested |
| Q-38 iPhone SpeechAnalyzer (Q-38a) | Installed, NOT tested |
| Q-39 Mac Whisper turbo (Q-39a) | Model download + load VERIFIED in whisper.log; transcription quality NOT tested |
| Q-34b/d prompt placeholders at paste | Mac now installed; Q-34d NOT tested |
| Q-33a prompt ranking per agent | NOT tested |
| LAN auth | Observed once (00:55:28Z), not re-checked after the Mac restart |

## Open threads

1. **New: Mac services start only on window `onAppear`.** After `killall -KILL` + `open`, Quip relaunched with no window, so `startServicesOnce()` never ran: no listener on 8765, no Whisper. A second `open` fixed it. Any windowless relaunch leaves the phone unable to connect. Worth an item: start services from the app delegate, not a view's `onAppear`.
2. Hardware checks owed: Q-38a, Q-39a, Q-35a, Q-34d, Q-33a (steps in `board.md` Ready).
3. Q-36 "pin a bomb": meaning unknown, waiting on the owner.
4. Q-32a: App Store Connect record needed before the first TestFlight upload.
5. `KeystrokeInjectorClipboardTests.test_overlapping_pastes_restore_user_original_not_injected_text` failed once when the user copied text mid-run (it uses the real pasteboard). It passed on rerun. It is flaky under real use.

## Resume

Fresh session: "Read docs/superpowers/handoffs/2026-10-06-session-handoff.md, confirm the phone is connected (`netstat -an | grep 8765`), tail ~/Library/Logs/Quip/*.log, and walk me through Q-39a then Q-38a."

---

## Addendum — later the same night (after the first handoff)

### Commits since `a6854fb`

| Hash | Why |
|------|-----|
| `e1ad277` | #37/#35: Mac sends the last 2,000 terminal lines (was 200); the phone's text view follows new output only when the reader is at the bottom. |
| `ea8b130` | Board: Q-41 / GH #38 filed. |
| `b506f96` | Board: Q-39a partly verified (Whisper turbo on three live dictations, all `success=1`). |
| `08a4419` | Phone diagnostics reach the Mac as `~/Library/Logs/Quip/phone.log` (`phone_log` message; offline buffer of 200 lines; no transcript text). |
| `76e3725` | Board: Q-42 prompt UX, Q-43 "voice mode" (meaning unknown). |
| `b2e9246` | Q-42: one Prompts hub. Main-screen Prompts button and Settings → Prompts open the same screen; tap = paste, ↵ = send, hold = Edit / Hide / Delete (Delete confirms). Owner chose this layout. |
| `84c19dd` | Q-41 / #38: phone-only terminal text size (A− / A+, pinch, 7–22 pt) and screenshot pinch-zoom; dead `ContentZoomLevel` removed. |
| `bfad5a1` | #37 cause 3: Terminal.app sends `history` (whole buffer) for the phone only; text size joins the prefs backup. |

GitHub issues opened tonight: **#37** (scrollback, three causes) and **#38** (phone-only text size).

### Install state at addendum time

- Mac `/Applications/Quip.app` built from `bfad5a1`, pid 72148, Whisper turbo `ready`, stale builds cleaned.
- iPhone: build from `bfad5a1` installed, but the owner had **not relaunched** the app (no `phone.log` yet; phone not connected).
- **Accessibility still not re-granted** on the Mac: window taps fail with `axPositions=[]`. Text sends work (iTerm2 scripting).

### Hardware status

| Item | State |
|------|-------|
| Whisper turbo (Q-39a) | Partly verified: three clean dictations. Jargon run owed. |
| SpeechAnalyzer on the phone (Q-38a) | Not tested. `phone.log` will show `ptt engine=…` once the phone runs the new build. |
| Scrollback #37 (Q-40) | Not tested. `seq 1 3000` in iTerm2 and Terminal.app; expect line 1001 on the phone. |
| Prompts hub (Q-42), text size (Q-41) | Not tested. |

### Open threads

1. Q-43 "improve the voice mode": ask whether it means dictation, Kokoro spoken replies, or something else.
2. Mac services start only on window `onAppear`: after a windowless relaunch nothing listens on 8765. Every install tonight needed a second `open`. Worth fixing (start services from the app delegate).
3. Mac tests write fake `cursor load failed for /Users/me/Projects/corrupt` lines into the real `swrm.log`.
4. eb-branch ~30 commits ahead of origin, not pushed (owner's rule: push only on explicit OK).

### Resume

"Read the 2026-10-06 handoff and its addendum, confirm Accessibility is granted and the phone runs the new build (`phone.log` exists), then walk me through the Q-40, Q-41, Q-42 and Q-38a hardware checks."

---

## Addendum 2 — 2026-10-07

| Hash | Why |
|------|-----|
| `a707035` | Q-44: long-press a window card → **Color…** (10 swatches, custom picker, reset). `set_color` to the Mac, which keeps the choice per window id (`windowColorOverrides`). Installed on Mac and phone. |
| `7dbebe9` | Open thread 2 fixed: services start from `applicationDidFinishLaunching` (`LaunchHook`), so a windowless relaunch still listens on 8765. **Built and tested, NOT installed** (a Mac install wipes Accessibility again). |
| `0172a72` | Open thread 3 fixed: under XCTest `LogPaths.directory` is a temp folder; tests no longer write into `~/Library/Logs/Quip`. NOT installed (test-only effect anyway). |

Mac tests now run with the live Quip still up (XCTest guard skips services); expect ~50-90 s instead of ~20 s.

Still owed by the owner: re-grant Accessibility (focus errors `AXError -25204` continue), relaunch Quip on the phone (`phone.log` still empty at 17:52Z), hardware checks Q-38a, Q-40, Q-41, Q-42, Q-44.
