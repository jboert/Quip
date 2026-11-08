//! Spec 10.4: the real server on a random loopback port, a real WebSocket
//! client as the phone, the fake platform as the PC.

mod common;

use std::time::{Duration, Instant};

use common::*;
use futures_util::StreamExt;
use quip_windows::host::HEARTBEAT_INTERVAL;
use quip_windows::platform::fake::{FakeCall, Typed};
use quip_windows::platform::traits::{FocusStep, InputAccess};
use quip_windows::protocol::limits::MAX_MESSAGE_BYTES;
use quip_windows::services::keys::{Key, KeyChord};
use serde_json::json;
use tokio_tungstenite::tungstenite::Message;

const QUIET: Duration = Duration::from_millis(300);
const ID_A: &str = "6BA7B810-9DAD-11D1-80B4-00C04FD430C8";
const ID_B: &str = "7BA7B810-9DAD-11D1-80B4-00C04FD430C8";

// --- auth (spec 3.1) ---

#[tokio::test]
async fn right_pin_gets_auth_result_identity_layout_in_that_order() {
    let h = start().await;
    let mut p = connect(h.addr).await;
    let greet = p.recv().await;
    assert_eq!(greet, json!({"type":"auth_result","success":false,"error":"auth_required"}));
    p.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(p.recv().await, json!({"type":"auth_result","success":true}));
    let id = p.recv().await;
    assert_eq!(id["type"], "device_identity");
    assert_eq!(id["deviceKind"], "windows");
    assert_eq!(id["deviceID"], DEVICE_ID);
    assert_eq!(id["localURLs"], json!(["ws://192.0.2.10:8765"]));
    let layout = p.recv().await;
    assert_eq!(layout["type"], "layout_update");
    assert_eq!(layout["monitor"], "FakeWindows Display");
    let names: Vec<&str> = layout["windows"].as_array().unwrap().iter().map(|w| w["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["pwsh one", "cmd two"], "terminals ride out; Notepad does not");
    assert!(layout["windows"].as_array().unwrap().iter().all(|w| w["enabled"] == false && w["cliKind"] == "shell"));
    let front = p.recv().await;
    assert_eq!(front["type"], "frontmost_changed");
    assert_eq!(front["windowId"], h.window_id(101));
    assert!(h.log("websocket.log").contains("auth ok"));
    assert!(!h.log("websocket.log").contains(PIN), "the PIN never reaches a log");
}

#[tokio::test]
async fn wrong_pin_fails_after_the_throttle_delay() {
    let h = start_with(Opts { real_sleeper: true, ..Default::default() }).await;
    let mut p = connect(h.addr).await;
    p.recv().await;
    let t0 = Instant::now();
    p.send(json!({"type":"auth","pin":"00000000"})).await;
    let r = p.recv().await;
    assert_eq!(r, json!({"type":"auth_result","success":false,"error":"Incorrect PIN"}));
    assert!(t0.elapsed() >= Duration::from_millis(200), "first failure waits 200 ms ({:?})", t0.elapsed());
    // The socket stays open and a right PIN still works.
    p.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(p.recv().await["success"], true);
    let ws = h.log("websocket.log");
    assert!(ws.contains("len=8") && !ws.contains("00000000") && !ws.contains(PIN));
}

#[tokio::test]
async fn nothing_before_auth_gets_a_reply_or_reaches_the_pc() {
    let h = start().await;
    let mut p = connect(h.addr).await;
    p.recv().await; // auth_required
    let wid = h.window_id(101);
    for m in [
        json!({"type":"select_window","windowId":wid}),
        json!({"type":"send_text","windowId":wid,"text":"rm -rf","pressReturn":true}),
        json!({"type":"quick_action","windowId":wid,"action":"press_return"}),
        json!({"type":"preferences_request","deviceID":"d"}),
        json!({"type":"close_window","windowId":wid}),
    ] {
        p.send(m).await;
    }
    p.send_raw("not json").await;
    p.assert_silent(QUIET).await;
    assert!(h.fake.calls().is_empty(), "{:?}", h.fake.calls());
}

#[tokio::test]
async fn ten_failures_lock_out_even_the_right_pin() {
    let h = start().await;
    let mut p = connect(h.addr).await;
    p.recv().await;
    for _ in 0..10 {
        p.send(json!({"type":"auth","pin":"99999999"})).await;
        assert_eq!(p.recv().await["error"], "Incorrect PIN");
    }
    let delays: Vec<u64> = h.sleeper.delays.lock().unwrap().iter().map(|d| d.as_millis() as u64).collect();
    assert_eq!(delays, [200, 400, 600, 800, 1000, 1200, 1400, 1600, 1800, 0]);
    p.send(json!({"type":"auth","pin":PIN})).await;
    let r = p.recv().await;
    assert_eq!(r["success"], false);
    assert!(r["error"].as_str().unwrap().starts_with("Too many attempts; try again in "), "{r}");
    // A second socket from the same host is locked too.
    let mut q = connect(h.addr).await;
    q.recv().await;
    q.send(json!({"type":"auth","pin":PIN})).await;
    assert!(q.recv().await["error"].as_str().unwrap().starts_with("Too many attempts"));
    assert!(!h.host.is_authenticated(1));
}

#[tokio::test]
async fn malformed_auth_is_answered_not_fatal() {
    let h = start().await;
    let mut p = connect(h.addr).await;
    p.recv().await;
    p.send(json!({"type":"auth"})).await;
    assert_eq!(p.recv().await["error"], "Malformed auth message");
    p.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(p.recv().await["success"], true);
}

// --- broadcast (spec 3.2) ---

#[tokio::test]
async fn window_open_move_close_each_broadcast_once_and_no_change_is_silent() {
    let h = start().await;
    let (mut a, _) = paired(h.addr).await;
    let (mut b, _) = paired(h.addr).await;

    h.host.poll_tick().await;
    a.assert_silent(QUIET).await;
    b.assert_silent(Duration::from_millis(50)).await;

    let mut w = quip_windows::platform::fake::window_from_fixture(
        &serde_json::from_value(json!({"handle":200,"pid":9,"title":"new pwsh","className":"ConsoleWindowClass",
            "shells":["pwsh.exe"],"visible":{"x":10,"y":10,"width":400,"height":300}}))
        .unwrap(),
    );
    w.is_minimized = false;
    h.fake.add_window(w);
    h.host.poll_tick().await;
    for p in [&mut a, &mut b] {
        let l = p.recv().await;
        assert_eq!(l["type"], "layout_update");
        assert_eq!(l["windows"].as_array().unwrap().len(), 3);
        p.assert_silent(Duration::from_millis(100)).await;
    }

    h.fake.move_window(200, quip_windows::services::layout::PixelRect::new(960, 520, 960, 520));
    h.host.poll_tick().await;
    for p in [&mut a, &mut b] {
        let l = p.recv().await;
        let moved = l["windows"].as_array().unwrap().iter().find(|w| w["name"] == "new pwsh").unwrap().clone();
        assert_eq!(moved["frame"]["x"], 0.5);
        p.assert_silent(Duration::from_millis(100)).await;
    }

    h.fake.remove_window(200);
    h.host.poll_tick().await;
    for p in [&mut a, &mut b] {
        let l = p.recv().await;
        assert_eq!(l["windows"].as_array().unwrap().len(), 2);
    }
    h.host.poll_tick().await;
    a.assert_silent(QUIET).await;
}

#[tokio::test]
async fn frontmost_follows_the_foreground_and_omits_untracked() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_foreground(Some(102));
    h.host.poll_tick().await;
    assert_eq!(p.recv().await, json!({"type":"frontmost_changed","windowId":h.window_id(102)}));
    h.fake.set_foreground(Some(103)); // Notepad: not in the broadcast set
    h.host.poll_tick().await;
    assert_eq!(p.recv().await, json!({"type":"frontmost_changed"}));
    h.host.poll_tick().await;
    p.assert_silent(QUIET).await;
}

#[tokio::test]
async fn a_failing_listing_keeps_the_last_state() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_fail_listing(true);
    h.host.poll_tick().await;
    h.host.poll_tick().await;
    p.assert_silent(QUIET).await;
    assert_eq!(h.host.state().windows().len(), 3);
    assert!(h.log("websocket.log").contains("window listing failed streak=1"));
    h.fake.set_fail_listing(false);
    h.host.poll_tick().await;
    assert!(h.log("websocket.log").contains("recovered after 2"));
}

// --- send_text (spec 5.4) ---

#[tokio::test]
async fn single_line_with_return_types_text_then_return_and_acks() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    p.send(
        json!({"type":"send_text","windowId":h.window_id(101),"text":"Get-Date","pressReturn":true,"messageId":ID_A}),
    )
    .await;
    let ack = p.recv().await;
    assert_eq!(ack["type"], "send_text_ack");
    assert_eq!(ack["messageId"], ID_A);
    assert_eq!(ack["path"], "sendText");
    assert!(ack["totalMs"].as_i64().unwrap() >= ack["injectMs"].as_i64().unwrap());
    assert_eq!(h.fake.typed(101), vec![Typed::Text("Get-Date".into()), Typed::Key(KeyChord::RETURN)]);
    let lat = h.log("latency.log");
    assert!(lat.contains("send_text rid=6BA7B810 path=sendText") && lat.contains("success=1"), "{lat}");
    assert!(!lat.contains("Get-Date"), "text never logged");
    assert!(!lat.contains("multiline_guard"));
}

#[tokio::test]
async fn multi_line_into_powershell_uses_shift_enter_and_drops_the_return() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    p.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"echo one\r\necho two\n","pressReturn":true,"messageId":ID_A}))
        .await;
    assert_eq!(p.recv().await["type"], "send_text_ack");
    assert_eq!(
        h.fake.typed(101),
        vec![Typed::Text("echo one".into()), Typed::Key(KeyChord::SHIFT_ENTER), Typed::Text("echo two".into())],
        "no Return: the block sits on the prompt"
    );
    assert!(h.log("latency.log").contains(" multiline_guard=1 lines=2"));
}

#[tokio::test]
async fn multi_line_into_cmd_is_refused_and_nothing_is_typed() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    p.send(
        json!({"type":"send_text","windowId":h.window_id(102),"text":"dir\ndel x","pressReturn":true,"messageId":ID_A}),
    )
    .await;
    let e = p.recv().await;
    assert_eq!(e["type"], "error");
    assert_eq!(e["messageId"], ID_A);
    assert!(e["reason"].as_str().unwrap().contains("Multi-line"));
    assert!(h.fake.calls().is_empty());
    let inj = h.log("injection.log");
    assert!(inj.contains("kind=unknown") && inj.contains(r#"detail="multi-line not safe in this shell""#), "{inj}");
    assert!(inj.contains("app=Command_Prompt"));
    // Single-line text to cmd is fine.
    p.send(json!({"type":"send_text","windowId":h.window_id(102),"text":"dir","pressReturn":true,"messageId":ID_B}))
        .await;
    assert_eq!(p.recv().await["type"], "send_text_ack");
}

#[tokio::test]
async fn duplicate_message_id_types_once() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let m = json!({"type":"send_text","windowId":h.window_id(101),"text":"x","pressReturn":false,"messageId":ID_A});
    p.send(m.clone()).await;
    p.send(m).await;
    assert_eq!(p.recv().await["type"], "send_text_ack");
    p.assert_silent(QUIET).await;
    assert_eq!(h.fake.typed(101), vec![Typed::Text("x".into())]);
}

#[tokio::test]
async fn window_gone_is_an_error_and_a_log_line_and_types_nothing() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    p.send(json!({"type":"send_text","windowId":"w-dead-1-1","text":"x","pressReturn":true,"messageId":ID_A})).await;
    assert_eq!(p.recv().await, json!({"type":"error","reason":"Window no longer exists","messageId":ID_A}));
    assert!(h.fake.calls().is_empty());
    assert!(h.log("injection.log").contains("op=sendText window=w-dead-1-1 app=- kind=windowClosed"));
}

#[tokio::test]
async fn ack_only_on_success_and_only_with_a_message_id() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    p.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"x","pressReturn":false})).await;
    p.assert_silent(QUIET).await;
    assert_eq!(h.fake.typed(101).len(), 1);
    h.fake.set_refuse_focus(101, true);
    p.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"y","pressReturn":false,"messageId":ID_A}))
        .await;
    assert_eq!(p.recv().await["type"], "error");
    p.assert_silent(QUIET).await;
}

