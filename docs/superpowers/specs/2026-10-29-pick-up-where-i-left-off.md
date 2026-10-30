# Spec: Pick up where I left off (+ one-tap Remote in) — Q-88

Status: **ready to build** (spec only; no code written). Written 2026-10-29, revised the same day after a code check.
Platform: QuipiOS only, plus test tooling in `tools/fake-mac/` and one story in the Berriscope repo. **No QuipMac change, so no Mac rebuild** (each rebuild costs the TCC grants).

## 1. Why

Owner, 2026-10-29: "the last window you [used] should pop up first, you should know your place in the app … things like this make it more enjoyable … from a mobile perspective", and "I often remote into the computer from my mobile app". Owner uses Berriscope (their own P2P remote desktop); other Quip users use other tools.

Decisions already made by the owner:

| Question | Answer |
|---|---|
| Remote in: built-in streaming or launch an app? | Launch an external app, one tap |
| Which app? | Owner: Berriscope. Others: their own. So presets, nothing hard-wired |
| "Recent" as the default grid order? | Yes |
| How long is "still where I left off"? | 30 min ("I think") — one constant, tune after use |

## 2. What the code does today (checked 2026-10-29 at `dd27444`)

| Area | Today | File |
|---|---|---|
| Last window | One id per backend, `lastSelectedWindow.<backendID>`; falls back to `windows.first` | `QuipiOS/Services/WindowSelectionMemory.swift`, tests `QuipiOS/Tests/WindowSelectionMemoryTests.swift` |
| Initial pick on layout | `WindowSelectionMemory.initialSelection` | `QuipiOS/QuipApp.swift` ~668 |
| Selected window vanishes | jumps to `update.windows.first` | `QuipiOS/QuipApp.swift` ~652 |
| Grid order | Manual drag order `phoneWindowOrderJSON` (`@AppStorage`), pins float first (Q-58). **There is no sort control** | `QuipiOS/Models/PhoneWindowOrder.swift`, `QuipApp.swift` ~1626–1953, tests `PhoneWindowOrderTests.swift` |
| Text input | `showTextInput` + one shared `textInputValue` | `QuipApp.swift` 147 |
| Terminal panel | `isTerminalExpanded` (`@State`), follow-tail via `isPinnedToBottom` + `TerminalScrollPolicy` | `QuipApp.swift` 1654, `QuipiOS/Views/InlineTerminalContent.swift` 473/909, `QuipiOS/Services/TerminalScrollPolicy.swift` |
| Desktop / display chip | `selectedSpaceID`, `selectedDisplayID` (`@State`, lost on relaunch) | `QuipApp.swift` |
| Lifecycle hooks | `willResignActive` / `didEnterBackground` observers | `QuipApp.swift` 491/497 |
| Deep link | `quip://window/<id>` selects window + opens input | `QuipApp.swift` 395–410 |
| Mac focus | `select_window` → Mac `windowManager.focusWindow` | `QuipMac/QuipMacApp.swift` 1649 |
| Mac frontmost | `frontmost_changed` (400 ms poll on Mac); `followFrontmost` pref makes the phone follow it | `Shared/MessageProtocol.swift` 354, 1363 |
| Waiting | `WindowState.state == "waiting_for_input"`; `WindowAttentionCenter` | `Shared/MessageProtocol.swift`, `QuipiOS/Services/PushNotificationCenter.swift` |
| Toast | `errorToast: String?` — text only, **no action button** | `QuipApp.swift` 182 |
| Window menu | long-press `.contextMenu` | `QuipiOS/Views/WindowRectangle.swift` 208 |
| Backend row menu | `.contextMenu` with Pin / Edit | `QuipApp.swift` ~2778 |
| Tailscale host | `urlPriority == tailscalePriority` (100.64/10, `*.ts.net`) | `QuipiOS/Services/BackendConnectionManager.swift` 1049–1080 |
| Backend name | `PairedBackend.name` | `QuipiOS/Models/PairedBackend.swift` 20 |
| Fake Mac | commands: `layout`, `library`, `close`, `dead`, `alive`, `status`. **No way to mark a window waiting, change frontmost, reopen a window or serve long content** | `tools/fake-mac/fake-mac.swift`, `README.md` |

