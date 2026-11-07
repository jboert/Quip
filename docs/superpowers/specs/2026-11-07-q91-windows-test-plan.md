# Q-91: Quip for Windows: test plan

Status: plan, 2026-11-07, at `439f039` on `eb-branch`. Behavior spec:
`docs/superpowers/specs/2026-11-06-q91-quip-windows-host.md` (called "spec"
below). Build plan: `docs/superpowers/plans/2026-11-06-q91-windows-host.md`
(called "plan"). S1-S9 and R1 are done. S10 (arrange), S11 (focus, typing,
keys) and S12 (logs, release build, README) are on hold until the owner's PC
check.

Every test name below was taken from the code with grep. A name marked
"planned" does not exist yet. A cell marked "gap" has no test and no plan.

## 1. Purpose and the bar

This plan says how we prove the Windows host works before the owner uses it.
It lists what is tested, where, by which test, and what is still open.

"Same bar as the Mac and iPhone" means the five habits of spec 10, held
concretely:

1. Every pure rule has its own unit tests. Each Windows module has the cases
   of its Mac twin (spec 10.3), copied by name where the Mac has them
   (for example `test_lockoutTriggersAfterMaxFails` in `auth_throttle.rs`
   twins `AuthThrottleTests`).
2. Peers share one source of truth. The Swift code writes or checks the
   files in `Shared/Tests/Fixtures/wire/` and `Shared/Tests/Fixtures/vectors/`.
   The Rust code reads them (`tests/shared_vectors.rs`). No copied numbers.
3. Mutation checks. Each pure module is run under `cargo mutants`. A missed
   mutant gets a test, or a one-line reason it is equivalent, in the commit
   message.
4. A fake peer for UI checks. The real iPhone app is driven in a simulator
   against `Quip --fake-platform`, never against a real PC or real data.
5. One gate. `tools/check.sh`, the pre-commit hook and CI run every affected
   suite. An unrun suite is reported as SKIPPED, never green.

Plus two things only Windows needs:

6. The real Win32 code runs on a real Windows desktop in CI on every push
   (`QUIP_WIN_UI=1` tests and `Quip.exe --selftest`).
7. The same selftest runs on the owner's PC, and its report comes back as
   evidence.

A build goes to the owner only when section 7 (release gate) is green.

## 2. Test layers and where each runs

Counts are from grep at `439f039`: 458 `#[test]` functions in `src/`
(2 of them only compile on Windows), 98 in `tests/`.

### L1. Mac unit tests (Rust, portable core)

- What: every pure rule in `src/` (protocol, auth throttle, dedupe, multi-line
  policy, geometry, broadcast, layout, classify, keys, typing plan, injector,
  logs, settings, tray menu, QR, selftest report and redaction).
- Where: the Mac, through `tools/check.sh`; also Windows CI step `test`.
- Command:
  ```bash
  cd QuipWindows && cargo test --lib
  tools/check.sh --files - <<< 'QuipWindows/src/lib.rs'   # the gate, scope windows
  ```
- `check.sh` scope `windows` runs `cargo fmt --check`, clippy for the host
  and for `x86_64-pc-windows-gnu`, and `cargo test`. With no
  `x86_64-pc-windows-gnu` target or no mingw it says SKIPPED with the install
  commands.

### L2. Shared vectors (Swift writes or checks, Rust reads)

- What: wire fixtures (one `min` and, where it has optional fields, one `full`
  file per phase 1 message, listed in `wire/index.json`) and seven rule
  vectors: `arrange`, `broadcast_filter`, `display_geometry`,
  `injection_log`, `multiline`, `pairing`, `window_color`.
- Swift side: `Shared/Tests/WireFixtureTests.swift`
  (`testEveryFixtureDecodesAndReencodesToTheSameShape`,
  `testEveryPhaseOneMessageHasAFixture`, `testIndexListsEveryFileInTheFolder`),
  `Shared/Tests/SharedVectorTests.swift`, `QuipMac/Tests/MacVectorTests.swift`
  (`testToWindowStateMatchesTheVectorFrames`, `testFirstUnused`,
  `testColorsToAvoid`).
- Rust side: `QuipWindows/tests/shared_vectors.rs`, 11 tests.
- Where: Rust on the Mac and in Windows CI. Swift in the QuipMac suite and
  (blocked, Q-92) the QuipiOS suite.
- Commands:
  ```bash
  cd QuipWindows && cargo test --test shared_vectors
  tools/check.sh --files - <<< 'Shared/Tests/Fixtures/vectors/arrange.json'   # runs Apple + windows scopes
  ```
- `changed-scopes.sh` maps `Shared/Tests/Fixtures/*` to `apple=true;
  windows=true`, so a fixture change pays for both sides.

### L3. Fake-platform integration tests

- What: the real `ws_server` on a random loopback port, a real WebSocket
  client, `platform/fake.rs` as the PC. Auth, pre-auth slots, broadcast,
  send_text, keys, arrange, heartbeat, prefs, New PIN.
- Where: the Mac and Windows CI.
- Command: `cd QuipWindows && cargo test --test ws_integration` (74 tests).

### L4. Win32 UI tests (real Windows only)

- What: the real Win32 backend against real windows: listing, classify,
  displays, tray, single instance, autostart, QR window, Bonjour.
- Files: `tests/win32_listing.rs` (6), `tests/win32_displays.rs` (2),
  `tests/win32_tray.rs` (3), `tests/win32_qr.rs` (2). They skip unless
  `QUIP_WIN_UI=1`. On the Mac they compile and skip.
- Where: Windows CI job `cargo test (QuipWindows)`, step "Win32 UI tests".
  Also on the PC if the owner has Rust (not required).
- Command (PowerShell on Windows):
  ```powershell
  $env:QUIP_WIN_UI = "1"
  cargo test --test "win32_*" -- --test-threads=1 --nocapture
  ```
- Every window a test opens carries a per-run marker
  (`selftest::own::marker`). A test closes only a window with its marker, so
  it is safe on a PC in use.

### L5. `Quip.exe --selftest` (CI and the PC)

- What: the same Win32 cases through the real app code. Registry
  `CASES` in `src/selftest/win32.rs`, 11 cases today:
  `process_snapshot`, `displays_one_primary`,
  `displays_work_area_inside_bounds`, `frames_inside_0_to_1`,
  `foreground_window_owner`, `classic_powershell_console`,
  `classic_cmd_console`, `busy_shell_reads_unknown`, `windows_terminal`,
  `start_with_windows_round_trip`, `pairing_qr_window`.
