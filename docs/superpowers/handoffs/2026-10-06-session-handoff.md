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
