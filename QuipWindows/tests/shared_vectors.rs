//! Spec 10.2: the parity contract. The Swift side writes or checks every file
//! under `Shared/Tests/Fixtures/{wire,vectors}/`; these tests hold the Rust
//! rules to the same files. A change on either side that breaks the other
//! fails here. Expected values are never typed into this file.

use std::collections::HashSet;
use std::path::PathBuf;

use quip_windows::app_state::AppState;
use quip_windows::platform::traits::{PlatformDisplay, PlatformWindow, WindowRef};
use quip_windows::protocol::messages::{
    decode_incoming, AuthResult, DeviceIdentity, ErrorMessage, FrontmostChanged, Heartbeat, Incoming, LayoutUpdate,
    PreferenceRestore, SendTextAck, StateChange, TerminalContent,
};
use quip_windows::protocol::types::WireUuid;
use quip_windows::protocol::types::{ArrangeLayout, CliKind};
use quip_windows::services::broadcast::{windows_for_broadcast, BroadcastCandidate};
use quip_windows::services::classify::TerminalHost;
use quip_windows::services::geometry::{self, DisplayEntry, DisplayRect};
use quip_windows::services::injection_log::{self, InjectionKind};
use quip_windows::services::layout::{self, LayoutMode, NormRect, PixelRect};
use quip_windows::services::multiline_policy::{self as mp, Shell, TerminalApp, WindowsSend};
use quip_windows::services::pairing::PairingPayload;
use quip_windows::services::window_color;
use serde_json::{json, Value};

fn fixtures() -> PathBuf {
    // Override for a copied tree (cargo-mutants copies only this crate).
    if let Ok(p) = std::env::var("QUIP_SHARED_FIXTURES") {
        return PathBuf::from(p);
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("Shared").join("Tests").join("Fixtures")
}

fn load(rel: &str) -> Value {
    let p = fixtures().join(rel);
    let text = std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    serde_json::from_str(&text).unwrap()
}

fn cases<'a>(v: &'a Value, section: &str) -> &'a Vec<Value> {
    let c = v[section].as_array().unwrap_or_else(|| panic!("no section {section}"));
    assert!(!c.is_empty(), "section {section} is empty");
    c
}

fn f(v: &Value) -> f64 {
    v.as_f64().unwrap_or_else(|| panic!("not a number: {v}"))
}

fn close(a: f64, b: f64, eps: f64) -> bool {
    (a - b).abs() <= eps
}

fn rect(v: &Value) -> DisplayRect {
    DisplayRect::new(f(&v["x"]), f(&v["y"]), f(&v["width"]), f(&v["height"]))
}

fn frame_eq(got: quip_windows::protocol::types::WindowFrame, want: &Value, eps: f64) -> bool {
    close(got.x, f(&want["x"]), eps)
        && close(got.y, f(&want["y"]), eps)
        && close(got.width, f(&want["width"]), eps)
        && close(got.height, f(&want["height"]), eps)
}

// --- wire/ ---

/// Same keys, kinds and values, recursively. A null in the fixture may be
/// absent from ours (Swift omits nil). Numbers compare as numbers.
fn same_shape(path: &str, fixture: &Value, ours: &Value, errs: &mut Vec<String>) {
    match (fixture, ours) {
        (Value::Object(a), Value::Object(b)) => {
            for (k, v) in a {
                match b.get(k) {
                    Some(w) => same_shape(&format!("{path}.{k}"), v, w, errs),
                    None if v.is_null() => {}
                    None => errs.push(format!("{path}.{k}: missing from the Rust encoding")),
                }
            }
            for k in b.keys() {
                if !a.contains_key(k) {
                    errs.push(format!("{path}.{k}: extra key in the Rust encoding"));
                }
            }
        }
        (Value::Array(a), Value::Array(b)) => {
            if a.len() != b.len() {
                errs.push(format!("{path}: length {} vs {}", a.len(), b.len()));
            }
            for (i, (x, y)) in a.iter().zip(b).enumerate() {
                same_shape(&format!("{path}[{i}]"), x, y, errs);
            }
        }
        (Value::Number(x), Value::Number(y)) => {
            if x.as_f64() != y.as_f64() {
                errs.push(format!("{path}: {x} vs {y}"));
            }
        }
        (Value::Null, Value::Null) => {}
        (a, b) if a == b => {}
        (a, b) => errs.push(format!("{path}: {a} vs {b}")),
    }
}