- Output: `%LOCALAPPDATA%\Quip\Logs\selftest-<UTC time>.txt`. One
  `PASS`/`FAIL`/`SKIP` line per case, a header (Quip version and git sha,
  Windows `major.minor.build`, each display with DPI), `SUMMARY` last. User,
  host, domain, IPs and foreign window titles are redacted.
- Exit code: 0 all passed, 1 any FAIL, 3 nothing failed but something was
  skipped (a SKIP is not a PASS), 2 not on Windows.
- Where: Windows CI step "Selftest" (artifact `selftest-report`) and the PC.
- Command on the PC: `start /wait Quip.exe --selftest` (cmd) or
  `.\Quip.exe --selftest | Out-Host` (PowerShell).
- S10 and S11 append arrange and typing cases to `CASES` (planned).

### L6. Simulator QA with the real phone app

- What: the real iPhone app on a simulator of our own, paired to
  `Quip --fake-platform` on 127.0.0.1. Six scripts in `tools/qa/`:
  `q91-pair.sh`, `q91-layout.sh`, `q91-send.sh`, `q91-keys.sh`,
  `q91-arrange.sh`, `q91-two-backends.sh`, sharing `q91-lib.sh`. Each saves
  a screenshot under `docs/superpowers/evidence/q91/`.
- Where: the Mac. Simulator clone `1CA3EE21` with phone app 1.5.7.
  Fake-windows on port 8797, fake-mac on 8799. Never port 8765. Never the
  shared `D8C5154B` simulator while another session uses it.
- Command:
  ```bash
  for s in pair layout send keys arrange two-backends; do
    tools/qa/q91-$s.sh <sim-udid> || echo "FAIL q91-$s"
  done
  ```
- Gap: the owner's phone runs 1.6.0. The 1.6.0 build cannot be built for the
  simulator until Q-92 is fixed, so the scripts have only run against 1.5.7.
- Limits: no dictation in the simulator (typed text uses the same
  `send_text`). The phone has no control that sends `arrange_windows`, so
  `q91-arrange.sh` sends it from a scripted peer.

### L7. Owner manual checks on the PC

- What only a person at the PC can see: tray icon, SmartScreen, firewall
  prompt, the phone grid, typing into the right window, reboot. Section 6
  gives the steps per milestone. Spec 11 is the final checklist.

### L8. Mutation checks

- What: `cargo mutants` on the pure modules (spec 10.7: `protocol`,
  `auth_throttle`, `dedupe`, `multiline_policy`, `injection_log`,
  `geometry`, `broadcast`, `layout`, `window_id`, `classify`, `keys`,
  `router`, `typing_plan`, plus `host.rs` and `ws_server.rs`).
- Where: the Mac, per slice, on the files the slice changed. Results go in
  the commit message.
- Command:
  ```bash
  cd QuipWindows
  export QUIP_SHARED_FIXTURES="$PWD/../Shared/Tests/Fixtures"
  export QUIP_FAKE_WINDOWS_FIXTURE="$PWD/../tools/fake-windows/fixture.json"
  cargo mutants --file src/host.rs --file src/services/auth_throttle.rs -j 4
  cargo mutants --in-diff <diff-file> -j 4          # only what a slice changed
  ```
- A timeout counts as caught (the test waits for a reply that never comes).
- Known survivors (plan S5e, R1): `AuthThrottle::gc` lockout `>` x3,
  `ws_config` max_message_size, `spawn` `Ticks::Auto` `==`,
  `is_benign_close` x5 and its `!`, and the `#[cfg(windows)]` registry code
  in `tray/autostart.rs` (the Mac run cannot reach it; `win32_tray.rs` covers
  it on Windows CI). Each needs a test or a written equivalence reason before
  release (section 7).

## 3. Coverage matrix

Columns:

- **Unit** = L1 (`src/`), **Vec** = L2, **Int** = L3 (`ws_integration.rs`),
  **Win32** = L4, **Self** = L5 case name, **Sim** = L6 script,
  **Owner** = L7 step (section 6), **Mac/iOS twin** = the Swift test file
  that covers the same behavior.
- "S10/S11/S12" = planned in that slice. "gap" = no test and no plan.

### 3.1 Connection and auth