Window ids are bundle id + window number: stable while the window stays open, within one Mac boot. After a Mac reboot old ids simply stop matching.

## 3. One rule decides where the phone lands

Several features want to choose the window. Exactly one function decides, `LandingPolicy.decide(_:)` (pure), in this order — first match wins:

1. **Explicit intent**: push tap, `quip://window/<id>` deep link, or a user tap in the last 2 s. Never overridden.
2. **Follow the Mac**: `followFrontmost` is on → the Mac's frontmost tracked window. Steps 3–4 are skipped (the Mac decides); panel/draft/scroll still restore for whatever window that is.
3. **Smart landing** (US-009): away ≥ 2 min, setting on, the restored window is not itself waiting, and another window is `waiting_for_input` → that window (highest in recency; ties by Mac order), with a Back toast.
4. **Restore** (US-006): saved place for this backend, ≤ 30 min old, window still exists → that window.
5. **Recency** (US-002): first id in the recency stack that is still in the layout.
6. `windows.first`; nil if there are no windows.

Inputs: `explicit: String?`, `followFrontmost: Bool`, `macFrontmost: String?`, `awayFor: TimeInterval`, `smartLandingOn: Bool`, `place: PhonePlace?`, `now: Date`, `recency: [String]`, `windows: [(id, state)]`. Output: `(windowId: String?, reason: .explicit|.follow|.waiting|.restored|.recent|.first|.none)`. The reason is logged to `phone.log` (`landing reason=… away=Ns`) and drives the toast. **Every** selection path (initial layout, vanished window, foreground, backend switch) calls this one function and sends `select_window` at most once per decision.

## 4. Stories

Order is the build order. Each is sized for one focused session (Ralph-compatible). "Gate" means `QUIP_QA_SIM_UDID=<own sim> tools/check.sh` green, never the shared sim another session is using.

### US-000: Fake Mac can drive the scenarios this spec tests
**Why first:** without it, US-003/006/008/009 cannot be tested in the simulator.

- [x] New stdin commands in `tools/fake-mac/fake-mac.swift`:
  - `wait <window>` / `idle <window>`: set `state` to `waiting_for_input` / back to the fixture's value, resend `layout_update`.
  - `front <window>`: send `frontmost_changed` for that window.
  - `open <window>`: re-add a window removed by `close`, resend layout.
  - `lines <window> <N>`: serve N numbered lines (`line 0001 …`) as that window's terminal content on the next `request_content`.
- [x] `help` lists them; `README.md` command table updated.
- [x] `tools/run-fake-mac-tests.sh` (new, run by `tools/check.sh` harness scope): starts the fake on a free port with a FIFO, pipes each command, asserts the expected line in the fake's log (`--log`). One case per command plus an unknown-window case (prints `no such window`, changes nothing).
- [x] Gate.

### US-001: Recency stack of windows per Mac
- [ ] New pure `WindowRecency` (`QuipiOS/Services/WindowRecency.swift`): ids most recent first, cap 20, no duplicates. `touch(id)`, `prune(keeping:)`, `best(available:excluding:)`.
- [ ] Storage behind a `RecencyStore` protocol with a `UserDefaults` implementation (`recentWindows.<backendID>`, string array) and an in-memory one for tests — tests never touch `UserDefaults.standard`.
- [ ] Migration: no `recentWindows.<id>` but `lastSelectedWindow.<id>` exists → seed with it, then delete the old key.
- [ ] `WindowSelectionMemory` is removed; its call sites move to `WindowRecency`. `WindowSelectionMemoryTests` is ported, not deleted (its cases still hold).
- [ ] Tests `QuipiOS/Tests/WindowRecencyTests.swift` — table in §5.
- [ ] Gate.