fn reencode_host_to_phone(type_: &str, v: &Value) -> Result<Value, String> {
    fn rt<T: serde::de::DeserializeOwned + serde::Serialize>(v: &Value) -> Result<Value, String> {
        let t: T = serde_json::from_value(v.clone()).map_err(|e| e.to_string())?;
        serde_json::to_value(&t).map_err(|e| e.to_string())
    }
    match type_ {
        "auth_result" => rt::<AuthResult>(v),
        "device_identity" => rt::<DeviceIdentity>(v),
        "layout_update" => rt::<LayoutUpdate>(v),
        "frontmost_changed" => rt::<FrontmostChanged>(v),
        "heartbeat" => rt::<Heartbeat>(v),
        "send_text_ack" => rt::<SendTextAck>(v),
        "error" => rt::<ErrorMessage>(v),
        "state_change" => rt::<StateChange>(v),
        "preferences_restore" => rt::<PreferenceRestore>(v),
        other => Err(format!("no Rust host->phone type for {other}")),
    }
}

fn reencode_phone_to_host(v: &Value) -> Result<Value, String> {
    let m = decode_incoming(&v.to_string()).map_err(|e| format!("{e:?}"))?;
    let (t, mut body) = match &m {
        Incoming::Auth(x) => ("auth", serde_json::to_value(x)),
        Incoming::HeartbeatAck(x) => ("heartbeat_ack", serde_json::to_value(x)),
        Incoming::SelectWindow(x) => ("select_window", serde_json::to_value(x)),
        Incoming::SendText(x) => ("send_text", serde_json::to_value(x)),
        Incoming::QuickAction(x) => ("quick_action", serde_json::to_value(x)),
        Incoming::ArrangeWindows(x) => ("arrange_windows", serde_json::to_value(x)),
        Incoming::MinimizeWindow(x) => ("minimize_window", serde_json::to_value(x)),
        Incoming::CloseWindow(x) => ("close_window", serde_json::to_value(x)),
        Incoming::PhoneLog(x) => ("phone_log", serde_json::to_value(x)),
        Incoming::PreferencesSnapshot(x) => ("preferences_snapshot", serde_json::to_value(x)),
        Incoming::PreferencesRequest(x) => ("preferences_request", serde_json::to_value(x)),
        Incoming::RequestContent(x) => ("request_content", serde_json::to_value(x)),
    };
    let b = body.as_mut().map_err(|e| e.to_string())?;
    b.as_object_mut().ok_or("not an object")?.insert("type".into(), json!(t));
    Ok(b.clone())
}

#[test]
fn wire_fixtures_decode_and_reencode_with_the_same_shape() {
    let index = load("wire/index.json");
    let list = cases(&index, "fixtures");
    let mut failures = vec![];
    for entry in list {
        let file = entry["file"].as_str().unwrap();
        let type_ = entry["type"].as_str().unwrap();
        let dir = entry["direction"].as_str().unwrap();
        let v = load(&format!("wire/{file}"));
        assert_eq!(v["type"], type_, "{file}");
        let ours =
            if dir.starts_with("phone") { reencode_phone_to_host(&v) } else { reencode_host_to_phone(type_, &v) };
        match ours {
            Err(e) => failures.push(format!("{file}: {e}")),
            Ok(ours) => {
                let mut errs = vec![];
                same_shape(file, &v, &ours, &mut errs);
                failures.extend(errs);
            }
        }
    }
    assert!(failures.is_empty(), "{} wire failures:\n{}", failures.len(), failures.join("\n"));
    let files: Vec<_> = std::fs::read_dir(fixtures().join("wire"))
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n != "index.json")
        .collect();
    assert_eq!(files.len(), list.len(), "every wire file is listed in index.json");
}

// --- host-built messages against the wire fixtures ---