| Feature | Unit | Vec | Int | Win32 | Self | Sim | Owner | Mac/iOS twin |
|---|---|---|---|---|---|---|---|---|
| Handshake order (auth_required, auth_result, device_identity, layout_update) | `auth_required_signal_is_the_string_the_phone_matches`, `test_authResult_success_omitsError`, `test_deviceIdentity_roundTrip_withLocalURLs` | `wire_fixtures_decode_and_reencode_with_the_same_shape`, `host_built_messages_match_the_wire_fixtures` | `right_pin_gets_auth_result_identity_layout_in_that_order`, `nothing_reaches_a_phone_before_its_auth_result_even_mid_broadcast` | gap | gap | `q91-pair.sh` | Now 4 | Shared `MessageProtocolTests`, `WireFixtureTests`; Mac `WebSocketServerRequireAuthTests` |
| PIN (8 digits, stored, never logged) | `test_freshInstall_pinManager_generates8DigitPIN`, `leading_zeros_are_kept`, `log_form_is_length_only`, `first_run_creates_the_file_with_an_8_digit_pin` | gap | `wrong_pin_fails_after_the_throttle_delay`, `malformed_auth_is_answered_not_fatal` | gap | gap | `q91-pair.sh` | Now 4 | Mac `PINStoreTests`; iOS `BackendPINCarryOverTests` |
| Auth throttle (delay, 10 failures, 15 min lockout, exact address, /64 delay) | `test_lockoutTriggersAfterMaxFails`, `lockout_ends_exactly_at_fifteen_minutes`, `sender_of_folds_ipv4_mapped_ipv6_into_ipv4`, `two_addresses_in_one_slash_64_do_not_share_a_lockout`, `network_delay_is_zero_within_one_addresss_budget_then_grows_to_the_cap`, `a_right_pin_is_accepted_however_slow_its_network_has_become` | gap | `ten_failures_lock_out_even_the_right_pin`, `rotating_addresses_in_one_slash_64_get_a_growing_delay_but_the_right_pin_still_pairs`, `attacker_tokens_on_two_networks_never_refuse_the_owners_right_pin`, `a_wrong_pin_with_no_free_token_waits_for_one_instead_of_being_refused` | gap | gap | gap | gap | Mac `AuthThrottleTests` |
| Pre-auth slots (16 / 8 per network / 4 per address, eviction, deadlines) | `pre_auth_limits_match_the_mac`, `test_connectionThatNeverHandshook_isReaped`, `test_deadlineLeavesRoomForASlowButRealHandshake` | gap | `at_most_sixteen_sockets_wait_for_auth`, `one_sender_holds_at_most_four_pre_auth_sockets_and_another_still_connects`, `one_slash_64_holds_at_most_eight_pre_auth_sockets_and_ipv4_still_connects`, `four_ipv4_addresses_holding_all_sixteen_slots_never_keep_a_fifth_from_pairing`, `a_neighbour_inside_an_attacker_held_slash_64_still_pairs`, `a_newcomer_refused_for_its_full_network_evicts_nobody`, `a_slot_whose_wrong_pin_is_queued_is_never_evicted`, `closing_during_the_wrong_pin_delay_frees_the_slot_at_once`, `an_unauthenticated_socket_is_closed_after_the_deadline` | gap | gap | gap | gap | Mac `PreHandshakeReapPolicyTests`, `ConnectionOutcomeTests` |
| Rate limit (10/s, auth exempt, connect burst fits) | `rate_limit_allows_ten_per_second_then_drops`, `only_a_snake_case_type_reaches_the_log` | gap | `more_than_ten_frames_a_second_are_dropped_but_auth_is_not`, `the_phones_connect_burst_is_not_rate_limited` | gap | gap | `q91-pair.sh` (burst passes) | gap | gap (Mac `allowMessage` has no unit test) |
| Unknown type, bad JSON, oversized frame | `unknown_type_is_reported_not_decoded`, `bad_json_is_reported_not_decoded`, `app_cap_matches_shared_constants_swift`, `protocol_cap_sits_just_above_app_cap` | gap | `unknown_types_bad_json_and_oversized_frames_are_ignored`, `a_frame_past_the_protocol_cap_closes_the_socket_one_at_the_app_cap_is_kept` | gap | gap | gap | gap | Shared `MessageProtocolTests` |
| Heartbeat (15 s, ack, missed count) | `test_heartbeat_encodesSeqAndTs`, `test_heartbeatAck_decodes`, `manual_clock_moves_both_readings` | `wire_fixtures_decode_and_reencode_with_the_same_shape` (`heartbeat.min.json`) | `heartbeat_every_15s_with_the_injected_clock`, `heartbeats_go_only_to_authenticated_phones`, `acks_reset_the_missed_count`, `recovery_is_logged_only_after_a_failure`, `a_send_text_blocked_5s_does_not_delay_heartbeats_or_another_phones_layout` | gap | gap | gap | Now 6 (idle 2 min, still connected) | Shared `MessageProtocolTests`, `WireFixtureTests`; iOS gap (no heartbeat test) |
| IPv4-only listener | `the_real_host_listens_on_ipv4_only` (in `src/app.rs`), `interface_listing_never_contains_loopback` | gap | gap | gap | gap | gap | Triage: `netstat` shows `0.0.0.0:8765` | none (the Mac listens on both) |

### 3.2 Windows, displays, broadcast

| Feature | Unit | Vec | Int | Win32 | Self | Sim | Owner | Mac/iOS twin |
|---|---|---|---|---|---|---|---|---|
| layout_update content and listing filter | `an_ordinary_app_window_is_kept`, `each_filter_drops_the_window`, `every_window_starts_disabled_terminals_still_ride_out`, `an_older_listing_never_replaces_a_newer_one`, `test_layoutUpdate_roundTripsDisplays`, `test_windowState_encodesSwiftKeySet_andOmitsNilOptionals` | `wire_fixtures_decode_and_reencode_with_the_same_shape` (`layout_update.min/full.json`) | `window_open_move_close_each_broadcast_once_and_no_change_is_silent`, `concurrent_polls_never_send_an_older_layout_after_a_newer_one`, `a_failing_listing_keeps_the_last_state` | `the_filter_keeps_only_plain_app_windows_and_minimized_ones_report_their_restored_rect`, `notepad_is_an_app_not_a_terminal` | `frames_inside_0_to_1` | `q91-pair.sh`, `q91-layout.sh` | Now 5-6 | Mac `WindowSnapshotGraceTests`; Shared `WindowOrderAndDisplayTests` |
| Window ids (HWND reuse) | `same_window_across_polls_keeps_its_id`, `hwnd_reused_by_a_new_process_gets_a_new_id`, `ids_are_unique_and_space_free` | gap | `a_reused_handle_types_nothing_and_reports_window_closed` | gap | gap | gap | gap | Shared `WindowManagerSessionIdTests` |
| Minimized windows | `minimized_windows_stay_in_the_set_are_flagged_and_restored_first`, `a_minimized_window_reported_at_the_parking_rect_is_still_shown`, `restored_rect_adds_the_work_area_offset` | gap | gap | `the_filter_keeps_only_plain_app_windows_and_minimized_ones_report_their_restored_rect` | gap | gap | Now 5 | iOS `MinimizedTrayTests` |
| Displays and DPI | `exactly_one_primary`, `display_names`, `frames_are_per_display_and_monitor_is_the_primary`, `monitor_does_not_change_with_focus`, `scale_from_dpi`, `testWindowIsAssignedToTheDisplayContainingItsCenter`, `center_exactly_on_the_seam_belongs_to_the_right_display`, `gap_without_a_primary_falls_back_to_the_first` | `display_geometry_vectors` | gap | `at_least_one_display_and_exactly_one_primary_at_the_origin`, `frames_of_windows_inside_a_display_are_inside_0_to_1` | `displays_one_primary`, `displays_work_area_inside_bounds`, `frames_inside_0_to_1` | gap | Now 3 (header lines) | Shared `DisplayGeometryTests`; Mac `MacVectorTests` |
| Classify shells (WT, conhost, powershell / pwsh / cmd / unknown, busy shell) | `windows_terminal_by_process_or_class`, `conhost_with_each_shell`, `unknown_console_is_still_a_terminal`, `elevated_window_without_process_access_is_kept`, `a_program_running_in_the_shell_makes_it_unknown`, `a_nested_shell_wins_and_its_own_children_count`, `a_pid_cycle_or_missing_shell_never_hangs`, `windows_terminal_mixed_or_busy_tabs_are_unknown` | gap | `the_shell_is_rechecked_at_send_time` | `classic_consoles_are_terminals_with_their_shell`, `a_program_running_in_the_shell_makes_it_unknown`, `windows_terminal_is_a_terminal_with_its_tab_shell` | `classic_powershell_console`, `classic_cmd_console`, `busy_shell_reads_unknown`, `windows_terminal` | `q91-pair.sh` (app names) | Now 5 | Mac `CLIKindClassifierTests` |
| Broadcast filter (mirror desktop default, Show all apps, enabled) | `windows_default_shows_terminals_and_hides_disabled_apps`, `testMirrorOnDropsOffScreenDisabledTerminals`, `testMirrorAllAppsIsStrictlyWiderThanMirrorDesktop`, `show_all_apps_widens_the_set`, `a_disabled_terminal_off_every_display_is_not_sent` | `broadcast_filter_vectors` | `show_all_apps_rebroadcasts_with_every_window`, `only_windows_the_phone_is_shown_can_be_driven` | gap | gap | `q91-pair.sh` (no Notepad) | Now 7 | Shared `MirrorDesktopFilterTests`; Mac `QAModeBroadcastTests` |
| toggle_enabled and its persistence | `toggle_sticks_across_polls_and_is_reapplied_by_key`, `enabled_app_joins_the_set_and_disabled_terminal_stays`, `overrides_for_other_windows_are_kept`, `enabled_override_is_last_write_wins` | gap | `toggle_enabled_flips_rebroadcasts_and_persists` | gap | gap | gap | gap | Mac `WindowEnabledMemoryTests` |
| frontmost_changed | `frontmost_tracked_and_untracked`, `test_frontmostChanged_nilWindowIdIsOmitted` | `wire_fixtures_decode_and_reencode_with_the_same_shape` (`frontmost_changed.null.json`) | `frontmost_follows_the_foreground_and_omits_untracked` | `foreground_window_names_its_owner` | `foreground_window_owner` | gap | gap | Mac `FrontmostMatchTests`; iOS `RecencyWriteCoalescerTests` |
| Window colours | `new_windows_take_palette_colors_in_order`, `a_freed_color_is_reused_first`, `colors_are_stable_per_id` | `window_color_vectors` | gap | gap | gap | gap | gap | Shared `WindowColorTests`; Mac `WindowColorOverrideTests` |