### US-002: One landing decision, with recency fallback
- [ ] New pure `LandingPolicy` (`QuipiOS/Services/LandingPolicy.swift`) implementing §3 steps 1, 2, 5, 6 (3 and 4 stubbed as "no candidate" until US-006/US-009).
- [ ] `QuipApp.swift` ~652 (vanished window) and ~668 (initial pick) both call it; the two separate `select_window` sends collapse into one call site.
- [ ] Every phone selection path calls `touch` (tap, deep link, `onSelectWindow` echo, push tap, backend switch).
- [ ] Tests `LandingPolicyTests.swift` — table in §5, including "stack [C,B,A], layout [A,B] → B".
- [ ] Wiring test (pattern: `BroadcastWiringTests`): a `layout_update` without the selected window produces exactly one `SelectWindowMessage` for the recency pick.
- [ ] Gate.

### US-003: Mac frontmost feeds the recency stack
- [ ] `frontmost_changed` with a tracked id → `touch` on that backend's stack, even with `followFrontmost` off (order only; selection unchanged).
- [ ] Writes coalesced: at most one persisted write per backend per second (`RecencyWriteCoalescer`, injectable clock).
- [ ] Bridged in `BackendConnectionManager.wire()` if not already (check: every `onFoo` needs a `c.onFoo` bridge or it silently no-ops on non-active backends).
- [ ] Tests: two events 100 ms apart → one write, latest order; event for an untracked id → no change; inactive backend's event updates that backend's stack only.
- [ ] Sim scenario S3 (§6).
- [ ] Gate.

### US-004: "Recent" grid order (default) and "Manual"
- [ ] New pref `windowOrderMode` (`recent` | `manual`), `@AppStorage`, in `PreferencesSnapshot` with apply/snapshot wiring and the `savedAt` freshness gate.
- [ ] Default when unset: `manual` if `phoneWindowOrderJSON` is non-empty (the user has dragged before — keep their choice), else `recent`.
- [ ] `PhoneWindowOrder.display` gains a `mode` + `recency` input. Recent: sort by recency position; ids not in the stack keep the Mac's order after them. Pins first in both modes (Q-58).
- [ ] Dragging a card in Recent mode switches to Manual and saves the drag. A toast says "Order: Manual" with a **Use Recent** action.
- [ ] Settings → existing windows section gets a two-option picker "Window order: Recent / Manual". No new main-screen control (compact UI).
- [ ] No reshuffle under the finger: in Recent mode, reorders are deferred while a drag or press is active and applied 300 ms after it ends.
- [ ] Tests: extend `PhoneWindowOrderTests` (recent order, pins first, unknown ids, mode default migration); `PreferencesFreshnessTests` covers the new field.
- [ ] New tiny `ActionToast` view (text + one button, 4 s auto-dismiss, VoiceOver reads both) — reused by US-004/US-009/US-011. Unit test on its dismiss timer with an injected clock.
- [ ] Sim scenario S4.
- [ ] Gate.

### US-005: `PhonePlace` — what "my place" is, saved on background
- [ ] `Codable` `PhonePlace` per backend (`phonePlace.v1.<backendID>`): `selectedWindowId`, `selectedDisplayID`, `selectedSpaceID`, `textInputOpen: Bool`, `terminalExpanded: Bool`, `scrollAnchorByWindow: [String: ScrollAnchor]`, `savedAt: Date`.
- [ ] Saved on `didEnterBackground` (hook already exists, `QuipApp.swift` 497) and on selection change, debounced 1 s. `backgroundedAt` stored separately to compute `awayFor`.
- [ ] Device-local: **not** in `PreferencesSnapshot`, not in iCloud KVS, never sent to the Mac. A test asserts `PreferencesSnapshot`'s coding keys contain none of these names.
- [ ] Tests `PhonePlaceTests.swift`: round trip; unknown future keys ignored; corrupt data → nil, not a crash (and one `phone.log` line, matching the `PersistenceLoudDropTests` convention).
- [ ] Gate.

### US-006: Restore the place
- [ ] `LandingPolicy` step 4 enabled: saved place, same backend, `now - savedAt ≤ PlaceRestorePolicy.freshness` (30 min, one constant).
- [ ] Restore runs after the first `layout_update` with windows; order: display/desktop chip → window (via `LandingPolicy`) → `terminalExpanded` → `textInputOpen`. Panel flags restore only if the chosen window is the saved window.
- [ ] Stale (> 30 min): only the window (recency); panels closed.
- [ ] Switching backends in-app restores that backend's place (same function).
- [ ] Sheets (Settings, Prompts, Slash, QA picker, scanner, camera) are **not** restored — see Non-goals.
- [ ] Tests `PlaceRestorePolicyTests.swift` — table in §5.
- [ ] Sim scenario S6.
- [ ] Gate.