#[tokio::test]
async fn focus_refused_types_nothing_errors_and_logs() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_refuse_focus(102, true);
    p.send(json!({"type":"send_text","windowId":h.window_id(102),"text":"dir","pressReturn":true,"messageId":ID_A}))
        .await;
    assert_eq!(p.recv().await, json!({"type":"error","reason":"Windows refused to focus the window","messageId":ID_A}));
    assert!(h.fake.typed(102).is_empty() && h.fake.typed(101).is_empty());
    assert!(h
        .log("injection.log")
        .contains(r#"kind=unknown msg="Windows refused to focus the window" detail="focus refused""#));
    assert!(h.log("latency.log").contains("success=0"));
}

// --- elevated windows (spec 5.4 step 2b) ---

#[tokio::test]
async fn an_elevated_window_types_nothing_and_says_administrator() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    // UIPI drops the input silently: the fake's own guard is off, so only
    // the injector's integrity check can keep the text out.
    h.fake.set_input_guard(false);
    h.fake.set_input_access(101, InputAccess::Elevated);
    p.send(
        json!({"type":"send_text","windowId":h.window_id(101),"text":"Get-Date","pressReturn":true,"messageId":ID_A}),
    )
    .await;
    let e = p.recv().await;
    assert_eq!(e["type"], "error");
    assert_eq!(e["messageId"], ID_A);
    assert!(e["reason"].as_str().unwrap().contains("administrator"), "{e}");
    p.assert_silent(QUIET).await; // no send_text_ack
    let inj = h.log("injection.log");
    assert!(inj.contains("op=sendText") && inj.contains("kind=unknown"), "{inj}");
    assert!(inj.contains(r#"detail="input blocked (elevated window?)""#), "{inj}");
    assert!(h.log("latency.log").contains("success=0"));
    let calls = h.fake.calls();
    assert!(calls.iter().any(|c| matches!(c, FakeCall::Focus { handle: 101, .. })), "{calls:?}");
    assert!(!calls.iter().any(|c| matches!(c, FakeCall::TypeText { .. } | FakeCall::Key { .. })), "{calls:?}");
    assert!(h.fake.typed(101).is_empty() && h.fake.typed(102).is_empty());
}

#[tokio::test]
async fn a_quick_action_to_an_elevated_window_presses_nothing() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_input_guard(false);
    h.fake.set_input_access(102, InputAccess::Unknown);
    p.send(json!({"type":"quick_action","windowId":h.window_id(102),"action":"press_ctrl_c","messageId":ID_A})).await;
    let e = p.recv().await;
    assert_eq!(e["type"], "error");
    assert!(e["reason"].as_str().unwrap().contains("administrator"), "{e}");
    let inj = h.log("injection.log");
    assert!(inj.contains("op=quickAction"), "{inj}");
    assert!(inj.contains(r#"detail="input blocked (elevated window?) action=press_ctrl_c""#), "{inj}");
    assert!(!h.fake.calls().iter().any(|c| matches!(c, FakeCall::Key { .. } | FakeCall::TypeText { .. })));
}

#[tokio::test]
async fn select_window_on_an_elevated_window_still_focuses() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_input_access(102, InputAccess::Elevated);
    let w102 = h.window_id(102);
    p.send(json!({"type":"select_window","windowId":w102})).await;
    assert_eq!(p.recv().await, json!({"type":"frontmost_changed","windowId":w102}), "focus is not input");
    p.assert_silent(QUIET).await;
    assert!(!h.fake.calls().iter().any(|c| matches!(c, FakeCall::InputAccess { .. })));
}

#[tokio::test]
async fn focus_lost_mid_text_stops_and_nothing_reaches_the_other_window() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_steal_focus(1, 102);
    p.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"z".repeat(100),"pressReturn":true,"messageId":ID_A}))
        .await;
    let e = p.recv().await;
    assert_eq!(e["type"], "error");
    assert!(e["reason"].as_str().unwrap().contains("32"));
    assert_eq!(h.fake.typed(101), vec![Typed::Text("z".repeat(32))]);
    assert!(h.fake.typed(102).is_empty());
    assert!(h.log("injection.log").contains(r#"detail="focus lost after 32 chars""#));
}

#[tokio::test]
async fn the_focus_step_that_worked_is_logged() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_focus_step(FocusStep::AltFallback);
    p.send(json!({"type":"send_text","windowId":h.window_id(102),"text":"ver","pressReturn":true,"messageId":ID_A}))
        .await;
    assert_eq!(p.recv().await["type"], "send_text_ack");
    assert!(h.log("latency.log").contains("focus=alt_fallback"));
}

// --- hang guard ---

/// One reactor thread (`current_thread`): if the blocked `SendInput` ran on
/// it, nothing below could happen until it returned, and every timing
/// assert would fail.
#[tokio::test(flavor = "current_thread")]
async fn a_send_text_blocked_5s_does_not_delay_heartbeats_or_another_phones_layout() {
    let h = start().await;
    let (mut a, _) = paired(h.addr).await;
    let (mut b, _) = paired(h.addr).await;
    h.fake.set_block_typing(Some(Duration::from_secs(5)));
    a.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"slow","pressReturn":false,"messageId":ID_A}))
        .await;
    tokio::time::sleep(Duration::from_millis(100)).await; // the input lane is now stuck

    let t0 = Instant::now();
    h.host.heartbeat_tick();
    let hb = b.recv_type("heartbeat").await;
    assert!(t0.elapsed() < Duration::from_millis(100), "heartbeat took {:?}", t0.elapsed());
    assert!(hb["seq"].as_i64().unwrap() >= 1);

    let t0 = Instant::now();
    let mut c = connect(h.addr).await;
    c.pair().await;
    assert!(t0.elapsed() < Duration::from_millis(100), "new phone's layout took {:?}", t0.elapsed());

    let t0 = Instant::now();
    h.fake.remove_window(102);
    h.host.poll_tick().await;
    let l = b.recv_type("layout_update").await;
    assert_eq!(l["windows"].as_array().unwrap().len(), 1);
    assert!(t0.elapsed() < Duration::from_millis(100), "broadcast took {:?}", t0.elapsed());

    // The slow send still finishes.
    let ack = tokio::time::timeout(Duration::from_secs(8), a.recv_type("send_text_ack")).await.unwrap();
    assert_eq!(ack["messageId"], ID_A);
}

// --- heartbeat ---

#[tokio::test]
async fn heartbeat_every_15s_with_the_injected_clock() {
    assert_eq!(HEARTBEAT_INTERVAL, Duration::from_secs(15));
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.host.heartbeat_tick();
    assert_eq!(p.recv().await, json!({"type":"heartbeat","seq":1,"ts":1_800_000_000.0}));
    h.clock.advance(HEARTBEAT_INTERVAL);
    h.host.heartbeat_tick();
    assert_eq!(p.recv().await, json!({"type":"heartbeat","seq":2,"ts":1_800_000_015.0}));
    assert!(!h.log("websocket.log").contains("missed"), "one miss is not logged");
    h.host.heartbeat_tick();
    assert_eq!(p.recv().await["seq"], 3);
    // Two missed acks in a row (seq 1 and 2): logged, not disconnected.
    assert!(h.log("websocket.log").contains("missed 2 acks"), "{}", h.log("websocket.log"));
    p.send(json!({"type":"heartbeat_ack","seq":3})).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    h.host.heartbeat_tick();
    assert_eq!(p.recv().await["seq"], 4);
    let ids = h.host.client_ids();
    assert_eq!(ids.len(), 1);
    assert_eq!(h.host.missed_acks(ids[0]), Some(0), "the ack reset the count");
    assert_eq!(h.host.authenticated_count(), 1, "still connected");
}

#[tokio::test]
async fn heartbeats_go_only_to_authenticated_phones() {
    let h = start().await;
    let mut unauth = connect(h.addr).await;
    unauth.recv().await;
    h.host.heartbeat_tick();
    unauth.assert_silent(QUIET).await;
}

// --- prefs ---

#[tokio::test]
async fn preferences_snapshot_is_stored_and_returned_as_is_to_the_asker_only() {
    let h = start().await;
    let (mut a, _) = paired(h.addr).await;
    let (mut b, _) = paired(h.addr).await;
    let prefs = json!({"pushSound":true,"savedAt":1.5,"unknownFuture":{"k":[1,"two"]}});
    a.send(json!({"type":"preferences_snapshot","deviceID":"PHONE-A","preferences":prefs})).await;
    a.send(json!({"type":"preferences_request","deviceID":"PHONE-A"})).await;
    assert_eq!(a.recv().await, json!({"type":"preferences_restore","deviceID":"PHONE-A","preferences":prefs}));
    b.assert_silent(QUIET).await;
    b.send(json!({"type":"preferences_request","deviceID":"PHONE-B"})).await;
    assert_eq!(b.recv().await, json!({"type":"preferences_restore","deviceID":"PHONE-B","preferences":{}}));
    assert!(h.dir.path().join("config").join("phone-prefs.json").exists());
}

#[tokio::test]
async fn no_backup_mode_answers_empty() {
    let h = start_with(Opts { prefs_file: false, ..Default::default() }).await;
    let (mut a, _) = paired(h.addr).await;
    a.send(
        json!({"type":"preferences_snapshot","deviceID":"P","preferences":{"pushSound":true,"pairedBackendsJSON":"x"}}),
    )
    .await;
    a.send(json!({"type":"preferences_request","deviceID":"P"})).await;
    assert_eq!(a.recv().await["preferences"], json!({}));
    let ws = h.log("websocket.log");
    assert!(
        ws.contains("keys=pushSound,pairedBackendsJSON") || ws.contains("keys=pairedBackendsJSON,pushSound"),
        "{ws}"
    );
}

// --- never a disconnect ---

#[tokio::test]
async fn unknown_types_bad_json_and_oversized_frames_are_ignored() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    p.send(json!({"type":"request_content","windowId":"x"})).await;
    p.send(json!({"type":"image_upload","imageId":"i","windowId":"x","data":"AAAA"})).await;
    p.send(json!({"type":"device_identity","deviceID":"x","deviceKind":"ios","displayName":"p"})).await;
    p.send_raw("{not json").await;
    p.send(json!({"type":"send_text","windowId":"x"})).await; // bad payload
    p.send_raw(&format!(r#"{{"type":"phone_log","lines":["{}"]}}"#, "a".repeat(MAX_MESSAGE_BYTES))).await;
    p.assert_silent(QUIET).await;
    let ws = h.log("websocket.log");
    assert!(ws.contains("drop_oversized bytes="), "{ws}");
    assert!(ws.contains("ignored undecodable frame") && ws.contains("ignored send_text: decode failed"));
    // Still connected and working.
    h.host.heartbeat_tick();
    assert_eq!(p.recv().await["type"], "heartbeat");
    assert!(h.log("phone.log").is_empty(), "the oversized phone_log was dropped, not written");
}

#[tokio::test]
async fn binary_frames_are_parsed_like_text() {
    use futures_util::SinkExt;
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    p.ws.send(tokio_tungstenite::tungstenite::Message::Binary(
        json!({"type":"preferences_request","deviceID":"d"}).to_string().into_bytes(),
    ))
    .await
    .unwrap();
    assert_eq!(p.recv().await["type"], "preferences_restore");
}

// --- quick actions, arrange, minimize, close, phone_log (spec 3.3) ---

#[tokio::test]
async fn quick_actions_press_the_spec_keys_after_focusing() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let wid = h.window_id(102);
    for action in ["press_ctrl_c", "press_escape", "press_up", "press_y", "clear_terminal", "clear_input"] {
        p.send(json!({"type":"quick_action","windowId":wid,"action":action})).await;
    }
    p.send(json!({"type":"quick_action","windowId":wid,"action":"select_2"})).await;
    assert_eq!(p.recv().await["reason"], "Not supported on Windows yet");
    assert_eq!(
        h.fake.typed(102),
        vec![
            Typed::Key(KeyChord::ctrl(Key::Letter('c'))),
            Typed::Key(KeyChord::plain(Key::Escape)),
            Typed::Key(KeyChord::plain(Key::Up)),
            Typed::Text("y".into()),
            Typed::Text("cls".into()),
            Typed::Key(KeyChord::RETURN),
            Typed::Key(KeyChord::plain(Key::Escape)),
        ]
    );
    let focus = h.fake.calls().iter().filter(|c| matches!(c, FakeCall::Focus { handle: 102, .. })).count();
    assert_eq!(focus, 6, "every key action foregrounds first");
}