### 3.3 Pairing and the tray

| Feature | Unit | Vec | Int | Win32 | Self | Sim | Owner | Mac/iOS twin |
|---|---|---|---|---|---|---|---|---|
| Pairing link and QR | `testRoundTripPreservesURLAndPIN`, `testEncodedURLHasQuipPairShapeAndStrippedPadding`, `pairing_url_prefers_lan`, `the_matrix_reads_back_as_the_link`, `the_qr_carries_the_first_lan_url_and_the_pin`, `tailscale_only_when_there_is_no_lan_and_the_port_is_kept`, `pairing_link_is_loopback` | `pairing_vectors` | gap | `the_qr_window_opens_is_reused_is_never_listed_and_closes_on_esc` | `pairing_qr_window` | `q91-pair.sh` (link) | Now 3-4 | Shared `PairingPayloadTests`; Mac `PairingQRTests` |
| Bonjour (`_quip._tcp.`, TXT `did`, LAN addresses only) | `service_type_and_txt_match_the_mac`, `service_name_is_quip_and_the_pc_name`, `host_name_is_one_dns_label_in_local`, `only_lan_addresses_are_announced`, `a_vethernet_address_never_reaches_the_advert`, `no_lan_address_means_no_advert`, `no_lan_address_is_logged_and_nothing_is_advertised` | gap | gap | `the_advertiser_starts_is_seen_on_the_lan_and_stops` | gap | gap (fake never advertises) | Now 3 (phone discovers the PC) | iOS `BonjourAddressPickerTests`, `BackendConnectionManagerURLMergeTests` |
| Tray menu items | `the_menu_lists_spec_6_in_order`, `toggles_carry_their_state_and_every_item_is_enabled`, `status_line_counts_phones`, `pin_is_grouped_by_four`, `addresses_line_shows_only_lan_and_tailscale`, `action_ids_round_trip_and_zero_is_no_action`, `corners_are_clear_the_middle_is_the_disc_and_the_ring_is_white` | gap | `client_count_follows_auth_and_disconnect` | `the_tray_icon_is_added_and_removed` | gap | gap | Now 2, 7 | Mac `WindowRowMenuTests` (shape only) |
| Settings (`settings.toml`, `.bad`, read retry, save failure) | `first_run_creates_the_file_with_an_8_digit_pin`, `second_run_loads_the_same_pin_and_device_id`, `corrupt_file_is_moved_to_bad_and_a_new_pin_is_made`, `unusable_values_count_as_corrupt`, `a_read_error_retries_then_fails_without_a_new_pin_or_quarantine`, `a_file_without_a_port_gets_8765`, `first_run_creates_settings_serves_and_persists_tray_changes`, `a_second_start_keeps_the_pin_and_device_id`, `unreadable_settings_stop_the_start_and_mint_nothing` | gap | `a_failed_settings_save_is_logged`, `a_corrupt_prefs_file_is_moved_aside_with_a_log_line` | gap | gap | gap | Now 8 | Mac `PINStoreTests`, `PreferenceRestoreRoutingTests` |
| Phone prefs backup | `stores_per_device_and_returns_as_is`, `a_newer_snapshot_replaces_the_older`, `test_preferencesSnapshot_keepsUnknownKeys`, `test_preferenceRestore_noBackupIsEmptyObject` | `wire_fixtures_decode_and_reencode_with_the_same_shape` (`preferences_*.json`) | `preferences_snapshot_is_stored_and_returned_as_is_to_the_asker_only`, `no_backup_mode_answers_empty` | gap | gap | gap | gap | Mac `PreferenceRestoreRoutingTests`; iOS `PreferencesFreshnessTests` |
| Start with Windows (HKCU Run) | `the_value_is_the_quoted_exe_path`, `points_at_accepts_quoted_unquoted_and_any_case`, `the_selftest_round_trips_its_own_value_name`, `the_run_key_is_the_per_user_one` | gap | gap | `start_with_windows_writes_and_removes_the_run_value` | `start_with_windows_round_trip` | gap | S12 step 10 (reboot) | Mac `LaunchHookTests` (launch at login, shape) |
| Single instance | `the_mutex_is_per_session` | gap | gap | `a_second_launch_exits_with_0_within_a_second` | gap | gap | Now 2 | Mac `SingleInstanceGuardTests` |
| New PIN disconnects every phone | gap | gap | `tray_new_pin_closes_every_phone_and_only_the_new_pin_gets_back_in`, `new_pin_keeps_connected_phones_and_is_required_next_time` (host-level `set_pin` only) | gap | gap | gap | Now 9 | none (deliberate difference: the Mac keeps phones connected) |
| Device id | `generated_ids_are_v4_upper_and_unique`, `fake_id_is_valid_and_not_fake_macs`, `uuid_encodes_upper_case_like_swift` | `wire_fixtures_decode_and_reencode_with_the_same_shape` (`device_identity.*`) | `right_pin_gets_auth_result_identity_layout_in_that_order` | gap | gap | `q91-two-backends.sh` | Now 4 | iOS `BackendConnectionManagerURLMergeTests` |