### US-007: Unsent text kept per window
- [ ] `DraftStore`: draft per window id, replacing the single shared `textInputValue`. Switching windows saves the old window's draft and loads the new one's; send clears only that window's draft.
- [ ] Persisted to a file in Application Support, `drafts.v1.<backendID>.json`, with `FileProtectionType.complete` and `isExcludedFromBackup = true` — **not** `UserDefaults` (drafts can hold secrets; `UserDefaults` is backed up). Cap 4 KB per draft, 50 drafts per backend; drafts for ids pruned from the recency stack are dropped.
- [ ] Draft text never reaches `phone.log`, the Mac, or `PreferencesSnapshot`.
- [ ] Tests `DraftStoreTests.swift` (in-memory file backing): switch-save-load, send clears one, prune drops, 4 KB cap truncates on a character boundary (emoji safe), file attributes set.
- [ ] Sim scenario S7.
- [ ] Gate.

### US-008: Terminal scroll position comes back
- [ ] `ScrollAnchor` = text of the first visible line + its distance from the end. Saved only when `isPinnedToBottom == false`.
- [ ] New pure `TerminalScrollPolicy.resolve(anchor:lines:)`: search outward from the saved distance for an exact line match; found → that line index; not found → nil (bottom, follow-tail on).
- [ ] `InlineTerminalContent` uses it on appear when an anchor exists for the window; `isPinnedToBottom` stays the source of truth afterwards.
- [ ] Tests: extend `TerminalScrollPolicyTests` — exact, shifted by 40 new lines, duplicate lines (nearest to the saved distance wins), line gone, empty buffer.
- [ ] Sim scenario S8 (needs US-000 `lines`).
- [ ] Gate.

### US-009: Smart landing on a waiting window
- [ ] `LandingPolicy` step 3 enabled. Threshold 2 min (constant). Setting "Jump to waiting windows" (default on) in Settings → Notifications, in `PreferencesSnapshot`.
- [ ] `ActionToast`: "Jumped to <window name> — waiting for you" with **Back** (reselects the window step 4/5 would have chosen).
- [ ] Never fires on explicit intent or with `followFrontmost` on (§3).
- [ ] Tests in `LandingPolicyTests` — table in §5.
- [ ] Sim scenario S9 (threshold overridden by a `#if DEBUG` launch argument `-QuipSmartLandingAfter 5`).
- [ ] Gate.