fn json_kind(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

/// What the host BUILDS (not a re-encoded fixture) must look like Swift's
/// encoding: every key it writes exists in `full` with the same kind
/// (objects recursively, arrays by their first element), and every key in
/// `min` (the fields Swift always writes) is written.
fn check_built(path: &str, built: &Value, min: Option<&Value>, full: &Value, errs: &mut Vec<String>) {
    match (built, full) {
        (Value::Object(b), Value::Object(f)) => {
            for (k, v) in b {
                match f.get(k) {
                    None => errs.push(format!("{path}.{k}: written by the host, absent from the fixture")),
                    Some(fv) if fv.is_null() => {}
                    Some(fv) => check_built(&format!("{path}.{k}"), v, min.and_then(|m| m.get(k)), fv, errs),
                }
            }
            if let Some(Value::Object(m)) = min {
                for k in m.keys() {
                    if !b.contains_key(k) {
                        errs.push(format!("{path}.{k}: always written by Swift, missing from the host's message"));
                    }
                }
            }
        }
        (Value::Array(b), Value::Array(f)) => {
            if let Some(f0) = f.first() {
                let m0 = min.and_then(|m| m.as_array()).and_then(|a| a.first());
                for (i, x) in b.iter().enumerate() {
                    check_built(&format!("{path}[{i}]"), x, m0, f0, errs);
                }
            }
        }
        (b, f) if json_kind(b) != json_kind(f) => {
            errs.push(format!("{path}: host writes {}, fixture has {}", json_kind(b), json_kind(f)))
        }
        _ => {}
    }
}

fn built(file_min: Option<&str>, file_full: &str, v: Value, errs: &mut Vec<String>) {
    let full = load(&format!("wire/{file_full}"));
    let min = file_min.map(|m| load(&format!("wire/{m}")));
    assert_eq!(v["type"], full["type"], "{file_full}");
    check_built(file_full, &v, min.as_ref(), &full, errs);
}

fn layout_from_app_state() -> Value {
    let display = |name: &str, x: i32, primary: bool| PlatformDisplay {
        device_name: format!(r"\\.\{name}"),
        name: name.into(),
        bounds: PixelRect::new(x, 0, 1920, 1080),
        work_area: PixelRect::new(x, 0, 1920, 1040),
        is_primary: primary,
    };
    let win = |handle: u64, terminal: bool, x: i32, minimized: bool| PlatformWindow {
        handle,
        pid: 7,
        title: format!("w{handle}"),
        class_name: "C".into(),
        exe_path: None,
        app: if terminal { "Windows Terminal".into() } else { "Notepad".into() },
        terminal: terminal.then_some(TerminalHost::WindowsTerminal),
        shell: terminal.then_some(Shell::Pwsh),
        visible: PixelRect::new(x, 0, 960, 540),
        outer: PixelRect::new(x - 7, 0, 974, 547),
        is_minimized: minimized,
        is_maximized: false,
    };
    let mut s = AppState::new(Default::default(), true);
    s.update(
        vec![win(1, true, 0, false), win(2, false, 2000, true)],
        vec![display("DISPLAY1", 0, true), display("DISPLAY2", 1920, false)],
        Some(WindowRef { handle: 1, pid: 7 }),
    );
    let id = s.windows()[0].id.clone();
    s.toggle_enabled(&id);
    serde_json::to_value(s.snapshot()).unwrap()
}

#[test]
fn host_built_messages_match_the_wire_fixtures() {
    let mut errs = vec![];
    let ok = serde_json::to_value(AuthResult::success()).unwrap();
    built(Some("auth_result.min.json"), "auth_result.full.json", ok, &mut errs);
    let req = serde_json::to_value(AuthResult::auth_required()).unwrap();
    assert_eq!(req["error"], "auth_required");
    built(Some("auth_result.min.json"), "auth_result.full.json", req, &mut errs);
    let id = DeviceIdentity::windows("00000000-0000-4000-8000-000000000001".into(), "PC".into(), vec![]);
    built(Some("device_identity.min.json"), "device_identity.full.json", serde_json::to_value(id).unwrap(), &mut errs);
    let id = DeviceIdentity::windows("x".into(), "PC".into(), vec!["ws://192.0.2.1:8765".into()]);
    let idv = serde_json::to_value(id).unwrap();
    assert_eq!(idv["deviceKind"], load("wire/device_identity.min.json")["deviceKind"]);
    built(Some("device_identity.min.json"), "device_identity.full.json", idv, &mut errs);
    let hb = serde_json::to_value(Heartbeat::new(3, 1_762_387_200.25)).unwrap();
    built(Some("heartbeat.min.json"), "heartbeat.min.json", hb, &mut errs);
    let layout = layout_from_app_state();
    assert_eq!(layout["windows"].as_array().unwrap().len(), 2, "terminal + minimized app (show all apps)");
    built(Some("layout_update.min.json"), "layout_update.full.json", layout.clone(), &mut errs);
    for w in layout["windows"].as_array().unwrap() {
        for k in ["isThinking", "isPinned", "isMinimized"] {
            assert!(w[k].is_boolean(), "{k} always written: {w}");
        }
    }
    let front = serde_json::to_value(FrontmostChanged::new(None)).unwrap();
    built(Some("frontmost_changed.min.json"), "frontmost_changed.full.json", front, &mut errs);
    let front = serde_json::to_value(FrontmostChanged::new(Some("w-1".into()))).unwrap();
    built(Some("frontmost_changed.full.json"), "frontmost_changed.full.json", front, &mut errs);
    let ack = SendTextAck::new(WireUuid::parse("6BA7B810-9DAD-11D1-80B4-00C04FD430C8").unwrap(), 1, 2);
    built(Some("send_text_ack.min.json"), "send_text_ack.min.json", serde_json::to_value(ack).unwrap(), &mut errs);
    let e = serde_json::to_value(ErrorMessage::new("Window no longer exists", None)).unwrap();
    built(Some("error.min.json"), "error.full.json", e, &mut errs);
    assert!(errs.is_empty(), "{} host-built failures:\n{}", errs.len(), errs.join("\n"));
}

/// `terminal_content` has no Shared fixture yet (Shared/ is not changed in
/// M1), so the Rust side carries one, written from `TerminalContentMessage`'s
/// synthesized Swift encoding: the four always-written keys, nil optionals
/// omitted.
#[test]
fn terminal_content_matches_the_swift_encoding() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/terminal_content.min.json");
    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let ours = serde_json::to_value(TerminalContent::not_available("w-1a2b3c".into())).unwrap();
    let mut errs = vec![];
    same_shape("terminal_content", &fixture, &ours, &mut errs);
    assert!(errs.is_empty(), "{errs:?}");
    assert_eq!(ours["content"], "Terminal text is not available on Windows yet.");
    let back: TerminalContent = serde_json::from_value(fixture).unwrap();
    assert_eq!(back, TerminalContent::not_available("w-1a2b3c".into()));
}