### 3.4 Logs

| Feature | Unit | Vec | Int | Win32 | Self | Sim | Owner | Mac/iOS twin |
|---|---|---|---|---|---|---|---|---|
| Log files, rotation, disk full | `ten_megabyte_cap`, `append_rotates_at_the_cap_then_starts_fresh`, `exactly_at_cap_is_not_rotated`, `full_disk_never_panics`, `read_only_directory_never_panics`, `each_file_gets_its_format`, `a_log_call_never_waits_for_the_disk`, `files_live_in_the_dir`, `missing_env_falls_back_to_temp` | gap | `successful_sends_and_quick_actions_write_latency_lines_with_counts_only` | gap | gap | `q91-send.sh` (reads latency.log, injection.log) | Now 10 | Mac `QuipLogTests`, `LogRotationTests` |
| injection.log line format | `kind_is_a_closed_vocabulary`, `op_window_and_app_never_contain_spaces`, `testQuotesAndNewlinesCannotForgeASecondLine`, `file_line_is_timestamped_and_redacted` | `injection_log_vectors` | `a_phone_supplied_action_with_line_breaks_cannot_forge_a_log_line`, `window_gone_is_an_error_and_a_log_line_and_types_nothing` | gap | gap | `q91-send.sh` | S11 step 4 | Mac `InjectionLogTests` |
| phone.log | `test_eachPhoneLineBecomesOneStampedRow`, `test_embeddedNewlinesCannotForgeRows`, `test_longLinesAndFloodsAreCapped`, `secrets_are_redacted` | `wire_fixtures_decode_and_reencode_with_the_same_shape` (`phone_log.*`) | `select_minimize_close_and_phone_log` | gap | gap | gap | gap | Mac `PhoneLogSinkTests`; iOS `PhoneLogBufferTests` |
| Redaction (logs and selftest report) | `redacts_auth_pin_in_websocket_envelope`, `redacts_bearer_token`, `test_redactIPv4_lanAddress_masksLastTwoOctets`, `user_machine_and_profile_never_reach_the_report`, `titles_of_windows_it_did_not_open_are_dropped_and_its_own_kept`, `ip_addresses_are_masked_and_versions_and_times_kept`, `the_formatted_report_is_redacted_as_a_whole` | gap | gap | gap | every report (header redacted) | gap | Now 3 (read the report before sending) | Mac `LogRedactorTests` |
| Windows log paths (`%LOCALAPPDATA%\Quip\Logs`) on the real PC | `files_live_in_the_dir` | gap | gap | gap | report path | gap | Now 10 | planned in S12 (`CLAUDE.md` log section) |

### 3.5 Actions on windows

| Feature | Unit | Vec | Int | Win32 | Self | Sim | Owner | Mac/iOS twin |
|---|---|---|---|---|---|---|---|---|
| Arrange [S10] | `tiles_touch_and_fill_the_work_area`, `pixel_rects_are_within_one_px_of_the_mac_fractional_rects`, `work_area_excludes_the_taskbar_on_any_edge`, `border_compensation_grows_by_each_edge`, `compensated_neighbours_have_touching_visible_edges`, `arrange_tiles_the_windows_the_phone_shows_on_the_primary_work_area`, `moves_keep_the_border_and_refusals_do_not_stop_others` | `arrange_vectors` | `arrange_tiles_the_windows_the_phone_shows`, `arrange_with_nothing_shown_says_so` | planned in S10 (two windows, ≤1 px gap, fill the work area) | planned in S10 | `q91-arrange.sh` | S12 step 5 | Shared `ArrangeLayoutMappingTests`; Mac `ArrangeOutcomeTests`, `LayoutPresetStoreTests` |
| Select, minimize, close | `close_and_minimize`, `test_minimizeAndClose_decode`, `acting_on_a_window_says_what_is_missing` (Windows only), `a_dead_window_is_gone` (Windows only) | `wire_fixtures_decode_and_reencode_with_the_same_shape` (`select_window`, `minimize_window`, `close_window`) | `select_minimize_close_and_phone_log` | planned in S11 | planned in S11 | gap | S11 step 1 | Mac `WindowRaisePolicyTests` |
| Focus (5.3 sequence, pid check) [S11] | `focus_reports_the_step_and_refusal`, `every_call_checks_the_pid_still_owns_the_handle`, `focus_step_is_reported`, `a_gone_or_reused_window_fails_at_focus`, `the_target_must_match_by_pid_too` | gap | `focus_refused_types_nothing_errors_and_logs`, `the_focus_step_that_worked_is_logged` | planned in S11 (window behind another comes to front) | planned in S11 | gap | S11 step 2 | Mac `WindowRaisePolicyTests`; Shared `KeystrokeFocusDelayTests` |
| Typing (unicode, 64-input batches, focus guard, short insert) [S11] | `surrogate_pairs_are_two_units_and_never_split`, `focus_is_checked_before_every_batch`, `focus_lost_stops_and_reports_chars_typed`, `a_short_insert_stops_typing_and_counts_whole_chars`, `focus_is_checked_before_every_key`, `a_short_insert_stops_typing_and_never_presses_return`, `input_blocked_is_unknown_with_the_elevated_detail` | gap | `single_line_with_return_types_text_then_return_and_acks`, `duplicate_message_id_types_once`, `focus_lost_mid_text_stops_and_nothing_reaches_the_other_window`, `a_short_insert_stops_with_an_error_and_no_ack`, `ack_only_on_success_and_only_with_a_message_id`, `ack_timings_measure_the_injection` | planned in S11 (marker plus emoji typed, read back from a file) | planned in S11 | `q91-send.sh` | S11 steps 3-5 | Mac `KeystrokeInjectorWriteExpressionTests`, `SendTextSelfHealTests`, `MessageDedupeTableTests` |
| Multi-line rule (Shift+Enter in PowerShell, refuse cmd/unknown, Return dropped) [S11] | `windows_multi_line_powershell_splits_and_never_returns`, `windows_multi_line_cmd_and_unknown_are_refused`, `windows_one_trailing_newline_is_stripped_and_single_line_even_in_cmd`, `crlf_is_one_break_and_u2028_is_a_break`, `multi_line_uses_shift_enter_and_no_return`, `the_shell_is_read_at_send_time_and_a_program_in_it_refuses_multi_line` | `multiline_vectors_mac_policy`, `multiline_vectors_windows_rule_on_the_shell_cases` | `multi_line_into_powershell_uses_shift_enter_and_drops_the_return`, `multi_line_into_cmd_is_refused_and_nothing_is_typed`, `the_shell_is_rechecked_at_send_time` | planned in S11 (two lines, file must not exist after 2 s) | planned in S11 | `q91-send.sh` | S11 steps 6-7 | Mac `MultiLineSendPolicyTests` |
| Keys (quick_action table 5.5) [S11] | `spec_5_5_table`, `every_supported_action_maps`, `unknown_and_mac_only_actions_are_unsupported`, `input_count_is_a_down_and_up_per_key_and_modifier`, `a_blocked_chord_is_input_blocked` | `wire_fixtures_decode_and_reencode_with_the_same_shape` (`quick_action.*`) | `quick_actions_press_the_spec_keys_after_focusing`, `quick_action_focus_refused_presses_nothing` | planned in S11 | planned in S11 | `q91-keys.sh` | S11 step 8 | Mac `Iterm2ScrollKeystrokeTests` (shape); key table in `QuipMacApp.swift` has no unit test |
| Elevated target types nothing [S11] | `input_blocked_is_unknown_with_the_elevated_detail`, `fully_blocked_input_types_nothing_and_stops` | gap | `a_short_insert_stops_with_an_error_and_no_ack`, `a_dead_input_lane_says_so_not_elevated` | planned in S11 (CI runner is admin: see section 5) | planned in S11 | gap | S11 step 9 | none (macOS has no UIPI) |
| request_content reply | `request_content_decodes_and_terminal_content_has_the_swift_keys` | `terminal_content_matches_the_swift_encoding` | `request_content_gets_the_not_available_text_for_shown_windows_only` | gap | gap | gap | gap | Mac `TerminalContentWindowTests` |
| Hang guard (platform lane never blocks the tray or reactor) | `a_blocked_input_lane_does_not_block_queries`, `jobs_on_a_lane_run_in_order`, `run_does_not_wait_for_a_slow_job` | gap | `a_send_text_blocked_5s_does_not_delay_heartbeats_or_another_phones_layout` | gap | gap | gap | gap | Mac `TerminalStateDetectorMainThreadTests` |