### US-010: Remote-in settings
- [ ] Settings → Connection → "Remote in" (per backend, in `PreferencesSnapshot`): app preset, host, Mac name.
- [ ] Presets (no hard-wired default app): **Any VNC app** `vnc://{host}` (fresh-install default; also opens Apple Screen Sharing where installed), **Berriscope** `berriscope://open?saved={name}` (needs US-012), **Screens**, **Jump Desktop**, **RealVNC Viewer** (each with its documented scheme, verified against the app's docs at build time and cited in a code comment), **Custom** (free template).
- [ ] Host default: the backend's Tailscale host (MagicDNS name if any, else 100.64/10 address) via the existing `urlPriority`. None → empty with hint "Add this Mac's Tailscale name".
- [ ] Mac name default: `PairedBackend.name`.
- [ ] Templates: `{host}` and `{name}`, percent-encoded; unknown `{x}` placeholder or unparsable URL → inline error, Save disabled.
- [ ] `LSApplicationQueriesSchemes` in `QuipiOS/project.yml` lists every preset scheme (`canOpenURL` returns false for unlisted schemes); `xcodegen generate` then restore the pbxproj per US-005 protocol.
- [ ] Pure `RemoteInURLBuilder` + tests `RemoteInURLBuilderTests.swift` — table in §5.
- [ ] Sim scenario S10.
- [ ] Gate.

### US-011: One-tap Remote in
- [ ] "Remote in here" in the window long-press menu (`WindowRectangle.swift` 208); "Remote in" in the backend row menu (`QuipApp.swift` ~2778). No always-visible button.
- [ ] "Remote in here": send `select_window` (Mac focuses it), wait up to 500 ms for the Mac's `frontmost_changed` echo for that id (proceed anyway on timeout), then open the URL.
- [ ] No app for the scheme → `ActionToast` "No app opens <scheme>:" with **Settings** action. No host/name configured → opens the Remote-in setting directly.
- [ ] `phone.log`: `remote_in preset=<p> host_kind=tailscale|lan|name|custom result=opened|no_app|no_host waited_ms=N` — never the host value.
- [ ] Tests: `RemoteInFlowTests.swift` with an injected `URLOpener` and clock: select-then-open order; timeout still opens; no-app path; no-host path; log line contains no host.
- [ ] Sim scenario S11 (`no_app` expected — the simulator has no VNC app).
- [ ] Gate.

### US-012 (Berriscope repo): Berriscope iOS opens a saved host from a link
Today `berriscope://` is registered (`apple/Resources/IOS-Info.plist`) but only parsed from a scanned QR (`apple/Sources/BerriscopeIOS/ConnectView.swift` 1173); there is no `onOpenURL`, so a link launches the app and stops. Saved hosts are `SavedHost`, keyed by `code`, with a user-editable name.

- [ ] `onOpenURL` handles `berriscope://open?saved=<name>`: case-insensitive match on a saved host name → the same path as tapping that saved host (remembered PIN honoured, else the normal PIN prompt).
- [ ] No match → connect screen with banner "No saved Mac named <name>". Never connects to an unknown host from a link.
- [ ] `berriscope://<code>` and `berriscope://relay?…` arriving via `onOpenURL` (not a scan) require a confirmation tap — a link from any app must not start a session to a new host silently.
- [ ] Tests on the parser: match, no match, encoded spaces, two hosts same name (most recently connected wins), unknown path, relay-from-link requires confirm.
- [ ] Follow Berriscope's own gate and signing rules. Until shipped, Quip's Berriscope preset help text says "opens Berriscope; connecting by name needs Berriscope 2026-11+".

## 5. Unit test tables

Every pure type gets table-driven tests. Each row is one `XCTAssert`.

**WindowRecency** — touch A,B,C → [C,B,A]; touch B again → [B,C,A]; 21 touches → 20 kept, oldest dropped; prune keeping {A} → [A]; best(available [A,B], excluding B) → A; best with nothing available → nil; migration seeds from `lastSelectedWindow` and deletes it; migration skipped when new key exists.

**LandingPolicy** — explicit beats everything (incl. waiting window); `followFrontmost` on → Mac frontmost, no smart landing; away 1 min + other window waiting → restore, not jump; away 3 min + other waiting → jump, reason `.waiting`; restored window itself waiting → stay; two waiting → higher in recency; setting off → no jump; place 29 min → restored; place 31 min → recency; place from another backend → ignored; saved window gone → recency excluding it; empty layout → nil; decision sends one `select_window`.

**PlaceRestorePolicy** — fresh place restores chip, window, terminal, input in that order; stale restores window only; saved display gone → display unchanged, window still restored; panel flags dropped when window differs.

**TerminalScrollPolicy.resolve** — as US-008.

**RemoteInURLBuilder** — each preset with MagicDNS host; IPv4 Tailscale host; name with spaces → `%20`; custom `myapp://x?h={host}&n={name}`; unknown placeholder → error; empty host for a `{host}` preset → `.noHost`; empty name for Berriscope → `.noHost`.

**Mutation check** (repo convention, record results in the commit message): for each pure type, break the key line and confirm a test fails — e.g. drop the cap in `WindowRecency`, swap steps 3/4 in `LandingPolicy`, use `>` for `≤` on freshness, skip percent-encoding, drop the `excluding` filter. A mutation that no test catches means a missing test, added before commit.

## 6. Simulator scenarios (fake Mac)

Run on **your own** simulator (`xcrun simctl create`, `QUIP_QA_SIM_UDID`), fake Mac on a port other than 8799 if another session uses it, FIFO stdin, idb taps by screenshot points. Each scenario ends with a screenshot saved under the session scratchpad and named in the commit notes. Script them as `tools/qa/q88-<id>.sh` so a later session can re-run them.

| ID | Steps | Expect |
|---|---|---|
| S2 | select W3, then W1; fake `close W1` | W3 selected (not first in list) |
| S3 | fake `front W4`; open grid | W4 first in Recent order; selection unchanged |
| S4 | fresh install → grid order; drag W2 to first | Recent by default; after drag toast "Order: Manual", tap Use Recent → recency order back |
| S6 | W2 + terminal expanded + input open; background; relaunch within 1 min | same window, terminal expanded, input open |
| S6b | same, but relaunch with clock override +31 min (`-QuipNowOffset 1860`, DEBUG only) | window restored, panels closed |
| S7 | type "hello" in W1, switch to W2, back | "hello" in W1; W2 empty |
| S8 | `lines W1 500`; scroll to line ~200; background; relaunch | line ~200 visible, not the bottom |
| S9 | `-QuipSmartLandingAfter 5`; on W1, background 10 s, `wait W3`; return | W3 selected, toast, Back → W1 |
| S10 | Remote in settings: each preset | URL preview correct; custom bad placeholder blocks Save |
| S11 | long-press W2 → Remote in here | fake log shows `select_window W2` before the attempt; toast "No app opens vnc:" |

## 7. Hardware checklist (owner, once, after all stories)

Phone-only install; **do not rebuild the Mac**. Tail `~/Library/Logs/Quip/phone.log` live while testing.

1. Use W2 with terminal scrolled up; lock the phone 5 min; unlock → same spot. `landing reason=restored`.
2. Close the current window on the Mac → phone lands on the previously used one. `reason=recent`.
3. Leave 3+ min while a Claude prompt is waiting in another window → jump + toast; Back works. `reason=waiting`.
4. Push-tap a waiting notification → that window, no smart-landing toast. `reason=explicit`.
5. Berriscope preset (after US-012 ships) → "Remote in here" opens Berriscope connected to this Mac with W2 in front.

## 8. Functional requirements

- FR-1 Per-backend recency stack (≤ 20), updated by phone selections and Mac `frontmost_changed`.
- FR-2 One landing decision (§3) for every automatic selection; `windows.first` only as last resort.
- FR-3 Place saved on background and selection change; restored within 30 min on the same backend.
- FR-4 Drafts per window, file-protected, excluded from backup, never logged or synced.
- FR-5 Recent is the default grid order unless the user has a saved manual order; pins always first.
- FR-6 Smart landing after ≥ 2 min away, with Back; off-switch in Settings.
- FR-7 Remote in via presets + custom template; selected window focused first; no host values in logs.

## 9. Non-goals

- Built-in screen streaming / remote control in Quip.
- Waking or unlocking a sleeping or locked Mac.
- Restoring sheets (Settings, Prompts, Slash, QA picker, scanner, camera) or Settings navigation depth — sheets are short tasks; reopening one on launch would feel like a bug.
- Restoring a pending photo.
- Syncing place or drafts between devices or to the Mac.
- Any QuipMac, QuipLinux or QuipAndroid change.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Landing fights the user (jumps away while they look) | Only on return from background, never mid-session; explicit intent wins; Back toast |
| `QuipApp.swift` (6.5k lines) gets harder to change | All logic in pure types under `QuipiOS/Services/`; `QuipApp.swift` gets wiring only |
| iCloud KVS restore clobbers new prefs at launch | New prefs go through the `savedAt` freshness gate; sim QA sets prefs through the UI, not `defaults write` |
| Two `select_window` sends race | One call site via `LandingPolicy`; wiring test asserts exactly one |
| Drafts leak secrets | File protection + backup exclusion + no logging (US-007) |
| Remote-in scheme of a third-party app changes | Presets cite their source; Custom always available |

## 11. Success measures

- Relaunch within 30 min: 0 taps to the same window, panel and scroll (S6, S8).
- Closed window: lands on the previous one used in 100% of S2 runs.
- Remote in: 1 tap from the window menu to the remote app.
- `phone.log` `landing reason=` lines show `first` only when the stack is empty.