// --- vectors/multiline.json ---

fn cli(s: &str) -> CliKind {
    serde_json::from_value(json!(s)).unwrap()
}

#[test]
fn multiline_vectors_mac_policy() {
    let v = load("vectors/multiline.json");
    let cs = cases(&v, "cases");
    for c in cs {
        let (i, e, name) = (&c["input"], &c["expect"], c["name"].as_str().unwrap());
        let text = i["text"].as_str().unwrap();
        let app = TerminalApp::from_raw(i["terminalApp"].as_str().unwrap()).unwrap();
        let pr = i["pressReturn"].as_bool().unwrap();
        let (route, ret) = mp::decide(text, cli(i["cliKind"].as_str().unwrap()), app, pr);
        let norm = mp::normalized_text(text);
        assert_eq!(norm, e["normalizedText"].as_str().unwrap(), "{name}");
        assert_eq!(mp::is_multi_line(norm), e["isMultiLine"].as_bool().unwrap(), "{name}");
        assert_eq!(mp::line_count(norm) as u64, e["lineCount"].as_u64().unwrap(), "{name}");
        assert_eq!(route.as_str(), e["route"].as_str().unwrap(), "{name}");
        assert_eq!(ret, e["pressReturn"].as_bool().unwrap(), "{name}");
        assert_eq!(mp::latency_suffix(pr, ret, text), e["latencySuffix"].as_str().unwrap(), "{name}");
    }
    eprintln!("multiline: {} cases", cs.len());
}