### 3.6 Network paths and release

| Feature | Unit | Vec | Int | Win32 | Self | Sim | Owner | Mac/iOS twin |
|---|---|---|---|---|---|---|---|---|
| LAN addresses (`localURLs`, virtual adapters dropped) | `tailscale_and_link_local_never_reach_local_urls`, `urls_use_the_given_port_and_dedupe`, `virtual_adapters_are_dropped_by_name_or_description`, `real_adapter_names_are_kept`, `testAcceptsRFC1918Ranges`, `testRejectsNonLAN` | gap | gap | gap | gap | gap | Now 3 | Mac `LocalAddressesTests`; iOS `LinkLocalRecoveryTests` |
| Tailscale path (`100.x` shown, QR falls back to it) | `tray_splits_lan_from_tailscale_and_drops_the_rest`, `tailscale_only_when_there_is_no_lan_and_the_port_is_kept`, `test_redactIPv4_tailscaleCgnat_masksLastTwoOctets` | gap | gap | gap | gap | gap | Now 11-12 | iOS `URLSwapPolicyTests`, `LatencySwapComparabilityTests` |
| Port in use, bind errors | `port_in_use_is_a_clear_error`, `a_busy_port_is_a_bind_error`, `port_8765_and_0_are_refused` (fake only) | gap | gap | gap | gap | gap | gap | Mac `ListenPortTests` |
| Release build and install [S12] | gap | gap | gap | gap | header shows version and git sha (`no_git_sha_or_windows_version_still_reads`) | gap | S12 steps 1-2 | none; planned in S12 (`tools/build-windows.sh` checks DLL imports) |
| Fake platform safety | `defaults_are_safe`, `a_fixture_named_like_a_real_display_is_refused`, `a_log_dir_inside_the_real_logs_is_refused`, `a_symlink_into_the_real_logs_is_refused`, `shipped_fixture_is_valid_and_fake` | gap | gap | gap | gap | every script | n/a | `tools/fake-mac` (no tests) |

## 4. Known gaps and what closes each

1. **iOS suite is blocked (Q-92).** `xcodebuild` cannot open the generated
   QuipiOS project on this Mac, so `Shared/Tests/WireFixtureTests` and the
   other Shared tests have never run in the iOS target. Closes when Q-92 is
   fixed and `tools/check.sh --files - <<< 'Shared/Tests/Fixtures/wire/index.json'`
   reports QuipiOS green.
2. **Phone 1.6.0 untested against the host.** Simulator QA ran 1.5.7
   only. The owner's phone is 1.6.0. Closes when Q-92 is fixed, 1.6.0 is
   installed on the simulator clone, and all six `q91-*.sh` scripts exit 0
   again. Until then, owner step "Now 4-7" is the only 1.6.0 evidence.
3. **The real PC has never run Quip.** Every Win32 result so far is from the
   CI runner. Closes with the "Now" script in section 6 and its selftest
   report saved under `docs/superpowers/evidence/q91/`.
4. **Windows 10 vs 11.** CI is Windows Server 2025 (build 26100, Windows 11
   code base). Windows 10 (build 19045 and older) is untested: DWM frame
   bounds, cloaking and the conhost owner can differ. Closes when a selftest
   report from a Windows 10 machine is saved. No CI runner offers Windows 10
   desktop images; mark it untested in the release notes until then.
5. **Multi-monitor and mixed DPI.** CI has one 1024x768 display at 96 DPI.
   `display_geometry_vectors` covers two displays in math only. Closes when
   the owner's selftest header shows two or more displays and
   `frames_inside_0_to_1` passes, and S12 step 5 (arrange) is done with a
   second monitor at a different scale. If the PC has one monitor, this stays
   open.
6. **Default terminal: Windows Terminal vs conhost.** On Windows 11 the
   default terminal can be Windows Terminal, so `cmd /c start powershell`
   may open a WT window, not a `ConsoleWindowClass` one. CI has conhost as
   default. Closes when the owner's selftest shows `classic_powershell_console`
   and `windows_terminal` both PASS with the PC's setting, and the setting is
   written in the report. A FAIL here with WT as default is a test-harness
   finding, not a host bug; record it and fix the case.
7. **PowerShell 5.1 vs 7.** CI ran PSReadLine 2.4.5 under Windows PowerShell
   5.1 (M0). `pwsh.exe` is classified (`conhost_with_each_shell`) but
   Shift+Enter in PowerShell 7 was never run. Closes with an S11 selftest case
   for `pwsh` (planned, SKIP when not installed) plus owner S11 step 6 in a
   PowerShell 7 tab, if installed.