#[tokio::test]
async fn quick_action_focus_refused_presses_nothing() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_refuse_focus(101, true);
    p.send(json!({"type":"quick_action","windowId":h.window_id(101),"action":"press_return","messageId":ID_A})).await;
    assert_eq!(p.recv().await["reason"], "Windows refused to focus the window");
    assert!(h.fake.typed(101).is_empty());
    assert!(h.log("injection.log").contains("op=quickAction"));
}

#[tokio::test]
async fn toggle_enabled_flips_rebroadcasts_and_persists() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let wid = h.window_id(101);
    p.send(json!({"type":"quick_action","windowId":wid,"action":"toggle_enabled"})).await;
    let l = p.recv_type("layout_update").await;
    let w = l["windows"].as_array().unwrap().iter().find(|w| w["id"] == wid.as_str()).unwrap().clone();
    assert_eq!(w["enabled"], true);
    assert!(h.fake.calls().is_empty(), "no keys for toggle_enabled");
    let settings = h.settings();
    assert!(settings.contains("pwsh one"), "{settings}");
}

// --- set_pin / set_color (Mac `QuipMacApp.swift` cases, spec 3.3) ---

fn layout_names(l: &serde_json::Value) -> Vec<String> {
    l["windows"].as_array().unwrap().iter().map(|w| w["name"].as_str().unwrap().to_string()).collect()
}

fn layout_window(l: &serde_json::Value, id: &str) -> serde_json::Value {
    l["windows"].as_array().unwrap().iter().find(|w| w["id"] == id).unwrap().clone()
}

#[tokio::test]
async fn set_pin_puts_the_window_first_flagged_and_unpin_restores_the_order() {
    let h = start().await;
    let (mut p, first) = paired(h.addr).await;
    assert_eq!(layout_names(&first), ["pwsh one", "cmd two"]);
    let wid = h.window_id(102);
    p.send(json!({"type":"set_pin","windowId":wid,"pinned":true})).await;
    let l = p.recv_type("layout_update").await;
    assert_eq!(layout_names(&l), ["cmd two", "pwsh one"], "the pinned window rides out first");
    assert_eq!(l["windows"][0]["isPinned"], true);
    assert_eq!(l["windows"][1]["isPinned"], false);
    assert!(h.fake.calls().is_empty(), "a pin touches no window");
    // A poll does not undo it.
    h.host.poll_tick().await;
    p.assert_silent(QUIET).await;
    p.send(json!({"type":"set_pin","windowId":wid,"pinned":false})).await;
    let l = p.recv_type("layout_update").await;
    assert_eq!(layout_names(&l), ["pwsh one", "cmd two"]);
    assert!(l["windows"].as_array().unwrap().iter().all(|w| w["isPinned"] == false));
}

#[tokio::test]
async fn set_color_wins_over_the_dealt_color_and_clearing_brings_it_back() {
    let h = start().await;
    let (mut p, first) = paired(h.addr).await;
    let wid = h.window_id(101);
    let dealt = layout_window(&first, &wid)["color"].clone();
    p.send(json!({"type":"set_color","windowId":wid,"color":"#ff6b6b"})).await;
    let l = p.recv_type("layout_update").await;
    assert_eq!(layout_window(&l, &wid)["color"], "#FF6B6B", "normalized like WindowColor.normalized");
    h.host.poll_tick().await;
    p.assert_silent(QUIET).await;
    // Not a hex color: ignored, as the Mac's setColor does.
    p.send(json!({"type":"set_color","windowId":wid,"color":"red"})).await;
    p.assert_silent(QUIET).await;
    // Absent color clears the choice.
    p.send(json!({"type":"set_color","windowId":wid})).await;
    let l = p.recv_type("layout_update").await;
    assert_eq!(layout_window(&l, &wid)["color"], dealt);
}

#[tokio::test]
async fn set_pin_and_set_color_for_an_unknown_id_are_ignored() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let notepad = h.window_id(103); // tracked, but not shown to the phone
    for m in [
        json!({"type":"set_pin","windowId":"w-999-9-9","pinned":true}),
        json!({"type":"set_color","windowId":"w-999-9-9","color":"#4A90D9"}),
        json!({"type":"set_pin","windowId":notepad,"pinned":true}),
        json!({"type":"set_color","windowId":notepad,"color":"#4A90D9"}),
    ] {
        p.send(m).await;
    }
    p.assert_silent(QUIET).await;
    let saved: quip_windows::services::settings::Settings = toml::from_str(&h.settings()).unwrap();
    assert!(saved.pinned_windows.is_empty() && saved.window_colors.is_empty(), "{saved:?}");
    // The socket still works.
    p.send(json!({"type":"set_pin","windowId":h.window_id(102),"pinned":true})).await;
    assert_eq!(layout_names(&p.recv_type("layout_update").await), ["cmd two", "pwsh one"]);
}

#[tokio::test]
async fn pins_and_colors_survive_a_restart() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    p.send(json!({"type":"set_pin","windowId":h.window_id(102),"pinned":true})).await;
    p.recv_type("layout_update").await;
    p.send(json!({"type":"set_color","windowId":h.window_id(101),"color":"#123456"})).await;
    p.recv_type("layout_update").await;
    let saved: quip_windows::services::settings::Settings = toml::from_str(&h.settings()).unwrap();
    assert_eq!(saved.pinned_windows.len(), 1, "{saved:?}");
    assert_eq!(saved.window_colors[0].color, "#123456");
    drop(p);
    let dir = h.dir;
    let h2 = start_with(Opts { dir: Some(dir), ..Default::default() }).await;
    let (_q, l) = paired(h2.addr).await;
    assert_eq!(layout_names(&l), ["cmd two", "pwsh one"], "the saved pin is first after a restart");
    assert_eq!(l["windows"][0]["isPinned"], true);
    assert_eq!(layout_window(&l, &h2.window_id(101))["color"], "#123456");
}

#[tokio::test]
async fn arrange_tiles_the_windows_the_phone_shows() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    // Nothing is enabled (mirror-desktop rule): the two terminals the phone
    // shows are tiled anyway; Notepad (not shown) is not moved.
    p.send(json!({"type":"arrange_windows","layout":"vertical"})).await;
    let l = p.recv_type("layout_update").await;
    let ys: Vec<f64> = l["windows"].as_array().unwrap().iter().map(|w| w["frame"]["y"].as_f64().unwrap()).collect();
    // Rows over the 1040 px work area, normalized against the 1080 px display.
    assert!(ys[0] == 0.0 && (ys[1] - 520.0 / 1080.0).abs() < 1e-9, "{ys:?}");
    let moved: Vec<u64> = h
        .fake
        .calls()
        .into_iter()
        .filter_map(|c| match c {
            FakeCall::Move { handle, .. } => Some(handle),
            _ => None,
        })
        .collect();
    assert_eq!(moved, [101, 102]);
    h.fake.clear_calls();
    h.fake.set_refuse_move(102, true);
    p.send(json!({"type":"arrange_windows","layout":"horizontal"})).await;
    let e = p.recv_type("error").await;
    assert_eq!(e["reason"], "Windows refused to move 1 of 2 windows (elevated or protected)");
    let moves: Vec<_> = h.fake.calls().into_iter().filter(|c| matches!(c, FakeCall::Move { .. })).collect();
    assert_eq!(moves.len(), 1, "the other window still moved");
    assert!(
        h.log("injection.log").contains(r#"op=arrange"#)
            && h.log("injection.log").contains(r#"detail="elevated or refused""#)
    );
    p.recv_type("layout_update").await; // the tiles moved
    p.send(json!({"type":"arrange_windows","layout":"grid"})).await; // not on the wire enum
    p.assert_silent(QUIET).await;
}

#[tokio::test]
async fn arrange_with_nothing_shown_says_so() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.remove_window(101);
    h.fake.remove_window(102);
    h.host.poll_tick().await;
    p.recv_type("layout_update").await;
    p.send(json!({"type":"arrange_windows","layout":"horizontal"})).await;
    assert_eq!(p.recv_type("error").await, json!({"type":"error","reason":"No enabled windows to arrange"}));
}

fn moves_of(h: &Harness) -> Vec<u64> {
    h.fake
        .calls()
        .into_iter()
        .filter_map(|c| match c {
            FakeCall::Move { handle, .. } => Some(handle),
            _ => None,
        })
        .collect()
}

/// After an arrange: the next `layout_update`, then silence (no `error`).
async fn arranged_without_error(p: &mut Phone) -> serde_json::Value {
    let l = p.recv_type("layout_update").await;
    p.assert_silent(QUIET).await;
    l
}

#[tokio::test]
async fn arrange_restores_a_minimized_window_and_tiles_it_without_a_gap() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    // Minimized: DWM reports no border until it is back (spec 5.2).
    h.fake.set_minimized(102, true);
    h.fake.set_border_after_restore(102, 7);
    h.host.poll_tick().await;
    let l = p.recv_type("layout_update").await;
    assert_eq!(layout_window(&l, &h.window_id(102))["isMinimized"], true);
    p.send(json!({"type":"arrange_windows","layout":"horizontal"})).await;
    let l = arranged_without_error(&mut p).await;
    let w = layout_window(&l, &h.window_id(102));
    assert_eq!(w["isMinimized"], false);
    // Columns over the 1920 px work area, normalized against the 1920 px display.
    let x = w["frame"]["x"].as_f64().unwrap() * 1920.0;
    let width = w["frame"]["width"].as_f64().unwrap() * 1920.0;
    assert!((x - 960.0).abs() <= 1.0 && (x + width - 1920.0).abs() <= 1.0, "x={x} width={width}");
    let calls = h.fake.calls();
    let restore = calls.iter().position(|c| *c == FakeCall::Restore { handle: 102 }).expect("restored");
    let mv = calls.iter().position(|c| matches!(c, FakeCall::Move { handle: 102, .. })).expect("moved");
    assert!(restore < mv, "restored before it was measured and moved: {calls:?}");
    assert_eq!(moves_of(&h), [101, 102], "on target the first time");
}

#[tokio::test]
async fn a_cross_dpi_rescale_is_corrected_by_a_second_move() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_rescale_once(101, 125);
    // Vertical: the fixture already sits in columns, so rows change the layout.
    p.send(json!({"type":"arrange_windows","layout":"vertical"})).await;
    let l = arranged_without_error(&mut p).await;
    let mut moved = moves_of(&h);
    moved.sort_unstable();
    assert_eq!(moved, [101, 101, 102], "two moves for the rescaled window, one for the other");
    let f = &layout_window(&l, &h.window_id(101))["frame"];
    // Rows over the 1040 px work area, normalized against the 1080 px display.
    let (y, height) = (f["y"].as_f64().unwrap() * 1080.0, f["height"].as_f64().unwrap() * 1080.0);
    let width = f["width"].as_f64().unwrap() * 1920.0;
    assert!(y.abs() <= 1.0 && (height - 520.0).abs() <= 1.0 && (width - 1920.0).abs() <= 1.0, "{f}");
}

#[tokio::test]
async fn a_window_at_minimum_size_is_logged_not_an_error() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_min_size(102, 1200, 700);
    p.send(json!({"type":"arrange_windows","layout":"horizontal"})).await;
    arranged_without_error(&mut p).await;
    let ws = h.log("websocket.log");
    assert!(
        ws.contains(&format!("arrange: {} ended at 1186x1040, wanted 960x1040 (minimum size?)", h.window_id(102))),
        "{ws}"
    );
    assert!(!h.log("injection.log").contains("op=arrange"));
}

#[tokio::test]
async fn a_window_that_closed_before_the_arrange_is_logged_as_closed_not_refused() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    // Gone after the phone was shown it: the plan still names it.
    let gone = h.window_id(102);
    h.fake.remove_window(102);
    p.send(json!({"type":"arrange_windows","layout":"horizontal"})).await;
    let e = p.recv_type("error").await;
    assert_eq!(e["reason"], "Windows refused to move 1 of 2 windows (elevated or protected)");
    let inj = h.log("injection.log");
    let line = inj.lines().find(|l| l.contains("op=arrange")).unwrap_or_else(|| panic!("{inj}"));
    assert!(line.contains(&format!("window={gone}")), "{line}");
    assert!(line.contains("kind=windowClosed"), "a stale id greps apart from a refusal: {line}");
}