/// The Windows rule on top of the shell cases (spec 5.4 step 5): PowerShell
/// types the same lines with Shift+Enter and the same Return decision; cmd /
/// unknown refuse exactly the multi-line ones.
#[test]
fn multiline_vectors_windows_rule_on_the_shell_cases() {
    let v = load("vectors/multiline.json");
    let mut n = 0;
    for c in cases(&v, "cases") {
        let (i, e, name) = (&c["input"], &c["expect"], c["name"].as_str().unwrap());
        if i["cliKind"] != "shell" || i["terminalApp"] == "Claude" {
            continue;
        }
        n += 1;
        let text = i["text"].as_str().unwrap();
        let pr = i["pressReturn"].as_bool().unwrap();
        let multi = e["isMultiLine"].as_bool().unwrap();
        for shell in [Shell::PowerShell, Shell::Pwsh] {
            let d = mp::windows_decide(text, shell, pr);
            let WindowsSend::Type { segments, press_return } = &d else { panic!("{name}: PowerShell refused") };
            assert_eq!(*press_return, e["pressReturn"].as_bool().unwrap(), "{name}");
            assert_eq!(segments.len() as u64, if multi { e["lineCount"].as_u64().unwrap() } else { 1 }, "{name}");
            if !multi {
                assert_eq!(segments[0], e["normalizedText"].as_str().unwrap(), "{name}");
            }
            assert!(segments.iter().all(|s| !mp::is_multi_line(s)), "{name}: no break is ever typed");
        }
        for shell in [Shell::Cmd, Shell::Unknown] {
            assert_eq!(mp::windows_decide(text, shell, pr) == WindowsSend::Refuse, multi, "{name}");
        }
    }
    assert!(n > 0);
    eprintln!("multiline (Windows rule): {n} shell cases");
}

// --- vectors/display_geometry.json ---

#[test]
fn display_geometry_vectors() {
    let v = load("vectors/display_geometry.json");
    for c in cases(&v, "normalize") {
        let got = geometry::normalize(rect(&c["input"]["window"]), rect(&c["input"]["display"]));
        assert!(frame_eq(got, &c["expect"], 1e-9), "{}: {got:?}", c["name"]);
    }
    for c in cases(&v, "span") {
        let ds: Vec<DisplayRect> = c["input"]["displays"].as_array().unwrap().iter().map(rect).collect();
        let s = geometry::span(&ds);
        assert_eq!(s, rect(&c["expect"]), "{}", c["name"]);
    }
    for c in cases(&v, "scenes") {
        let name = &c["name"];
        let ds: Vec<DisplayEntry> = c["input"]["displays"]
            .as_array()
            .unwrap()
            .iter()
            .map(|d| DisplayEntry {
                id: d["id"].as_str().unwrap().into(),
                is_primary: d["isPrimary"].as_bool().unwrap(),
                rect: rect(&d["rect"]),
            })
            .collect();
        let rects: Vec<DisplayRect> = ds.iter().map(|d| d.rect).collect();
        let span = geometry::span(&rects);
        assert_eq!(span, rect(&c["expect"]["span"]), "{name}");
        match c["expect"]["spanAspect"].as_f64() {
            Some(a) => assert!(close(geometry::aspect(span).unwrap(), a, 1e-9), "{name}"),
            None => assert_eq!(geometry::aspect(span), None, "{name}"),
        }
        for (d, want) in ds.iter().zip(c["expect"]["displays"].as_array().unwrap()) {
            assert_eq!(d.id, want["id"].as_str().unwrap());
            assert!(close(geometry::aspect(d.rect).unwrap_or(1.0), f(&want["aspect"]), 1e-9), "{name}");
            assert!(frame_eq(geometry::span_frame(d.rect, span), &want["spanFrame"], 1e-9), "{name}");
        }
        for (w, want) in
            c["input"]["windows"].as_array().unwrap().iter().zip(c["expect"]["windows"].as_array().unwrap())
        {
            let wr = rect(w);
            let id = geometry::display_id_for_window(wr, &ds);
            assert_eq!(id.as_deref(), want["displayID"].as_str(), "{name}");
            let Some(d) = ds.iter().find(|d| Some(&d.id) == id.as_ref()) else {
                // No displays at all: no id, no frame (the doc's empty-list case).
                assert!(want["frame"].is_null() && want["spanFrame"].is_null(), "{name}");
                continue;
            };
            let frame = geometry::normalize(wr, d.rect);
            assert!(frame_eq(frame, &want["frame"], 1e-9), "{name}: {frame:?}");
            let composed = geometry::compose(frame, geometry::span_frame(d.rect, span));
            assert!(frame_eq(composed, &want["spanFrame"], 1e-9), "{name}");
        }
    }
}