8. **Elevated windows.** The CI runner user is an administrator, so UIPI
   never blocks it. The elevated path is tested only with the fake
   (`input_blocked_is_unknown_with_the_elevated_detail`). Closes with owner
   S11 step 9 (an Administrator PowerShell, Quip not elevated) and S12 step 9.
9. **Non-English keyboard layouts.** `KEYEVENTF_UNICODE` ignores the layout
   for text, but `press_y` / `press_n`, Ctrl+C and `cls` use virtual keys.
   Untested on any layout but US. Closes with owner S11 step 8 repeated with
   a second input language (for example German, where Y and Z swap), if the
   owner uses one. Otherwise record it as untested.
10. **IPv6 crowd-out (spec 3.1).** The host listens on IPv4 only, on purpose.
    A future IPv6 listener would let a /64 neighbour fill all 8 network slots
    with queued wrong PINs and refuse the owner. Pinned by
    `the_real_host_listens_on_ipv4_only`. Before anyone adds IPv6: cap queued
    wrong PINs per network below `max_unauthenticated_per_network` or reserve
    a slot for a sender holding none, and add an integration test for it.
    Not a phase 1 gap; a tripwire.
11. **Heartbeat on the phone side.** No iOS test covers `heartbeat` /
    `heartbeat_ack`. The host side is covered. Owner step "Now 6" is the only
    end-to-end check. Closes with an iOS unit test after Q-92.
12. **Rate-limit parity.** The Mac's `allowMessage` has no unit test, so
    `the_phones_connect_burst_is_not_rate_limited` cannot be compared to a
    Mac twin. Open; low risk.
13. **Real Tailscale path.** Only unit tests cover the `100.x` address.
    Closes with owner step "Now 11-12".
14. **Known mutation survivors** (section 2, L8). Close each with a test or a
    written equivalence reason before the S12 release.

## 5. PC environment matrix

| Property | CI runner (`windows-latest`) | Owner's PC | Simulator QA (Mac) |
|---|---|---|---|
| OS | Windows Server 2025, build 26100 | Windows 10 or 11, build in the selftest header | macOS, fake platform |
| Display | 1, 1024x768, work area 1024x720, 96 DPI (100%) | real monitors and scales | fixture `FakeWindows Display` |
| User | administrator, interactive desktop | normal user (expected) | n/a |
| Default terminal | conhost | WT or conhost (owner's setting) | fixture |
| Shells | Windows PowerShell 5.1 (PSReadLine 2.4.5), cmd, WT present | whatever is installed | fixture |
| Network | no LAN peer, no phone, no Tailscale | home LAN, Tailscale, the phone | 127.0.0.1 only |
| Firewall | not exercised | Windows Defender Firewall prompt | n/a |

What the CI runner **can** prove:

- Listing, classify, displays, frames, foreground owner, tray icon, single
  instance, Run value round trip, QR window, Bonjour advert seen in-process.
- After S10/S11: arrange gaps on one display, focus, `SendInput` typing,
  Shift+Enter multi-line in PowerShell 5.1, the focus-stolen guard. M0 proved
  focus and typing work there (run 42319562616).
- Every push: fmt, clippy, unit, integration and vector tests natively.

What the CI runner **cannot** prove:

- That the phone pairs over a real network, through the firewall.
- Multi-monitor, mixed DPI, a taskbar on a side edge.
- Windows 10 behavior.
- The elevated (UIPI) path: the runner is an administrator.
- A user's default terminal set to Windows Terminal.
- SmartScreen, the firewall prompt, reboot with Start with Windows.
- Tailscale.

What the owner's PC **can** prove: everything above that CI cannot, plus that
the real phone app (1.6.0) works with the host.

What the owner's PC **cannot** prove: repeatability on every change (it runs
when the owner runs it), and the fault-injection cases (pre-auth eviction,
throttle maths, disk full). Those stay in L1/L3.

What simulator QA **can** prove: the phone app's UI reacts to the host's
messages (pair, grid, send, keys, two backends). **Cannot**: anything Win32,
anything on 1.6.0 until Q-92.

## 6. Owner PC test script

Before each session, the builder gives the owner one `Quip.exe` that passed
section 7. Steps are numbered per gate. Each says what to do, what should
happen, and what to send back. Send files, not screenshots of files, where a
file exists. Read every file before sending it: it must hold no PC name, user
name or IP (the report redacts them; say so if one slipped through).