#[tokio::test]
async fn a_stalled_input_call_answers_the_phone_and_the_next_action_runs() {
    let limits = quip_windows::host::ConnectionLimits { input_stall: Duration::from_millis(300), ..Default::default() };
    let h = start_with(Opts { limits, ..Default::default() }).await;
    let (mut p, _) = paired(h.addr).await;
    // One SendInput that never comes back in time: a window that stopped
    // pumping messages under a Win32 call.
    h.fake.set_block_typing(Some(Duration::from_secs(3)));
    p.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"x","pressReturn":false,"messageId":ID_A}))
        .await;
    let e = p.recv_type("error").await;
    assert_eq!(e["reason"], quip_windows::services::router::INPUT_STALLED);
    let ws = h.log("websocket.log");
    assert!(ws.contains("input lane: send_text dropped: a Win32 call ran over"), "{ws}");
    assert!(h.log("injection.log").contains("op=sendText"), "the drop is in injection.log too");
    h.fake.set_block_typing(None);
    p.send(json!({"type":"minimize_window","windowId":h.window_id(102),"messageId":ID_B})).await;
    p.recv_type("layout_update").await;
    assert!(h.fake.calls().contains(&FakeCall::Minimize { handle: 102 }), "the lane runs again");
}

#[tokio::test]
async fn a_dead_input_lane_says_so_not_elevated() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_panic_input(true);
    p.send(json!({"type":"arrange_windows","layout":"horizontal"})).await;
    assert_eq!(p.recv_type("error").await["reason"], "Windows host input thread stopped");
    p.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"x","pressReturn":false,"messageId":ID_A}))
        .await;
    assert_eq!(
        p.recv_type("error").await,
        json!({"type":"error","reason":"Windows host input thread stopped","messageId":ID_A})
    );
    assert!(!h.log("injection.log").contains("elevated"));
}

#[tokio::test]
async fn select_minimize_close_and_phone_log() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let (w101, w102) = (h.window_id(101), h.window_id(102));
    p.send(json!({"type":"select_window","windowId":w102})).await;
    assert_eq!(p.recv().await, json!({"type":"frontmost_changed","windowId":w102}));
    assert!(h.fake.calls().contains(&FakeCall::Focus { handle: 102, step: FocusStep::SetForeground }));

    p.send(json!({"type":"minimize_window","windowId":w101,"messageId":ID_A})).await;
    let l = p.recv_type("layout_update").await;
    assert!(l["windows"].as_array().unwrap().iter().any(|w| w["id"] == w101.as_str() && w["isMinimized"] == true));

    p.send(json!({"type":"close_window","windowId":w102})).await;
    let l = p.recv_type("layout_update").await;
    assert!(!l["windows"].as_array().unwrap().iter().any(|w| w["id"] == w102.as_str()));
    assert!(h.fake.calls().contains(&FakeCall::Close { handle: 102 }));

    p.send(json!({"type":"close_window","windowId":w102})).await;
    assert_eq!(p.recv_type("error").await, json!({"type":"error","reason":"Window no longer exists"}));
    p.send(json!({"type":"minimize_window","windowId":"w-gone","messageId":ID_B})).await;
    assert_eq!(p.recv_type("error").await, json!({"type":"error","reason":"Window no longer exists","messageId":ID_B}));
    // The Mac answers nothing to select_window with an unknown id.
    p.send(json!({"type":"select_window","windowId":"w-gone"})).await;
    p.assert_silent(QUIET).await;

    p.send(json!({"type":"phone_log","lines":["ptt start path=remote","token=abcdefghijklmnopqrstuvwxyz"]})).await;
    tokio::time::sleep(Duration::from_millis(150)).await;
    let log = h.log("phone.log");
    assert!(log.contains("ptt start path=remote") && !log.contains("abcdefghijklmnopqrstuvwxyz"), "{log}");
}

#[tokio::test]
async fn errors_and_acks_reach_every_phone() {
    let h = start().await;
    let (mut a, _) = paired(h.addr).await;
    let (mut b, _) = paired(h.addr).await;
    a.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"x","pressReturn":false,"messageId":ID_A}))
        .await;
    assert_eq!(a.recv().await["type"], "send_text_ack");
    assert_eq!(b.recv().await["type"], "send_text_ack");
}

// --- host bookkeeping (mutation-check gaps) ---

#[tokio::test]
async fn new_pin_keeps_connected_phones_and_is_required_next_time() {
    let h = start().await;
    let (mut a, _) = paired(h.addr).await;
    h.host.set_pin("13572468".into());
    h.host.heartbeat_tick();
    assert_eq!(a.recv().await["type"], "heartbeat", "the paired phone stays connected");
    let mut b = connect(h.addr).await;
    b.recv().await;
    b.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(b.recv().await["error"], "Incorrect PIN");
    b.send(json!({"type":"auth","pin":"13572468"})).await;
    assert_eq!(b.recv().await["success"], true);
    let settings = h.settings();
    assert!(settings.contains("13572468"), "the new PIN is persisted");
}

/// Reads until the host closes the socket (Close frame or end of stream),
/// skipping whatever was queued first. Panics if it is still open after 5 s.
async fn assert_closed_by_host(p: &mut Phone) {
    let until = Instant::now() + Duration::from_secs(5);
    loop {
        match tokio::time::timeout_at(until.into(), p.ws.next()).await {
            Err(_) => panic!("the host did not close the socket within 5 s"),
            Ok(None | Some(Ok(Message::Close(_))) | Some(Err(_))) => return,
            Ok(Some(Ok(_))) => continue,
        }
    }
}

#[tokio::test]
async fn tray_new_pin_closes_every_phone_and_only_the_new_pin_gets_back_in() {
    let h = start().await;
    let (mut a, _) = paired(h.addr).await;
    let (mut b, _) = paired(h.addr).await;
    // One more that never authenticated: it is closed too.
    let mut c = connect(h.addr).await;
    c.recv().await;
    for _ in 0..50 {
        if h.host.client_ids().len() == 3 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(h.host.authenticated_count(), 2);
    assert_eq!(h.host.replace_pin("13572468".into()), 3);
    assert_eq!(h.host.authenticated_count(), 0, "no phone is authenticated from the moment the PIN changes");
    assert_closed_by_host(&mut a).await;
    assert_closed_by_host(&mut b).await;
    assert_closed_by_host(&mut c).await;
    let log = h.log("websocket.log");
    assert!(log.contains("closed 3 connection(s)"));
    // Each socket's task ended on the signal, not on a Close reply the peer
    // may never send.
    assert_eq!(log.matches("the PIN was replaced").count(), 3, "{log}");

    let mut again = connect(h.addr).await;
    again.recv().await;
    again.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(again.recv().await["error"], "Incorrect PIN", "the old PIN no longer works");
    again.send(json!({"type":"auth","pin":"13572468"})).await;
    assert_eq!(again.recv().await["success"], true);
    assert_eq!(again.recv().await["type"], "device_identity");
    assert!(h.settings().contains("13572468"), "the new PIN is persisted");
    assert!(!h.log("websocket.log").contains("13572468"), "the PIN never reaches a log");
}

#[tokio::test]
async fn client_count_follows_auth_and_disconnect() {
    let h = start().await;
    assert_eq!(h.host.authenticated_count(), 0);
    let (a, _) = paired(h.addr).await;
    let (_b, _) = paired(h.addr).await;
    assert_eq!(h.host.authenticated_count(), 2);
    drop(a);
    for _ in 0..50 {
        if h.host.authenticated_count() == 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(h.host.authenticated_count(), 1, "a closed socket is removed");
}

#[tokio::test]
async fn acks_reset_the_missed_count() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let id = 1; // the first registered client
    assert_eq!(h.host.missed_acks(id), Some(0));
    assert_eq!(h.host.missed_acks(999), None);
    h.host.heartbeat_tick();
    h.host.heartbeat_tick();
    assert_eq!(h.host.missed_acks(id), Some(1));
    let seq = p.recv().await["seq"].as_i64().unwrap() + 1;
    p.recv().await;
    p.send(json!({"type":"heartbeat_ack","seq":seq})).await;
    for _ in 0..50 {
        if h.host.missed_acks(id) == Some(0) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(h.host.missed_acks(id), Some(0));
    h.host.heartbeat_tick();
    assert_eq!(h.host.missed_acks(id), Some(0), "the acked heartbeat is no longer pending");
}

#[tokio::test]
async fn recovery_is_logged_only_after_a_failure() {
    let h = start().await;
    h.host.poll_tick().await;
    assert!(!h.log("websocket.log").contains("recovered"));
}

#[tokio::test]
async fn show_all_apps_rebroadcasts_with_every_window() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.host.set_show_all_apps(true);
    let l = p.recv().await;
    assert_eq!(l["windows"].as_array().unwrap().len(), 3);
    let settings = h.settings();
    assert!(settings.contains("show_all_apps = true"));
}

#[tokio::test]
async fn ack_timings_measure_the_injection() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_block_typing(Some(Duration::from_millis(120)));
    p.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"x","pressReturn":false,"messageId":ID_A}))
        .await;
    let ack = p.recv().await;
    assert!(ack["injectMs"].as_i64().unwrap() >= 120, "{ack}");
    assert!(ack["totalMs"].as_i64().unwrap() >= ack["injectMs"].as_i64().unwrap());
}

// --- review fixes ---

#[tokio::test]
async fn a_reused_handle_types_nothing_and_reports_window_closed() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let old = h.window_id(101);
    // 101 closes and Windows hands the HWND to a new process before the next
    // poll: the phone's id still maps to (101, pid 1).
    h.fake.reuse_handle(101, 4242, "someone else's window");
    h.fake.set_input_guard(false);
    p.send(json!({"type":"send_text","windowId":old,"text":"secret","pressReturn":true,"messageId":ID_A})).await;
    assert_eq!(p.recv().await, json!({"type":"error","reason":"Window no longer exists","messageId":ID_A}));
    assert!(h.fake.typed(101).is_empty(), "nothing reached the new window");
    assert!(h
        .log("injection.log")
        .contains(&format!("op=sendText window={old} app=Windows_Terminal kind=windowClosed")));
    p.send(json!({"type":"quick_action","windowId":old,"action":"press_return","messageId":ID_B})).await;
    assert_eq!(p.recv_type("error").await["reason"], "Window no longer exists");
    assert!(h.fake.typed(101).is_empty());
}

#[tokio::test]
async fn a_short_insert_stops_with_an_error_and_no_ack() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    h.fake.set_input_limit(Some(3));
    p.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"Get-ChildItem","pressReturn":true,"messageId":ID_A}))
        .await;
    let e = p.recv().await;
    assert_eq!(e["type"], "error", "{e}");
    assert_eq!(e["messageId"], ID_A);
    assert!(e["reason"].as_str().unwrap().contains("administrator"));
    p.assert_silent(QUIET).await; // no send_text_ack
    assert_eq!(h.fake.typed(101), vec![Typed::Text("Get".into())], "no Return after the blocked batch");
    let inj = h.log("injection.log");
    assert!(
        inj.contains(r#"kind=unknown msg="input blocked after 3 chars" detail="input blocked (elevated window?)""#),
        "{inj}"
    );
}

#[tokio::test]
async fn the_shell_is_rechecked_at_send_time() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    // The listing (1 s old) says pwsh; the user has just started python in it.
    h.fake.set_running(101, &["pwsh.exe", "python.exe"]);
    p.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"x = 1\nprint(x)","pressReturn":true,"messageId":ID_A}))
        .await;
    let e = p.recv().await;
    assert_eq!(e["type"], "error");
    assert!(e["reason"].as_str().unwrap().contains("(unknown)"), "{e}");
    assert!(h.fake.typed(101).is_empty());
    assert!(h.log("injection.log").contains(r#"detail="multi-line not safe in this shell""#));
    // Back at the prompt: multi-line works again, with no re-poll.
    h.fake.set_running(101, &["pwsh.exe"]);
    p.send(json!({"type":"send_text","windowId":h.window_id(101),"text":"a\nb","pressReturn":true,"messageId":ID_B}))
        .await;
    assert_eq!(p.recv().await["type"], "send_text_ack");
}

#[tokio::test]
async fn only_windows_the_phone_is_shown_can_be_driven() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let notes = h.window_id(103); // tracked, not in the broadcast set
    p.send(json!({"type":"send_text","windowId":notes,"text":"x","pressReturn":true,"messageId":ID_A})).await;
    assert_eq!(p.recv().await, json!({"type":"error","reason":"Window no longer exists","messageId":ID_A}));
    p.send(json!({"type":"close_window","windowId":notes})).await;
    assert_eq!(p.recv().await["reason"], "Window no longer exists");
    p.send(json!({"type":"select_window","windowId":notes})).await;
    p.assert_silent(QUIET).await;
    assert!(h.fake.calls().is_empty(), "{:?}", h.fake.calls());
}