// --- vectors/broadcast_filter.json ---

struct W {
    id: String,
    kind: String,
    enabled: bool,
    visible: bool,
}
impl BroadcastCandidate for W {
    fn id(&self) -> &str {
        &self.id
    }
    fn is_enabled(&self) -> bool {
        self.enabled
    }
    fn is_terminal(&self) -> bool {
        self.kind == "terminal"
    }
    fn is_target(&self) -> bool {
        self.kind == "simulator"
    }
    fn is_on_visible_screen(&self) -> bool {
        self.visible
    }
}

#[test]
fn broadcast_filter_vectors() {
    let v = load("vectors/broadcast_filter.json");
    for c in cases(&v, "cases") {
        let i = &c["input"];
        let ws: Vec<W> = i["windows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| W {
                id: w["id"].as_str().unwrap().into(),
                kind: w["kind"].as_str().unwrap().into(),
                enabled: w["enabled"].as_bool().unwrap(),
                visible: w["onVisibleScreen"].as_bool().unwrap(),
            })
            .collect();
        let pair = i["qaPair"].as_array().map(|p| (p[0].as_str().unwrap(), p[1].as_str().unwrap()));
        let got: Vec<&str> = windows_for_broadcast(
            &ws,
            i["mirrorDesktop"].as_bool().unwrap(),
            i["mirrorAllApps"].as_bool().unwrap(),
            pair,
        )
        .into_iter()
        .map(|w| w.id.as_str())
        .collect();
        let want: Vec<&str> = c["expect"].as_array().unwrap().iter().map(|x| x.as_str().unwrap()).collect();
        assert_eq!(got, want, "{}", c["name"]);
    }
}

// --- vectors/arrange.json ---

#[test]
fn arrange_vectors() {
    let v = load("vectors/arrange.json");
    for c in cases(&v, "cases") {
        let (i, e, name) = (&c["input"], &c["expect"], &c["name"]);
        let layout: ArrangeLayout = serde_json::from_value(i["layout"].clone()).unwrap();
        let mode = LayoutMode::from_arrange(layout);
        assert_eq!(e["mode"], if mode == LayoutMode::Columns { "columns" } else { "rows" }, "{name}");
        let n = i["windowCount"].as_u64().unwrap() as usize;
        let norm = layout::calculate(mode, n);
        let want_norm = e["normalized"].as_array().unwrap();
        assert_eq!(norm.len(), want_norm.len(), "{name}");
        for (g, w) in norm.iter().zip(want_norm) {
            let g = quip_windows::protocol::types::WindowFrame { x: g.x, y: g.y, width: g.width, height: g.height };
            assert!(frame_eq(g, w, 1e-9), "{name}");
        }
        let wa = &i["targetRect"];
        let area =
            PixelRect::new(f(&wa["x"]) as i32, f(&wa["y"]) as i32, f(&wa["width"]) as i32, f(&wa["height"]) as i32);
        let px = layout::to_pixels(&norm, area);
        for (g, w) in px.iter().zip(e["rects"].as_array().unwrap()) {
            for (a, b) in [(g.x, &w["x"]), (g.y, &w["y"]), (g.width, &w["width"]), (g.height, &w["height"])] {
                assert!(close(f64::from(a), f(b), 1.0), "{name}: {g:?} vs {w}");
            }
        }
        let _ = NormRect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };
    }
}

// --- vectors/pairing.json ---