Files to send back live in `%LOCALAPPDATA%\Quip\Logs\`:
`selftest-<time>.txt`, `websocket.log`, and later `injection.log`,
`latency.log`.

### Gate "Now" (after S9: pairing, grid, selftest, Tailscale)

Select, minimize, close, arrange, typing and keys are not built on Windows yet
(`NotImplemented`). The phone shows an error for them. That is expected now.

1. Copy `Quip.exe` to `%LOCALAPPDATA%\Programs\Quip\`. Double-click it.
   Expected: SmartScreen "Windows protected your PC". Click More info, then
   Run anyway.
2. Expected: a Quip tray icon, no console window. Double-click `Quip.exe`
   again. Expected: nothing new; still one tray icon.
3. Windows Defender Firewall asks about access. Allow on **Private**
   networks. Expected: the tray menu shows `LAN <address>` and, if Tailscale
   runs, `Tailscale 100.x.y.z`.
4. Tray, Show pairing QR. Scan it with the phone. Expected: the PC shows as a
   new backend on the phone. The Mac backend keeps working. The tray first
   line says `1 phone connected`.
5. Open PowerShell in Windows Terminal and in a classic console window.
   Expected: both show on the phone as terminals within 2 s, with app names
   (`Windows Terminal`, `PowerShell`). Minimize one: it stays, marked
   minimized. Close one: gone within 2 s.
6. Leave the phone paired and idle for 2 minutes. Expected: still connected,
   no reconnect.
7. Open Notepad. Expected: not on the phone. Tray, Show all apps: it
   appears. Turn Show all apps off again.
8. Tray, Quit Quip. Start it again. Expected: same PIN, the phone reconnects
   without a new pairing.
9. Tray, New PIN (disconnects phones). Expected: the phone loses the
   connection at once. Pair again with the new QR; it connects.
10. Run the selftest: open cmd in the Quip folder, run
    `start /wait Quip.exe --selftest`. Expected: every line `PASS`, last line
    `SUMMARY PASS`. Send `selftest-<time>.txt`. Also say whether the default
    terminal is Windows Terminal or Windows Console Host (Settings, System,
    For developers, Terminal).
11. Tailscale path: on the phone, turn Wi-Fi off (cellular plus Tailscale
    on). Expected: the PC row reconnects through its `100.x` address within
    30 s and the grid shows.
12. Turn Wi-Fi back on. Expected: still connected. Send `websocket.log`.

### Gate "After S11" (typing, keys, multi-line)

Repeat "Now" step 10 first (the selftest gains typing cases). Then:

1. From the phone, tap a PowerShell card. Expected: that window comes to the
   front.
2. Put Notepad in front of the PowerShell window. Send text to PowerShell
   from the phone. Expected: PowerShell comes to the front and gets the text;
   Notepad gets nothing.
3. Dictate `Get-Date` with Return into the Windows Terminal window, then into
   the classic window. Expected: it runs in that window only.
4. Close a window, then send to its stale card at once. Expected: nothing is
   typed anywhere, the phone shows an error, `injection.log` has a
   `kind=windowClosed` line.
5. Dictate a line with emoji and accented letters (for example
   `echo café 🙂`). Expected: exactly that text appears.
6. Dictate two lines with Return into PowerShell (and into PowerShell 7, if
   installed). Expected: both lines sit in the prompt, nothing runs. Press
   Return on the PC: both run.
7. Dictate two lines into a cmd window. Expected: nothing typed, the phone
   shows a refusal, `injection.log` has `multi-line not safe in this shell`.
8. Run `ping -t localhost`. Tap Ctrl+C on the phone. Expected: ping stops.
   Also try Esc, Tab, Up, Down, Return. If the PC has a second keyboard
   layout, repeat Ctrl+C and `press_y` with it active.
9. Open PowerShell as Administrator. Send text to it. Expected: nothing typed
   anywhere, the phone shows an error, `injection.log` has
   `input blocked (elevated window?)` or `focus refused`.
10. Send `selftest-<time>.txt`, `injection.log`, `latency.log`,
    `websocket.log`.

### Gate "After S12" (spec 11, all 10 checks)

Use the release `Quip.exe` from `tools/build-windows.sh` (planned in S12).

1. Run `Quip.exe`: tray icon, no console window. A second launch does
   nothing.
2. `start /wait Quip.exe --selftest`: every line PASS. Send the file.
3. The phone pairs with the QR. The PC is a second backend; the Mac backend
   keeps working.
4. PowerShell in Windows Terminal and in a classic window both show as
   terminals within 2 s. Close one: gone within 2 s.
5. Arrange side by side, then stacked, from the phone (or the scripted peer
   if the phone has no control for it). Expected: no gaps, nothing under the
   taskbar. With two monitors, only the primary is used.
6. Dictate `Get-Date` with Return into each: it runs in that window, no
   other.
7. Dictate two lines with Return: both sit in the prompt, nothing runs.
8. Ctrl+C from the quick buttons stops `ping -t localhost`.
9. Administrator PowerShell: sending text types nothing anywhere, the phone
   shows an error, `injection.log` has a line.
10. Turn on Start with Windows. Reboot. Expected: Quip is in the tray and the
    phone reconnects. Send `websocket.log`.

### Failure triage

Run these in PowerShell on the PC and send the output (remove IPs if you
prefer; say which line was which).

- **The phone cannot connect.**
  1. Is Quip listening? `netstat -an | findstr 8765`. Expected:
     `TCP 0.0.0.0:8765 ... LISTENING`. No line: Quip is not running, or
     `websocket.log` says the port is in use.
  2. Is the network Private? `Get-NetConnectionProfile`. A `Public`
     `NetworkCategory` on the Wi-Fi or Ethernet adapter blocks the phone.
     Fix: Settings, Network, the adapter, Private.
     Note: Tailscale sets its own adapter to Private, so the Tailscale path
     can work while the LAN path fails. That points at the LAN profile, not
     at Quip.
  3. Is the firewall rule there and allowing?
     `Get-NetFirewallApplicationFilter -Program "$env:LOCALAPPDATA\Programs\Quip\Quip.exe" | Get-NetFirewallRule | Format-Table DisplayName,Enabled,Profile,Direction,Action`.
     Expected: an inbound `Allow` rule whose `Profile` includes `Private`.
     A `Block` rule (a "Cancel" on the prompt) must be deleted in Windows
     Defender Firewall, then Quip restarted.
  4. Did the phone reach Quip? `websocket.log`: a connect line with no
     `auth ok` means PIN or throttle; no connect line means network or
     firewall.
- **A selftest case FAILs.** Send the whole report. Its detail lines name the
  rule that dropped a window, or the process tree. Do not re-run more than
  once before sending.
- **Windows are missing on the phone.** Check Show all apps. Send the
  selftest report: `frames_inside_0_to_1` and the console cases show what
  the lister sees.
- **Typing went nowhere (after S11).** Send `injection.log`. Each failure is
  one `DROPPED` line with `kind`.

## 7. Release gate

No build goes to the owner until all of these hold, on the commit the
`Quip.exe` is built from:

1. `tools/check.sh --since <last owner build>` green for scope `windows`
   (fmt, clippy host and `x86_64-pc-windows-gnu`, `cargo test`), and the
   QuipMac suite green if `Shared/` changed. Every SKIPPED line is named in
   the handoff, never counted as green.
2. Windows CI run on that commit green: steps fmt, clippy, test, Win32 UI
   tests (`QUIP_WIN_UI=1`), Selftest (exit 0, so no FAIL and no SKIP). The
   `selftest-report` artifact is saved under `docs/superpowers/evidence/q91/`
   with the run id in its name.
3. `bash .github/scripts/changed-scopes-test.sh` passes.
4. Simulator QA: the six `tools/qa/q91-*.sh` scripts exit 0 on our own
   simulator clone, with screenshots saved. Today on 1.5.7; on 1.6.0 once
   Q-92 is fixed.
5. Mutation results for every changed pure module are in the commit
   messages. No new survivor without a test or an equivalence reason.
6. Independent review of the slice diff done; every finding fixed or
   answered in the commit message. S11 also gets a silent-failure pass.
7. The `.exe` imports only Windows system DLLs:
   `x86_64-w64-mingw32-objdump -p Quip.exe | grep "DLL Name"` (no `libgcc`,
   `libwinpthread`). Its selftest header shows the commit's git sha.
8. The plan file (`docs/superpowers/plans/2026-11-06-q91-windows-host.md`)
   and board row Q-91 name the commit and CI run id the build came from.
9. No PC name, user name, IP, email or device name in anything committed
   from the owner's files.