#[tokio::test]
async fn request_content_gets_the_not_available_text_for_shown_windows_only() {
    let h = start().await;
    let (mut a, _) = paired(h.addr).await;
    let (mut b, _) = paired(h.addr).await;
    let wid = h.window_id(101);
    a.send(json!({"type":"request_content","windowId":wid})).await;
    assert_eq!(
        a.recv().await,
        json!({"type":"terminal_content","windowId":wid,"content":"Terminal text is not available on Windows yet.","hasAutosuggest":false})
    );
    b.assert_silent(QUIET).await; // to the asker only
    a.send(json!({"type":"request_content","windowId":h.window_id(103)})).await;
    a.send(json!({"type":"request_content","windowId":"w-gone"})).await;
    a.assert_silent(QUIET).await;
}

#[tokio::test]
async fn successful_sends_and_quick_actions_write_latency_lines_with_counts_only() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let wid = h.window_id(101);
    p.send(json!({"type":"send_text","windowId":wid,"text":"one\ntwo","pressReturn":true,"messageId":ID_A})).await;
    p.recv_type("send_text_ack").await;
    p.send(json!({"type":"quick_action","windowId":wid,"action":"press_ctrl_c","messageId":ID_B})).await;
    p.send(json!({"type":"quick_action","windowId":wid,"action":"clear_terminal"})).await;
    tokio::time::sleep(Duration::from_millis(150)).await;
    let lat = h.log("latency.log");
    assert!(
        lat.contains("send_text rid=6BA7B810") && lat.contains(" segments=2 ") && lat.contains("success=1"),
        "{lat}"
    );
    assert!(
        lat.contains("quick_action rid=7BA7B810 action=press_ctrl_c term=Windows_Terminal success=1 inputs=1"),
        "{lat}"
    );
    assert!(lat.contains("quick_action rid=nil action=clear_terminal") && lat.contains("inputs=2"), "{lat}");
    assert!(!lat.contains("one") && !lat.contains("cls"), "never text: {lat}");
    let acts = h.fake.actions();
    assert!(acts.contains(&"key handle=101 chord=ctrl+c".to_string()), "{acts:?}");
    assert!(acts.contains(&"type handle=101 units=3".to_string()), "{acts:?}");
}

#[tokio::test]
async fn a_phone_supplied_action_with_line_breaks_cannot_forge_a_log_line() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let forged = "nope\n[2026-01-01T00:00:00Z] [ERROR] [ws] forged";
    p.send(json!({"type":"quick_action","windowId":h.window_id(101),"action":forged})).await;
    assert_eq!(p.recv().await["reason"], "Not supported on Windows yet");
    p.send(json!({"type":"send_text","windowId":"w-x\r\nkind=forged","text":"x","pressReturn":false})).await;
    p.recv().await;
    for file in ["websocket.log", "injection.log"] {
        let log = h.log(file);
        assert!(log.lines().all(|l| l.starts_with('[') || l.starts_with("20")), "{file}: {log}");
        assert!(
            !log.lines().any(|l| l.contains("[ERROR] [ws] forged") && l.starts_with("[2026-01-01")),
            "{file}: {log}"
        );
    }
}

#[tokio::test]
async fn an_unauthenticated_socket_is_closed_after_the_deadline() {
    let limits =
        quip_windows::host::ConnectionLimits { pre_auth_deadline: Duration::from_millis(300), ..Default::default() };
    let h = start_with(Opts { limits, ..Default::default() }).await;
    let mut p = connect(h.addr).await;
    p.recv().await; // auth_required
                    // Wrong PINs do not extend it.
    p.send(json!({"type":"auth","pin":"00000000"})).await;
    p.recv().await;
    assert!(p.recv_within(Duration::from_secs(2)).await.is_none(), "closed");
    assert!(h.log("websocket.log").contains("not authenticated within 300ms"));
    // An authenticated phone is never reaped.
    let (mut q, _) = paired(h.addr).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    h.host.heartbeat_tick();
    assert_eq!(q.recv().await["type"], "heartbeat");
    // A TCP peer that never upgrades is reaped too.
    let raw = tokio::net::TcpStream::connect(h.addr).await.unwrap();
    tokio::time::sleep(Duration::from_millis(600)).await;
    let mut buf = [0u8; 1];
    let n = tokio::time::timeout(Duration::from_secs(2), async {
        use tokio::io::AsyncReadExt;
        let mut r = raw;
        r.read(&mut buf).await
    })
    .await
    .unwrap();
    assert!(matches!(n, Ok(0) | Err(_)), "closed by the host");
}

#[tokio::test]
async fn at_most_sixteen_sockets_wait_for_auth() {
    // One loopback sender here, so lift its own caps to reach the global one.
    let limits = quip_windows::host::ConnectionLimits {
        max_unauthenticated_per_sender: quip_windows::host::MAX_UNAUTHENTICATED,
        max_unauthenticated_per_network: quip_windows::host::MAX_UNAUTHENTICATED,
        ..Default::default()
    };
    let h = start_with(Opts { limits, ..Default::default() }).await;
    let mut waiting = vec![];
    for _ in 0..quip_windows::host::MAX_UNAUTHENTICATED {
        let mut p = connect(h.addr).await;
        p.recv().await; // auth_required
        waiting.push(p);
    }
    assert_eq!(h.host.unauthenticated_count(), 16);
    let extra = tokio_tungstenite::connect_async(format!("ws://{}", h.addr)).await;
    assert!(extra.is_err(), "the 17th is refused");
    assert!(h.log("websocket.log").contains("16 sockets already waiting for auth"));
    // Authenticating one frees its slot.
    let mut first = waiting.remove(0);
    first.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(first.recv().await["success"], true);
    assert_eq!(h.host.unauthenticated_count(), 15);
    let mut next = connect(h.addr).await;
    assert_eq!(next.recv().await["error"], "auth_required");
    // Closing one frees its slot too.
    drop(waiting.pop());
    for _ in 0..50 {
        if h.host.unauthenticated_count() == 15 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(h.host.unauthenticated_count(), 15);
}

#[tokio::test]
async fn more_than_ten_frames_a_second_are_dropped_but_auth_is_not() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    for _ in 0..12 {
        p.send(json!({"type":"preferences_request","deviceID":"d"})).await;
    }
    for _ in 0..10 {
        assert_eq!(p.recv().await["type"], "preferences_restore");
    }
    p.assert_silent(QUIET).await;
    assert!(h.log("websocket.log").contains("rate limit: dropping frames"));
    p.send(json!({"type":"auth","pin":PIN})).await; // bypasses the limit
    assert_eq!(p.recv().await["success"], true);
    h.clock.advance(Duration::from_secs(1));
    p.send(json!({"type":"preferences_request","deviceID":"d"})).await;
    assert_eq!(p.recv_type("preferences_restore").await["type"], "preferences_restore");
}