#[test]
fn pairing_vectors() {
    let v = load("vectors/pairing.json");
    for c in cases(&v, "encode") {
        let p = PairingPayload::new(c["input"]["url"].as_str().unwrap(), c["input"]["pin"].as_str().unwrap());
        let enc = p.encoded_url();
        assert_eq!(enc, c["expect"]["encoded"].as_str().unwrap(), "{}", c["name"]);
        let back = PairingPayload::decode(&enc).unwrap();
        assert_eq!(back.url, c["expect"]["decodedBack"]["url"].as_str().unwrap());
        assert_eq!(back.pin, c["expect"]["decodedBack"]["pin"].as_str().unwrap());
    }
    for c in cases(&v, "decode") {
        let got = PairingPayload::decode(c["input"]["raw"].as_str().unwrap());
        let want = if c["expect"].is_null() {
            None
        } else {
            Some(PairingPayload::new(c["expect"]["url"].as_str().unwrap(), c["expect"]["pin"].as_str().unwrap()))
        };
        assert_eq!(got, want, "{}", c["name"]);
    }
}

// --- vectors/window_color.json ---

fn component(v: &Value) -> f64 {
    match v.as_str() {
        Some("nan") => f64::NAN,
        Some("inf") => f64::INFINITY,
        Some("-inf") => f64::NEG_INFINITY,
        Some(other) => panic!("bad component {other}"),
        None => f(v),
    }
}

fn set(v: &Value) -> HashSet<String> {
    v.as_array().unwrap().iter().map(|x| x.as_str().unwrap().to_string()).collect()
}

#[test]
fn window_color_vectors() {
    let v = load("vectors/window_color.json");
    let pal: Vec<&str> =
        cases(&v, "palette")[0]["expect"].as_array().unwrap().iter().map(|x| x.as_str().unwrap()).collect();
    assert_eq!(pal, window_color::PALETTE);
    for c in cases(&v, "normalized") {
        assert_eq!(
            window_color::normalized(c["input"]["raw"].as_str().unwrap()).as_deref(),
            c["expect"].as_str(),
            "{}",
            c["name"]
        );
    }
    for c in cases(&v, "hex") {
        let i = &c["input"];
        assert_eq!(
            window_color::hex(component(&i["red"]), component(&i["green"]), component(&i["blue"])),
            c["expect"].as_str().unwrap(),
            "{}",
            c["name"]
        );
    }
    for c in cases(&v, "first_unused") {
        assert_eq!(window_color::first_unused(&set(&c["input"]["avoiding"])), c["expect"].as_str(), "{}", c["name"]);
    }
    for c in cases(&v, "colors_to_avoid") {
        let mut got: Vec<String> =
            window_color::colors_to_avoid(&set(&c["input"]["all"]), &set(&c["input"]["shown"])).into_iter().collect();
        got.sort();
        let want: Vec<String> =
            c["expect"].as_array().unwrap().iter().map(|x| x.as_str().unwrap().to_string()).collect();
        assert_eq!(got, want, "{}", c["name"]);
    }
}

// --- vectors/injection_log.json ---

fn kind(v: &Value) -> InjectionKind {
    match v.as_str() {
        None => InjectionKind::Unclassified,
        Some("sessionNotFound") => InjectionKind::SessionNotFound,
        Some("tccDenied") => InjectionKind::TccDenied,
        Some("windowClosed") => InjectionKind::WindowClosed,
        Some("unknown") => InjectionKind::Unknown,
        Some(other) => panic!("bad kind {other}"),
    }
}

#[test]
fn injection_log_vectors() {
    let v = load("vectors/injection_log.json");
    for c in cases(&v, "cases") {
        let i = &c["input"];
        let (op, win, msg, detail) = (
            i["op"].as_str().unwrap(),
            i["window"].as_str().unwrap(),
            i["message"].as_str().unwrap(),
            i["detail"].as_str().unwrap(),
        );
        let app = i["app"].as_str();
        let got = if i["redact"].as_bool().unwrap() {
            let full = injection_log::redacted_file_line(0.0, op, win, app, kind(&i["kind"]), msg, detail);
            full.trim_end_matches('\n').split_once(' ').unwrap().1.to_string()
        } else {
            injection_log::line(op, win, app, kind(&i["kind"]), msg, detail)
        };
        assert_eq!(got, c["expect"].as_str().unwrap(), "{}", c["name"]);
    }
}