#[tokio::test]
async fn nothing_reaches_a_phone_before_its_auth_result_even_mid_broadcast() {
    let h = start().await;
    let host = h.host.clone();
    let fake = h.fake.clone();
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let s2 = stop.clone();
    let churn = tokio::spawn(async move {
        let mut x = 0;
        while !s2.load(std::sync::atomic::Ordering::SeqCst) {
            x = (x + 37) % 900;
            fake.move_window(101, quip_windows::services::layout::PixelRect::new(x, 0, 960, 1040));
            host.poll_tick().await;
            tokio::task::yield_now().await;
        }
    });
    for _ in 0..20 {
        let mut p = connect(h.addr).await;
        assert_eq!(p.recv().await["error"], "auth_required");
        p.send(json!({"type":"auth","pin":PIN})).await;
        assert_eq!(p.recv().await, json!({"type":"auth_result","success":true}));
        assert_eq!(p.recv().await["type"], "device_identity");
        assert_eq!(p.recv().await["type"], "layout_update");
    }
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    churn.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_polls_never_send_an_older_layout_after_a_newer_one() {
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    // Each poll sees one more window; the phone must see the count only grow.
    let mut tasks = vec![];
    for i in 0..30u64 {
        let w = quip_windows::platform::fake::window_from_fixture(
            &serde_json::from_value(
                json!({"handle":1000 + i,"pid":9,"title":format!("t{i}"),"className":"ConsoleWindowClass",
                "shells":["pwsh.exe"],"visible":{"x":10,"y":10,"width":400,"height":300}}),
            )
            .unwrap(),
        );
        h.fake.add_window(w);
        let host = h.host.clone();
        tasks.push(tokio::spawn(async move { host.poll_tick().await }));
    }
    for t in tasks {
        t.await.unwrap();
    }
    let mut last = 0;
    while let Some(m) = p.recv_within(Duration::from_millis(300)).await {
        if m["type"] == "layout_update" {
            let n = m["windows"].as_array().unwrap().len();
            assert!(n >= last, "{n} after {last}");
            last = n;
        }
    }
    assert_eq!(last, 32);
}

#[tokio::test]
async fn a_corrupt_prefs_file_is_moved_aside_with_a_log_line() {
    let h = start().await;
    let (mut a, _) = paired(h.addr).await;
    let path = h.dir.path().join("config").join("phone-prefs.json");
    std::fs::write(&path, "{\"OTHER-PHONE\": {\"k\": 1}, oops").unwrap();
    a.send(json!({"type":"preferences_snapshot","deviceID":"PHONE-A","preferences":{"a":1}})).await;
    a.send(json!({"type":"preferences_request","deviceID":"PHONE-A"})).await;
    assert_eq!(a.recv().await["preferences"], json!({"a":1}));
    let bad = h.dir.path().join("config").join("phone-prefs.json.bad");
    assert_eq!(std::fs::read_to_string(bad).unwrap(), "{\"OTHER-PHONE\": {\"k\": 1}, oops", "never overwritten");
    assert!(h.log("websocket.log").contains("phone-prefs.json was corrupt; moved to"));
}

#[cfg(unix)]
#[tokio::test]
async fn a_failed_settings_save_is_logged() {
    use std::os::unix::fs::PermissionsExt;
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    let cfg = h.dir.path().join("config");
    std::fs::set_permissions(&cfg, std::fs::Permissions::from_mode(0o500)).unwrap();
    p.send(json!({"type":"quick_action","windowId":h.window_id(101),"action":"toggle_enabled"})).await;
    p.recv_type("layout_update").await;
    let ws = h.log("websocket.log");
    std::fs::set_permissions(&cfg, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(ws.contains("[ERROR] [ws] settings NOT saved"), "{ws}");
}

#[tokio::test]
async fn a_frame_past_the_protocol_cap_closes_the_socket_one_at_the_app_cap_is_kept() {
    use quip_windows::protocol::limits::PROTOCOL_MAX_MESSAGE_BYTES;
    let h = start().await;
    let (mut p, _) = paired(h.addr).await;
    // Exactly MAX_MESSAGE_BYTES: allowed (the cap is "more than").
    let head = r#"{"type":"phone_log","lines":[""#;
    let tail = r#""]}"#;
    let exact = format!("{head}{}{tail}", "a".repeat(MAX_MESSAGE_BYTES - head.len() - tail.len()));
    assert_eq!(exact.len(), MAX_MESSAGE_BYTES);
    p.send_raw(&exact).await;
    for _ in 0..100 {
        if h.log("phone.log").contains("aaaa") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(h.log("phone.log").contains("aaaa"), "handled, not dropped");
    assert!(!h.log("websocket.log").contains("drop_oversized"));
    // Past the protocol cap (app cap + headroom): tungstenite fails the
    // connection instead of buffering it.
    let huge = format!("{head}{}{tail}", "b".repeat(PROTOCOL_MAX_MESSAGE_BYTES + 16));
    let _ = futures_util::SinkExt::send(&mut p.ws, tokio_tungstenite::tungstenite::Message::Text(huge)).await;
    let closed = loop {
        match tokio::time::timeout(Duration::from_secs(5), futures_util::StreamExt::next(&mut p.ws)).await {
            Ok(Some(Ok(tokio_tungstenite::tungstenite::Message::Text(_)))) => continue,
            Ok(Some(Ok(_))) | Ok(None) | Ok(Some(Err(_))) => break true,
            Err(_) => break false,
        }
    };
    assert!(closed, "the host closed the socket");
}

#[tokio::test]
async fn the_first_refused_socket_is_logged_with_its_count() {
    let limits = quip_windows::host::ConnectionLimits { max_unauthenticated: 1, ..Default::default() };
    let h = start_with(Opts { limits, ..Default::default() }).await;
    let mut a = connect(h.addr).await;
    a.recv().await;
    assert!(tokio_tungstenite::connect_async(format!("ws://{}", h.addr)).await.is_err());
    assert!(h.log("websocket.log").contains("(refused=1)"), "{}", h.log("websocket.log"));
}

#[tokio::test]
async fn one_sender_holds_at_most_four_pre_auth_sockets_and_another_still_connects() {
    let h = start().await;
    // A second listener on the same host, so ::1 is a second sender.
    let v6 = quip_windows::services::ws_server::bind("[::1]:0".parse().unwrap()).await.unwrap();
    let v6_addr = v6.local_addr().unwrap();
    quip_windows::services::ws_server::spawn(h.host.clone(), v6);
    let mut waiting = vec![];
    for _ in 0..quip_windows::host::MAX_UNAUTHENTICATED_PER_SENDER {
        let mut p = connect(h.addr).await;
        p.recv().await; // auth_required
        waiting.push(p);
    }
    assert_eq!(h.host.unauthenticated_from("127.0.0.1"), 4);
    assert!(tokio_tungstenite::connect_async(format!("ws://{}", h.addr)).await.is_err(), "the 5th is refused");
    assert!(
        h.log("websocket.log").contains("4 sockets from 127.0.0.1 already waiting for auth (refused=1)"),
        "{}",
        h.log("websocket.log")
    );
    // Another sender is not blocked, and authenticates.
    let mut other = connect(v6_addr).await;
    assert_eq!(other.recv().await["error"], "auth_required");
    assert_eq!(h.host.unauthenticated_from("::1"), 1);
    assert_eq!(h.host.unauthenticated_count(), 5);
    other.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(other.recv().await["success"], true);
    // Authenticating one of the four frees a slot for that sender again.
    let mut first = waiting.remove(0);
    first.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(first.recv().await["success"], true);
    assert_eq!(h.host.unauthenticated_from("127.0.0.1"), 3);
    let mut next = connect(h.addr).await;
    assert_eq!(next.recv().await["error"], "auth_required");
}

#[tokio::test]
async fn pre_auth_slots_are_counted_per_exact_address() {
    use quip_windows::host::PreAuthRefusal;
    use quip_windows::services::auth_throttle::Sender;
    let h = start().await;
    let key = |s: &str| Sender::of(s.parse().unwrap());
    // `::ffff:192.0.2.1` and `192.0.2.1` are one sender.
    let mut held = vec![];
    for a in ["192.0.2.1", "::ffff:192.0.2.1", "192.0.2.1", "::ffff:192.0.2.1"] {
        held.push(h.host.try_pre_auth_slot(&key(a)).unwrap());
    }
    assert_eq!(h.host.try_pre_auth_slot(&key("192.0.2.1")).err(), Some(PreAuthRefusal::SenderFull));
    // The 5th from one exact IPv6 address is refused; a neighbour in its /64
    // still gets a slot.
    for _ in 0..4 {
        held.push(h.host.try_pre_auth_slot(&key("2001:db8:1:2::1")).unwrap());
    }
    assert_eq!(h.host.try_pre_auth_slot(&key("2001:db8:1:2::1")).err(), Some(PreAuthRefusal::SenderFull));
    held.push(h.host.try_pre_auth_slot(&key("2001:db8:1:2::2")).expect("a neighbour in the same /64 connects"));
    assert_eq!(h.host.unauthenticated_from("2001:db8:1:2::2"), 1);
    // The global 16 still binds across senders, for a sender holding one.
    for i in 0..7 {
        held.push(h.host.try_pre_auth_slot(&key(&format!("198.51.100.{}", i / 2 + 1))).unwrap());
    }
    assert_eq!(h.host.unauthenticated_count(), 16);
    assert_eq!(h.host.try_pre_auth_slot(&key("198.51.100.4")).err(), Some(PreAuthRefusal::Full));
    drop(held.remove(0));
    assert_eq!(h.host.unauthenticated_from("192.0.2.1"), 3);
    assert_eq!(h.host.unauthenticated_count(), 15);
    assert!(h.host.try_pre_auth_slot(&key("198.51.100.4")).is_ok());
    drop(held);
    assert_eq!(h.host.unauthenticated_count(), 0);
    assert_eq!(h.host.unauthenticated_from("192.0.2.1"), 0);
}

#[tokio::test]
async fn one_slash_64_holds_at_most_eight_pre_auth_sockets_and_ipv4_still_connects() {
    use quip_windows::host::{PreAuthRefusal, MAX_UNAUTHENTICATED_PER_NETWORK};
    use quip_windows::services::auth_throttle::Sender;
    let h = start().await;
    let key = |s: &str| Sender::of(s.parse().unwrap());
    assert_eq!(MAX_UNAUTHENTICATED_PER_NETWORK, 8);
    // Two from each of four addresses: under each address's 4, at the /64's 8.
    let mut held = vec![];
    for i in 0..8u32 {
        held.push(h.host.try_pre_auth_slot(&key(&format!("2001:db8:1:2::{:x}", 0x100 + i / 2))).unwrap());
    }
    assert_eq!(h.host.unauthenticated_from_network("2001:db8:1:2::/64"), 8);
    assert_eq!(h.host.unauthenticated_from("2001:db8:1:2::100"), 2);
    assert_eq!(
        h.host.try_pre_auth_slot(&key("2001:db8:1:2::100")).err(),
        Some(PreAuthRefusal::NetworkFull),
        "a 9th from an address already holding one"
    );
    // A 9th from a new address in the /64 replaces the oldest slot of the
    // /64's busiest address (all hold 2, so the oldest of all): the /64
    // stays at 8.
    let neighbour = h.host.try_pre_auth_slot(&key("2001:db8:1:2::ffff")).expect("a neighbour holding none gets in");
    assert!(held[0].is_evicted());
    assert_eq!(held.iter().filter(|s| s.is_evicted()).count(), 1);
    assert_eq!(h.host.unauthenticated_from_network("2001:db8:1:2::/64"), 8);
    assert_eq!(h.host.unauthenticated_from("2001:db8:1:2::100"), 1);
    held.push(neighbour);
    held.push(h.host.try_pre_auth_slot(&key("192.0.2.1")).expect("an IPv4 sender still connects"));
    held.push(h.host.try_pre_auth_slot(&key("2001:db8:1:3::1")).expect("the next /64 is another network"));
    assert_eq!(h.host.unauthenticated_count(), 10);
    // The per-address 4 still binds inside a network with room.
    for _ in 0..3 {
        held.push(h.host.try_pre_auth_slot(&key("2001:db8:1:3::1")).unwrap());
    }
    assert_eq!(h.host.try_pre_auth_slot(&key("2001:db8:1:3::1")).err(), Some(PreAuthRefusal::SenderFull));
    // Dropping an evicted slot changes nothing; freeing a live one of the
    // /64's lets an address in it connect again.
    drop(held.remove(0));
    assert_eq!(h.host.unauthenticated_from_network("2001:db8:1:2::/64"), 8);
    drop(held.remove(0));
    assert_eq!(h.host.unauthenticated_from_network("2001:db8:1:2::/64"), 7);
    assert_eq!(h.host.unauthenticated_from("2001:db8:1:2::100"), 0);
    held.push(h.host.try_pre_auth_slot(&key("2001:db8:1:2::ffff")).unwrap());
    drop(held);
    assert_eq!(h.host.unauthenticated_from_network("2001:db8:1:2::/64"), 0);
    assert_eq!(h.host.unauthenticated_count(), 0);
}

#[tokio::test]
async fn a_full_network_refuses_real_sockets_with_a_log_line_and_ipv4_still_connects() {
    // Loopback has one IPv6 address, so lift its own cap and lower the
    // network's to see the network cap refuse at accept.
    let limits = quip_windows::host::ConnectionLimits {
        max_unauthenticated_per_sender: 8,
        max_unauthenticated_per_network: 2,
        ..Default::default()
    };
    let h = start_with(Opts { limits, ..Default::default() }).await;
    let v6 = quip_windows::services::ws_server::bind("[::1]:0".parse().unwrap()).await.unwrap();
    let v6_addr = v6.local_addr().unwrap();
    quip_windows::services::ws_server::spawn(h.host.clone(), v6);
    let mut waiting = vec![];
    for _ in 0..2 {
        let mut p = connect(v6_addr).await;
        p.recv().await; // auth_required
        waiting.push(p);
    }
    assert!(tokio_tungstenite::connect_async(format!("ws://{v6_addr}")).await.is_err(), "the 3rd is refused");
    assert!(
        h.log("websocket.log").contains("2 sockets from network ::/64 already waiting for auth (refused=1)"),
        "{}",
        h.log("websocket.log")
    );
    let mut v4 = connect(h.addr).await;
    assert_eq!(v4.recv().await["error"], "auth_required", "an IPv4 sender still connects");
}

#[tokio::test]
async fn closing_during_the_wrong_pin_delay_frees_the_slot_at_once() {
    let hanging: std::sync::Arc<dyn quip_windows::host::Sleeper> = std::sync::Arc::new(HangingSleeper);
    let h = start_with(Opts { sleeper: Some(hanging), ..Default::default() }).await;
    let mut p = connect(h.addr).await;
    p.recv().await; // auth_required
    p.send(json!({"type":"auth","pin":"99999999"})).await;
    wait_for(|| h.log("websocket.log").contains("incorrect PIN")).await;
    assert_eq!(h.host.unauthenticated_count(), 1, "the delay holds the slot while the socket is open");
    p.ws.close(None).await.unwrap();
    drop(p);
    wait_for(|| h.host.unauthenticated_count() == 0).await;
    assert_eq!(h.host.unauthenticated_from("127.0.0.1"), 0);
    assert_eq!(h.host.unauthenticated_from_network("127.0.0.1"), 0);
    assert_eq!(h.host.guesses_in_delay("127.0.0.1"), 1, "the guess stays counted until its delay ends");
}

/// Review R1: four IPv4 addresses with four sockets each fill all 16 slots.
/// A fifth address, holding none, still gets the greeting and pairs: it
/// evicts the oldest slot of the busiest address. The attacker's own extra
/// sockets are still refused, a retry from the evicted address too.
#[tokio::test]
async fn four_ipv4_addresses_holding_all_sixteen_slots_never_keep_a_fifth_from_pairing() {
    use quip_windows::host::{PreAuthRefusal, MAX_UNAUTHENTICATED};
    use quip_windows::services::auth_throttle::Sender;
    let h = start().await;
    let key = |s: &str| Sender::of(s.parse().unwrap());
    let mut attacker = vec![];
    for a in 1..=4 {
        for _ in 0..4 {
            attacker.push(h.host.try_pre_auth_slot(&key(&format!("198.51.100.{a}"))).unwrap());
        }
        if a == 1 {
            let fifth = h.host.try_pre_auth_slot(&key("198.51.100.1")).err();
            assert_eq!(fifth, Some(PreAuthRefusal::SenderFull), "the per-address 4 binds below the 16");
        }
    }
    assert_eq!(h.host.unauthenticated_count(), MAX_UNAUTHENTICATED);

    let mut phone = connect(h.addr).await; // 127.0.0.1 holds none
    assert_eq!(phone.recv().await["error"], "auth_required");
    assert!(attacker[0].is_evicted(), "the oldest of the busiest address");
    assert_eq!(attacker.iter().filter(|s| s.is_evicted()).count(), 1);
    assert_eq!(h.host.unauthenticated_from("198.51.100.1"), 3);
    assert_eq!(h.host.unauthenticated_count(), MAX_UNAUTHENTICATED);
    assert_eq!(h.host.try_pre_auth_slot(&key("198.51.100.1")).err(), Some(PreAuthRefusal::Full), "no retry");
    assert_eq!(h.host.try_pre_auth_slot(&key("198.51.100.2")).err(), Some(PreAuthRefusal::Full));

    phone.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(phone.recv().await["success"], true);
    assert_eq!(h.host.unauthenticated_from("127.0.0.1"), 0);
    assert_eq!(h.host.unauthenticated_count(), MAX_UNAUTHENTICATED - 1);
    assert_eq!(h.host.try_pre_auth_slot(&key("198.51.100.2")).err(), Some(PreAuthRefusal::SenderFull));
    let log = h.log("websocket.log");
    assert!(
        log.contains(
            "evicted the oldest pre-auth socket of 198.51.100.1 to admit 127.0.0.1, which held none (host full)"
        ),
        "{log}"
    );
    drop(attacker);
    assert_eq!(h.host.unauthenticated_count(), 0, "an evicted slot is counted once");
}

/// The same from inside an attacker-held /64 (`::/64`, so the real `::1`
/// is the neighbour): the attacker holds the network's 8 and, with two IPv4
/// addresses, all 16. `::1` evicts inside its network, gets the greeting
/// and pairs; the attacker's addresses in the /64 are still refused.
#[tokio::test]
async fn a_neighbour_inside_an_attacker_held_slash_64_still_pairs() {
    use quip_windows::host::{PreAuthRefusal, MAX_UNAUTHENTICATED};
    use quip_windows::services::auth_throttle::Sender;
    let h = start().await;
    let v6 = quip_windows::services::ws_server::bind("[::1]:0".parse().unwrap()).await.unwrap();
    let v6_addr = v6.local_addr().unwrap();
    quip_windows::services::ws_server::spawn(h.host.clone(), v6);
    let key = |s: &str| Sender::of(s.parse().unwrap());
    let mut in_net = vec![];
    for (a, n) in [("::2", 4), ("::3", 3), ("::4", 1)] {
        for _ in 0..n {
            in_net.push(h.host.try_pre_auth_slot(&key(a)).unwrap());
        }
    }
    assert_eq!(h.host.unauthenticated_from_network("::/64"), 8);
    assert_eq!(h.host.try_pre_auth_slot(&key("::2")).err(), Some(PreAuthRefusal::SenderFull));
    assert_eq!(h.host.try_pre_auth_slot(&key("::3")).err(), Some(PreAuthRefusal::NetworkFull));
    let mut v4 = vec![];
    for a in ["198.51.100.1", "198.51.100.2"] {
        for _ in 0..4 {
            v4.push(h.host.try_pre_auth_slot(&key(a)).unwrap());
        }
    }
    assert_eq!(h.host.unauthenticated_count(), MAX_UNAUTHENTICATED);

    let mut phone = connect(v6_addr).await;
    assert_eq!(phone.recv().await["error"], "auth_required");
    assert!(in_net[0].is_evicted(), "the oldest of the /64's busiest address");
    assert_eq!(in_net.iter().filter(|s| s.is_evicted()).count(), 1);
    assert!(v4.iter().all(|s| !s.is_evicted()), "another network's slots are not taken");
    assert_eq!(h.host.unauthenticated_from_network("::/64"), 8);
    assert_eq!(h.host.try_pre_auth_slot(&key("::2")).err(), Some(PreAuthRefusal::Full), "no retry");

    phone.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(phone.recv().await["success"], true);
    assert_eq!(h.host.unauthenticated_from_network("::/64"), 7, "the paired phone's slot is freed");
    let log = h.log("websocket.log");
    assert!(
        log.contains("evicted the oldest pre-auth socket of ::2 to admit ::1, which held none (network full)"),
        "{log}"
    );
}

/// An evicted socket is closed, even in its wrong PIN's delay, and its
/// slot is no longer counted.
#[tokio::test]
async fn an_evicted_socket_is_closed_mid_delay_and_gives_its_slot_up() {
    let hanging: std::sync::Arc<dyn quip_windows::host::Sleeper> = std::sync::Arc::new(HangingSleeper);
    let limits = quip_windows::host::ConnectionLimits { max_unauthenticated: 2, ..Default::default() };
    let h = start_with(Opts { sleeper: Some(hanging), limits, ..Default::default() }).await;
    let v6 = quip_windows::services::ws_server::bind("[::1]:0".parse().unwrap()).await.unwrap();
    let v6_addr = v6.local_addr().unwrap();
    quip_windows::services::ws_server::spawn(h.host.clone(), v6);
    let mut oldest = connect(h.addr).await;
    oldest.recv().await; // auth_required
    oldest.send(json!({"type":"auth","pin":"99999999"})).await;
    wait_for(|| h.log("websocket.log").contains("incorrect PIN")).await;
    let mut second = connect(h.addr).await;
    second.recv().await; // auth_required
    assert_eq!(h.host.unauthenticated_count(), 2);

    let mut phone = connect(v6_addr).await;
    assert_eq!(phone.recv().await["error"], "auth_required");
    assert_closed_by_host(&mut oldest).await;
    assert_eq!(h.host.unauthenticated_from("127.0.0.1"), 1);
    assert_eq!(h.host.unauthenticated_count(), 2);
    phone.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(phone.recv().await["success"], true);
    second.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(second.recv().await["success"], true, "the younger socket was kept");
    wait_for(|| h.log("websocket.log").contains("evicted for a sender with no socket waiting for auth")).await;
}

/// A right PIN gives its slot back at once, before the socket's task drops
/// it, so no eviction can pick an authenticated socket.
#[tokio::test]
async fn a_right_pin_frees_its_slot_at_once() {
    use quip_windows::services::auth_throttle::Sender;
    let h = start().await;
    let sender = Sender::of("192.0.2.1".parse().unwrap());
    let slot = h.host.try_pre_auth_slot(&sender).unwrap();
    let (id, mut rx, _kick) = h.host.register_client("192.0.2.1:50000".into());
    h.host.handle_auth(id, &sender, Some(PIN.to_string()), Some(slot.clone())).await;
    assert_eq!(recv_json(&mut rx).await["success"], true);
    assert!(h.host.is_authenticated(id));
    assert_eq!(h.host.unauthenticated_count(), 0, "freed while the slot is still held");
    drop(slot);
    assert_eq!(h.host.unauthenticated_count(), 0, "and counted once");
}

/// A right PIN on an evicted socket's slot does not authenticate it.
#[tokio::test]
async fn an_auth_on_an_evicted_slot_does_not_complete() {
    use quip_windows::services::auth_throttle::Sender;
    let limits = quip_windows::host::ConnectionLimits { max_unauthenticated: 1, ..Default::default() };
    let h = start_with(Opts { limits, ..Default::default() }).await;
    let victim_sender = Sender::of("192.0.2.1".parse().unwrap());
    let victim = h.host.try_pre_auth_slot(&victim_sender).unwrap();
    let (id, mut rx, _kick) = h.host.register_client("192.0.2.1:50000".into());
    let _newcomer = h.host.try_pre_auth_slot(&Sender::of("192.0.2.2".parse().unwrap())).unwrap();
    assert!(victim.is_evicted());
    tokio::time::timeout(Duration::from_secs(1), victim.evicted()).await.expect("the eviction is signalled");
    h.host.handle_auth(id, &victim_sender, Some(PIN.to_string()), Some(victim.clone())).await;
    assert!(!h.host.is_authenticated(id));
    assert!(rx.try_recv().is_err(), "nothing is sent");
    assert_eq!(h.host.unauthenticated_count(), 1, "only the newcomer's slot");
}

/// A wrong PIN queued for a guess token keeps its slot (spec 3.1 threat
/// math): it is never the one evicted, and with only such slots there a
/// sender holding none is refused.
#[tokio::test]
async fn a_slot_whose_wrong_pin_is_queued_is_never_evicted() {
    use quip_windows::host::{PreAuthRefusal, MAX_UNAUTHENTICATED_PER_NETWORK};
    use quip_windows::services::auth_throttle::Sender;
    for max in [1, 2] {
        let hanging: std::sync::Arc<dyn quip_windows::host::Sleeper> = std::sync::Arc::new(HangingSleeper);
        let limits = quip_windows::host::ConnectionLimits { max_unauthenticated: max, ..Default::default() };
        let h = start_with(Opts { sleeper: Some(hanging), limits, ..Default::default() }).await;
        let key = |s: &str| Sender::of(s.parse().unwrap());
        let net = "2001:db8:1:1::/64";
        let mut in_delay = vec![];
        for i in 1..=MAX_UNAUTHENTICATED_PER_NETWORK {
            in_delay.push(auth_in_background(&h, &format!("2001:db8:1:1::{i:x}"), "99999999"));
        }
        wait_for(|| h.host.guesses_in_delay(net) == MAX_UNAUTHENTICATED_PER_NETWORK).await;
        let queued_sender = key("2001:db8:1:1::ff");
        let queued = h.host.try_pre_auth_slot(&queued_sender).unwrap();
        let (id, _rx, _kick) = h.host.register_client("[2001:db8:1:1::ff]:50000".into());
        let (host, slot, qs) = (h.host.clone(), queued.clone(), queued_sender.clone());
        tokio::spawn(async move { host.handle_auth(id, &qs, Some("99999999".into()), Some(slot)).await });
        wait_for(|| h.host.guesses_queued(net) == 1).await;
        if max == 1 {
            assert_eq!(h.host.try_pre_auth_slot(&key("192.0.2.2")).err(), Some(PreAuthRefusal::Full));
        } else {
            let idle = h.host.try_pre_auth_slot(&key("192.0.2.1")).unwrap();
            let _newcomer = h.host.try_pre_auth_slot(&key("192.0.2.2")).expect("evicts the idle slot");
            assert!(idle.is_evicted(), "the idle one, though the queued one is older");
        }
        assert!(!queued.is_evicted());
        assert_eq!(h.host.unauthenticated_from("2001:db8:1:1::ff"), 1);
    }
}

/// A sender refused for its own full network must not cost anyone else a
/// socket: with the network holding only busy slots (wrong PINs queued for a
/// guess token) and the host full of other networks' idle slots, a newcomer
/// from that network is refused and every other slot survives.
#[tokio::test]
async fn a_newcomer_refused_for_its_full_network_evicts_nobody() {
    use quip_windows::host::{PreAuthRefusal, MAX_UNAUTHENTICATED_PER_NETWORK, MAX_UNAUTHENTICATED_PER_SENDER};
    use quip_windows::services::auth_throttle::Sender;
    let hanging: std::sync::Arc<dyn quip_windows::host::Sleeper> = std::sync::Arc::new(HangingSleeper);
    let h = start_with(Opts { sleeper: Some(hanging), ..Default::default() }).await;
    let key = |s: &str| Sender::of(s.parse().unwrap());
    let net = "2001:db8:1:1::/64";
    let mut in_delay = vec![];
    for i in 1..=MAX_UNAUTHENTICATED_PER_NETWORK {
        in_delay.push(auth_in_background(&h, &format!("2001:db8:1:1::{i:x}"), "99999999"));
    }
    wait_for(|| h.host.guesses_in_delay(net) == MAX_UNAUTHENTICATED_PER_NETWORK).await;
    // Fill the network with slots whose wrong PIN is queued: never evictable.
    let mut queued = vec![];
    for (n, addr) in ["2001:db8:1:1::fe", "2001:db8:1:1::ff"]
        .iter()
        .flat_map(|a| std::iter::repeat_n(*a, MAX_UNAUTHENTICATED_PER_SENDER))
        .enumerate()
    {
        let sender = key(addr);
        let slot = h.host.try_pre_auth_slot(&sender).unwrap();
        let (id, _rx, _kick) = h.host.register_client(format!("[{addr}]:{}", 50000 + n));
        let (host, s, q) = (h.host.clone(), slot.clone(), sender.clone());
        tokio::spawn(async move { host.handle_auth(id, &q, Some("99999999".into()), Some(s)).await });
        wait_for(|| h.host.guesses_queued(net) == n + 1).await;
        queued.push(slot);
    }
    assert_eq!(h.host.unauthenticated_from_network(net), MAX_UNAUTHENTICATED_PER_NETWORK);
    // Fill the rest of the host with idle IPv4 slots (evictable).
    let mut idle = vec![];
    for a in ["192.0.2.1", "192.0.2.2"] {
        for _ in 0..MAX_UNAUTHENTICATED_PER_SENDER {
            idle.push(h.host.try_pre_auth_slot(&key(a)).unwrap());
        }
    }
    assert_eq!(h.host.unauthenticated_count(), quip_windows::host::MAX_UNAUTHENTICATED);
    assert_eq!(h.host.try_pre_auth_slot(&key("2001:db8:1:1::fd")).err(), Some(PreAuthRefusal::NetworkFull));
    assert!(idle.iter().all(|s| !s.is_evicted()), "no other network's socket was evicted");
    assert!(queued.iter().all(|s| !s.is_evicted()));
    assert_eq!(h.host.unauthenticated_count(), quip_windows::host::MAX_UNAUTHENTICATED);
}

/// Closing early frees the socket but not the guess. With all 8 of a
/// network's guess tokens in their delay its right PIN still pairs, and
/// its next wrong PINs queue, each keeping its socket's slot after a close,
/// so they stop at the per-address socket cap instead of guessing on.
#[tokio::test]
async fn a_network_with_eight_wrong_pins_in_their_delay_queues_the_next_and_still_pairs() {
    use quip_windows::host::{MAX_UNAUTHENTICATED_PER_NETWORK, MAX_UNAUTHENTICATED_PER_SENDER};
    let hanging: std::sync::Arc<dyn quip_windows::host::Sleeper> = std::sync::Arc::new(HangingSleeper);
    let h = start_with(Opts { sleeper: Some(hanging), ..Default::default() }).await;
    let v6 = quip_windows::services::ws_server::bind("[::1]:0".parse().unwrap()).await.unwrap();
    let v6_addr = v6.local_addr().unwrap();
    quip_windows::services::ws_server::spawn(h.host.clone(), v6);
    for n in 1..=MAX_UNAUTHENTICATED_PER_NETWORK {
        let mut q = connect(h.addr).await;
        q.recv().await;
        q.send(json!({"type":"auth","pin":"99999999"})).await;
        wait_for(|| h.host.guesses_in_delay("127.0.0.1") == n).await;
        q.ws.close(None).await.unwrap();
    }
    wait_for(|| h.host.unauthenticated_count() == 0).await;
    let mut owner = connect(h.addr).await;
    owner.recv().await;
    owner.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(owner.recv().await["success"], true, "the right PIN is checked first and pairs");
    for n in 1..=MAX_UNAUTHENTICATED_PER_SENDER {
        let mut q = connect(h.addr).await;
        q.recv().await;
        q.send(json!({"type":"auth","pin":"99999999"})).await;
        wait_for(|| h.host.guesses_queued("127.0.0.1") == n).await;
        q.ws.close(None).await.unwrap();
    }
    assert_eq!(h.host.guesses_in_delay("127.0.0.1"), MAX_UNAUTHENTICATED_PER_NETWORK);
    // The queued PINs' sockets are closed, but they keep their slots.
    wait_for(|| h.host.client_ids().len() == 1).await; // only the owner
    assert_eq!(h.host.unauthenticated_from("127.0.0.1"), MAX_UNAUTHENTICATED_PER_SENDER);
    assert!(tokio_tungstenite::connect_async(format!("ws://{}", h.addr)).await.is_err(), "no 5th guess");
    let log = h.log("websocket.log");
    assert_eq!(log.matches("incorrect PIN").count(), 12, "8 in their delay, 4 queued: {log}");
    assert_eq!(log.matches("auth: 127.0.0.1 wrong PIN queued: network 127.0.0.1 has 8").count(), 4, "{log}");
    assert!(!log.contains("Too many attempts"), "{log}");
    let mut other = connect(v6_addr).await;
    assert_eq!(other.recv().await["error"], "auth_required");
    other.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(other.recv().await["success"], true, "another network still pairs");
}

/// `handle_auth` from `ip` on a fresh client, in a task of its own (a wrong
/// PIN's reply may wait for its delay). The client's replies.
fn auth_in_background(h: &Harness, ip: &str, pin: &str) -> tokio::sync::mpsc::Receiver<String> {
    use quip_windows::services::auth_throttle::Sender;
    let (id, rx, _kick) = h.host.register_client(format!("[{ip}]:50000"));
    let host = h.host.clone();
    let sender = Sender::of(ip.parse().unwrap());
    let pin = pin.to_string();
    tokio::spawn(async move { host.handle_auth(id, &sender, Some(pin), None).await });
    rx
}

/// The security review's case against the all-senders cap: an attacker on
/// two networks holds all 16 guess tokens there. The owner's right PIN, from
/// a third network or from inside an attacker's, pairs at once, and a third
/// network's wrong PIN still gets a token of its own.
#[tokio::test]
async fn attacker_tokens_on_two_networks_never_refuse_the_owners_right_pin() {
    use quip_windows::host::MAX_UNAUTHENTICATED_PER_NETWORK;
    let hanging: std::sync::Arc<dyn quip_windows::host::Sleeper> = std::sync::Arc::new(HangingSleeper);
    let h = start_with(Opts { sleeper: Some(hanging), ..Default::default() }).await;
    let mut attacker = vec![];
    for net in ["2001:db8:1:1", "2001:db8:1:2"] {
        for i in 1..=MAX_UNAUTHENTICATED_PER_NETWORK {
            attacker.push(auth_in_background(&h, &format!("{net}::{i:x}"), "99999999"));
        }
        wait_for(|| h.host.guesses_in_delay(&format!("{net}::/64")) == MAX_UNAUTHENTICATED_PER_NETWORK).await;
    }
    assert_eq!(auth_from(&h, "192.0.2.1", PIN).await["success"], true, "a third address pairs");
    assert_eq!(auth_from(&h, "2001:db8:1:1::ff", PIN).await["success"], true, "a neighbour pairs too");
    let _third = auth_in_background(&h, "2001:db8:1:3::1", "99999999");
    wait_for(|| h.host.guesses_in_delay("2001:db8:1:3::/64") == 1).await;
    assert_eq!(h.host.guesses_queued("2001:db8:1:3::/64"), 0, "no cap across networks");
    for rx in &mut attacker {
        assert!(rx.try_recv().is_err(), "every attacker guess is still in its delay");
    }
    assert!(!h.log("websocket.log").contains("refused"), "{}", h.log("websocket.log"));
}

/// A wrong PIN finding its network's tokens taken is delayed, not refused:
/// it is answered `Incorrect PIN` only after a token frees and its own delay
/// ends, so the network never has more than its cap of guesses in a delay.
#[tokio::test]
async fn a_wrong_pin_with_no_free_token_waits_for_one_instead_of_being_refused() {
    let gate = std::sync::Arc::new(GateSleeper::new());
    let sleeper: std::sync::Arc<dyn quip_windows::host::Sleeper> = gate.clone();
    let limits = quip_windows::host::ConnectionLimits { max_unauthenticated_per_network: 2, ..Default::default() };
    let h = start_with(Opts { sleeper: Some(sleeper), limits, ..Default::default() }).await;
    let net = "2001:db8:1:1::/64";
    let mut a = auth_in_background(&h, "2001:db8:1:1::a", "99999999");
    wait_for(|| h.host.guesses_in_delay(net) == 1).await;
    let mut b = auth_in_background(&h, "2001:db8:1:1::b", "99999999");
    wait_for(|| h.host.guesses_in_delay(net) == 2).await;
    let mut c = auth_in_background(&h, "2001:db8:1:1::c", "99999999");
    wait_for(|| h.host.guesses_queued(net) == 1).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(c.try_recv().is_err(), "queued, not refused");
    assert_eq!(h.host.guesses_in_delay(net), 2);

    gate.release(1); // a's delay ends; c takes its token and starts its own
    assert_eq!(recv_json(&mut a).await["error"], "Incorrect PIN");
    wait_for(|| h.host.guesses_queued(net) == 0).await;
    assert_eq!(h.host.guesses_in_delay(net), 2, "c holds a's token: still at the cap");
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(c.try_recv().is_err(), "c still waits its own delay");

    gate.release(2);
    assert_eq!(recv_json(&mut b).await["error"], "Incorrect PIN");
    assert_eq!(recv_json(&mut c).await["error"], "Incorrect PIN");
    wait_for(|| h.host.guesses_in_delay(net) == 0).await;
    assert!(!h.log("websocket.log").contains("Too many"), "{}", h.log("websocket.log"));
}

async fn recv_json(rx: &mut tokio::sync::mpsc::Receiver<String>) -> serde_json::Value {
    let text = tokio::time::timeout(Duration::from_secs(5), rx.recv()).await.unwrap().unwrap();
    serde_json::from_str(&text).unwrap()
}

#[tokio::test]
async fn a_frame_sent_during_the_wrong_pin_delay_is_kept() {
    let h = start_with(Opts { real_sleeper: true, ..Default::default() }).await;
    let mut p = connect(h.addr).await;
    p.recv().await; // auth_required
    p.send(json!({"type":"auth","pin":"99999999"})).await;
    p.send(json!({"type":"auth","pin":PIN})).await;
    assert_eq!(p.recv().await["error"], "Incorrect PIN");
    assert_eq!(p.recv().await["success"], true, "the PIN queued behind the delay is answered");
    assert_eq!(h.host.unauthenticated_count(), 0);
    assert_eq!(h.host.guesses_in_delay("127.0.0.1"), 0, "a finished delay gives its guess back");
}

/// Polls `cond` for up to 5 s.
async fn wait_for(cond: impl Fn() -> bool) {
    for _ in 0..250 {
        if cond() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("condition not met within 5 s");
}

/// Auth from `ip` on a fresh client, straight through `Host::handle_auth`
/// (a loopback socket cannot come from 2001:db8::/32). The first reply.
async fn auth_from(h: &Harness, ip: &str, pin: &str) -> serde_json::Value {
    use quip_windows::services::auth_throttle::Sender;
    let (id, mut rx, _kick) = h.host.register_client(format!("[{ip}]:50000"));
    h.host.handle_auth(id, &Sender::of(ip.parse().unwrap()), Some(pin.to_string()), None).await;
    let reply = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
    h.host.remove_client(id);
    reply
}

#[tokio::test]
async fn two_addresses_in_one_slash_64_do_not_share_a_lockout() {
    let h = start().await;
    for _ in 0..10 {
        assert_eq!(auth_from(&h, "2001:db8:1:2::a", "99999999").await["error"], "Incorrect PIN");
    }
    let locked = auth_from(&h, "2001:db8:1:2::a", PIN).await;
    assert!(locked["error"].as_str().unwrap().starts_with("Too many attempts"), "{locked}");
    assert_eq!(auth_from(&h, "2001:db8:1:2::b", PIN).await["success"], true, "the neighbour pairs");
    // And the other way round: b's lockout leaves a fresh c pairing too.
    for _ in 0..10 {
        auth_from(&h, "2001:db8:1:2::b", "99999999").await;
    }
    assert!(auth_from(&h, "2001:db8:1:2::b", PIN).await["error"].as_str().unwrap().starts_with("Too many"));
    assert_eq!(auth_from(&h, "2001:db8:1:2::c", PIN).await["success"], true);
    assert!(h.log("websocket.log").contains("auth: 2001:db8:1:2::a locked"), "{}", h.log("websocket.log"));
}

#[tokio::test]
async fn rotating_addresses_in_one_slash_64_get_a_growing_delay_but_the_right_pin_still_pairs() {
    let h = start().await;
    for i in 0..13u32 {
        let r = auth_from(&h, &format!("2001:db8:1:2::{:x}", 0x100 + i), "99999999").await;
        assert_eq!(r["error"], "Incorrect PIN", "rotation is never locked out");
    }
    let delays: Vec<u64> = h.sleeper.delays.lock().unwrap().iter().map(|d| d.as_millis() as u64).collect();
    assert_eq!(delays, [200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 2_200, 2_400, 2_600]);
    assert_eq!(auth_from(&h, "2001:db8:1:2::1", PIN).await["success"], true);
    assert_eq!(h.sleeper.delays.lock().unwrap().len(), 13, "a right PIN is answered without a delay");
}

/// The 1.6.0 phone's frames right after connect, in its order. Six count
/// against the 10/s limit (`auth` is exempt, as on the Mac), so none is dropped.
#[tokio::test]
async fn the_phones_connect_burst_is_not_rate_limited() {
    let h = start().await;
    let mut p = connect(h.addr).await;
    assert_eq!(p.recv().await["error"], "auth_required");
    let wid = h.window_id(101);
    let burst = [
        json!({"type":"auth","pin":PIN}),
        json!({"type":"device_identity","deviceID":"PHONE-A","deviceKind":"ios","displayName":"phone"}),
        json!({"type":"preferences_snapshot","deviceID":"PHONE-A","preferences":{"pushSound":true}}),
        json!({"type":"request_content","windowId":wid}),
        json!({"type":"register_push_device","deviceToken":"00ff","environment":"development"}),
        json!({"type":"push_preferences","deviceToken":"00ff","paused":false}),
        json!({"type":"phone_log","lines":["burst-last-frame"]}),
    ];
    for f in burst {
        p.send(f).await;
    }
    assert_eq!(p.recv().await["success"], true);
    assert_eq!(p.recv_type("terminal_content").await["windowId"], wid);
    for _ in 0..100 {
        if h.log("phone.log").contains("burst-last-frame") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(h.log("phone.log").contains("burst-last-frame"), "the last frame was handled");
    assert!(!h.log("websocket.log").contains("rate limit"), "{}", h.log("websocket.log"));
    // Four more fill the window; the fifth is dropped and its type logged.
    for _ in 0..4 {
        p.send(json!({"type":"heartbeat_ack","seq":0})).await;
    }
    p.send(json!({"type":"request_content","windowId":wid})).await;
    p.assert_silent(QUIET).await;
    assert!(h.log("websocket.log").contains("over 10/s (first type=request_content)"), "{}", h.log("websocket.log"));
}
