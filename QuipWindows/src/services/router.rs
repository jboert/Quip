//! Phone message -> backend call (spec 3.3). Auth and heartbeat acks are
//! connection-level and handled in `ws_server`; everything else lands here.
//!
//! Error strings follow the Mac where it has one (`QuipMacApp.swift`
//! handlers): "Window no longer exists", "Could not minimize …", "No enabled
//! windows to arrange". Errors and acks go to every phone, as on the Mac;
//! `preferences_restore` goes only to the phone that asked (US-014).

use std::time::Duration;

use crate::host::{ClientId, Host};
use crate::platform::traits::{FocusStep, Platform, PlatformError, WindowRef};
use crate::protocol::messages::{
    ArrangeWindows, CloseWindow, ErrorMessage, Incoming, MinimizeWindow, PreferenceRequest, PreferenceRestore,
    PreferenceSnapshot, QuickAction, RequestContent, SelectWindow, SendText, SendTextAck, SetColor, SetPin,
    TerminalContent,
};
use crate::protocol::types::WireUuid;
use crate::services::arrange::{self, TargetResult};
use crate::services::injection_log::{self, InjectionKind};
use crate::services::injector::{self, Report, Step};
use crate::services::keys::{self, QuickActionPlan};
use crate::services::layout::ArrangeOutcome;
use crate::services::multiline_policy::{self, Shell, WindowsSend};
use crate::services::quip_log::Severity;

pub const WINDOW_GONE: &str = "Window no longer exists";
pub const FOCUS_REFUSED: &str = "Windows refused to focus the window";
/// The input lane is gone (a panic in a backend call). Not "refused": nothing
/// reached Windows at all, and it will not recover until a restart.
pub const INPUT_STOPPED: &str = "Windows host input thread stopped";
pub const INPUT_BLOCKED_DETAIL: &str = "input blocked (elevated window?)";

/// What a failed input plan tells the phone and `injection.log`.
pub struct FailureReport {
    pub kind: InjectionKind,
    pub reason: String,
    pub detail: String,
}

/// Spec 5.4 steps 1-4, failure side. Pure, so each branch is tested.
pub fn describe_failure(e: &PlatformError, prefix: &str) -> FailureReport {
    match e {
        PlatformError::WindowGone => {
            FailureReport { kind: InjectionKind::WindowClosed, reason: WINDOW_GONE.into(), detail: String::new() }
        }
        PlatformError::FocusRefused => {
            FailureReport { kind: InjectionKind::Unknown, reason: FOCUS_REFUSED.into(), detail: "focus refused".into() }
        }
        PlatformError::FocusLost { after_chars } => FailureReport {
            kind: InjectionKind::Unknown,
            reason: format!("Focus moved to another window after {after_chars} characters; the rest was not typed"),
            detail: format!("focus lost after {after_chars} chars"),
        },
        PlatformError::InputBlocked { after_chars } => FailureReport {
            kind: InjectionKind::Unknown,
            reason: format!(
                "Windows blocked the typing after {after_chars} characters; is the window running as administrator?"
            ),
            detail: INPUT_BLOCKED_DETAIL.into(),
        },
        other => {
            FailureReport { kind: InjectionKind::Unknown, reason: format!("{prefix}: {other}"), detail: String::new() }
        }
    }
}

fn ms(d: Duration) -> i64 {
    i64::try_from(d.as_millis()).unwrap_or(i64::MAX)
}

/// What one `send_text` did on the input lane.
pub enum SendOutcome {
    /// The shell (read at send time) refused multi-line text; nothing typed.
    Refused {
        shell: Shell,
    },
    /// The window is gone (or its handle belongs to another process now).
    Gone,
    Ran {
        shell: Shell,
        decision: WindowsSend,
        report: Report,
    },
}

/// Spec 5.4, the whole input-lane half: re-read the shell NOW (the poll's
/// answer can be a second old, and the user may just have started `python`),
/// apply the multi-line rule to it, then run the plan. Pure over `Platform`.
pub fn send_text_on_lane(p: &dyn Platform, window: WindowRef, text: &str, press_return: bool) -> SendOutcome {
    let shell = match p.current_shell(window) {
        Ok(Some(s)) => s,
        // A non-terminal: multi-line refused (Enter would submit a chat box).
        Ok(None) => Shell::Unknown,
        Err(PlatformError::WindowGone) => return SendOutcome::Gone,
        // Could not tell: treat like cmd, never guess "safe".
        Err(_) => Shell::Unknown,
    };
    let decision = multiline_policy::windows_decide(text, shell, press_return);
    match injector::send_text_steps(&decision) {
        None => SendOutcome::Refused { shell },
        Some(steps) => SendOutcome::Ran { shell, report: injector::execute(p, window, &steps), decision },
    }
}

fn steps_count(steps: &[Step]) -> usize {
    steps.iter().filter(|s| matches!(s, Step::Type(_) | Step::Key(_))).count()
}

impl Host {
    /// Route one authenticated phone message. `received` is the host clock
    /// at arrival (`tRecv` on the Mac), for `totalMs`.
    pub async fn route(&self, client: ClientId, msg: Incoming, received: Duration) {
        match msg {
            Incoming::Auth(_) | Incoming::HeartbeatAck(_) => {}
            Incoming::SelectWindow(m) => self.select_window(m).await,
            Incoming::SendText(m) => self.send_text(m, received).await,
            Incoming::QuickAction(m) => self.quick_action(m, received).await,
            Incoming::ArrangeWindows(m) => self.arrange(m).await,
            Incoming::MinimizeWindow(m) => self.minimize(m).await,
            Incoming::CloseWindow(m) => self.close(m).await,
            Incoming::PhoneLog(m) => self.logs.phone(&m.lines),
            Incoming::PreferencesSnapshot(m) => self.store_prefs(m).await,
            Incoming::PreferencesRequest(m) => self.restore_prefs(client, m).await,
            Incoming::RequestContent(m) => self.request_content(client, m),
            Incoming::SetPin(m) => self.set_pin_from_phone(m),
            Incoming::SetColor(m) => self.set_color_from_phone(m),
        }
    }

    fn error(&self, reason: impl Into<String>, message_id: Option<WireUuid>) {
        self.broadcast(&ErrorMessage::new(reason, message_id));
    }

    fn deduped(&self, kind: &str, id: Option<WireUuid>) -> bool {
        let dup = self.dedupe.check_and_record(id);
        if dup {
            let rid = id.map(|i| i.short()).unwrap_or_default();
            self.logs.debug(&format!("{kind} DEDUPED messageId={rid}"));
        }
        dup
    }

    fn rid(id: Option<WireUuid>) -> String {
        id.map(|i| i.short()).unwrap_or_else(|| "nil".into())
    }

    /// The Mac's `select_window` answers nothing, ever (`QuipMacApp.swift`
    /// `case "select_window"`): an id it does not know just leaves the
    /// selection unchanged. A focus failure is still an `error` (spec 3.2).
    async fn select_window(&self, m: SelectWindow) {
        let Some(window) = self.state().find(&m.window_id).map(|w| w.platform.window_ref()) else {
            self.logs.debug(&format!("select_window {}: not in the broadcast set, ignored", m.window_id));
            return;
        };
        let r = self.lanes.input(move |p| p.bring_to_foreground(window)).await;
        match r {
            Ok(Ok(_)) => {}
            Ok(Err(PlatformError::WindowGone)) => self.error(WINDOW_GONE, None),
            Ok(Err(e)) => {
                self.logs.ws(Severity::Warn, &format!("select_window {}: {e}", m.window_id));
                self.error(FOCUS_REFUSED, None);
            }
            Err(_) => self.error(INPUT_STOPPED, None),
        }
        self.poll_tick().await;
    }

    async fn send_text(&self, m: SendText, received: Duration) {
        if self.deduped("send_text", m.message_id) {
            return;
        }
        let found = self.state().find(&m.window_id).cloned();
        let Some(window) = found else {
            self.logs.injection("sendText", &m.window_id, None, InjectionKind::WindowClosed, WINDOW_GONE, "");
            self.error(WINDOW_GONE, m.message_id);
            return;
        };
        let app = window.platform.app.clone();
        let target = window.platform.window_ref();
        let (text, press_return) = (m.text.clone(), m.press_return);
        let outcome = self.lanes.input(move |p| send_text_on_lane(p, target, &text, press_return)).await;
        let (shell, decision, report) = match outcome {
            Err(_) => {
                self.logs.injection("sendText", &window.id, Some(&app), InjectionKind::Unknown, INPUT_STOPPED, "");
                self.error(INPUT_STOPPED, m.message_id);
                return;
            }
            Ok(SendOutcome::Gone) => {
                self.logs.injection("sendText", &window.id, Some(&app), InjectionKind::WindowClosed, WINDOW_GONE, "");
                self.error(WINDOW_GONE, m.message_id);
                return;
            }
            Ok(SendOutcome::Refused { shell }) => {
                self.logs.injection(
                    "sendText",
                    &window.id,
                    Some(&app),
                    InjectionKind::Unknown,
                    "multi-line text refused",
                    multiline_policy::REFUSE_DETAIL,
                );
                self.error(
                    format!(
                        "Multi-line text can't be sent safely to {app} ({}); send one line at a time",
                        shell.as_str()
                    ),
                    m.message_id,
                );
                return;
            }
            Ok(SendOutcome::Ran { shell, decision, report }) => (shell, decision, report),
        };
        let segments = match &decision {
            WindowsSend::Type { segments, .. } => segments.len(),
            WindowsSend::Refuse => 0,
        };
        let decided_return = multiline_policy::decided_return(&decision);
        let suffix = multiline_policy::latency_suffix(m.press_return, decided_return, &m.text);
        let total = self.clock.monotonic().saturating_sub(received);
        let (inject_ms, total_ms) = (ms(report.elapsed), ms(total.max(report.elapsed)));
        // Counts and ids only; the text itself is never logged.
        self.logs.latency(&format!(
            "send_text rid={} path=sendText cli=shell term={} shell={} success={} text_len={} segments={segments} press_return={} inject_ms={inject_ms} total_ms={total_ms} focus={}{suffix}",
            Self::rid(m.message_id),
            injection_log::token(&app),
            shell.as_str(),
            u8::from(report.ok()),
            m.text.chars().count(),
            u8::from(m.press_return),
            report.focus.map(FocusStep::as_str).unwrap_or("-"),
        ));
        match &report.error {
            None => {
                if let Some(id) = m.message_id {
                    self.broadcast(&SendTextAck::new(id, inject_ms, total_ms));
                }
            }
            Some(e) => {
                let f = describe_failure(e, "Text send failed");
                self.logs.injection("sendText", &window.id, Some(&app), f.kind, &e.to_string(), &f.detail);
                self.error(f.reason, m.message_id);
            }
        }
    }

    async fn quick_action(&self, m: QuickAction, received: Duration) {
        if self.deduped("quick_action", m.message_id) {
            return;
        }
        // `action` comes from the phone: a token (no spaces or breaks) in
        // every log field that carries it.
        let action = injection_log::token(&m.action);
        let found = self.state().find(&m.window_id).cloned();
        let Some(window) = found else {
            self.logs.injection(
                "quickAction",
                &m.window_id,
                None,
                InjectionKind::WindowClosed,
                WINDOW_GONE,
                &format!("action={action}"),
            );
            self.error(WINDOW_GONE, m.message_id);
            return;
        };
        let steps = match keys::plan(&m.action) {
            QuickActionPlan::ToggleEnabled => {
                let toggled = self.state().toggle_enabled(&window.id);
                if let Some((key, enabled)) = toggled {
                    self.with_settings(|s| s.set_enabled_override(key, enabled));
                }
                self.publish();
                return;
            }
            QuickActionPlan::Unsupported => {
                self.logs.ws(Severity::Info, &format!("quick_action {action} not supported on Windows"));
                self.error(keys::UNSUPPORTED_REASON, m.message_id);
                return;
            }
            QuickActionPlan::Keys(chords) => {
                std::iter::once(Step::Focus).chain(chords.into_iter().map(Step::Key)).collect::<Vec<_>>()
            }
            QuickActionPlan::Type(t) => vec![Step::Focus, Step::Type(t)],
            QuickActionPlan::TypeThenReturn(t) => {
                vec![Step::Focus, Step::Type(t), Step::Pause(injector::RETURN_PAUSE), Step::Key(keys::KeyChord::RETURN)]
            }
        };
        let inputs = steps_count(&steps);
        let target = window.platform.window_ref();
        let report = self.lanes.input(move |p| injector::execute(p, target, &steps)).await;
        let Ok(report) = report else {
            self.logs.injection(
                "quickAction",
                &window.id,
                Some(&window.platform.app),
                InjectionKind::Unknown,
                INPUT_STOPPED,
                &format!("action={action}"),
            );
            self.error(INPUT_STOPPED, m.message_id);
            return;
        };
        let total = self.clock.monotonic().saturating_sub(received);
        let (inject_ms, total_ms) = (ms(report.elapsed), ms(total.max(report.elapsed)));
        self.logs.latency(&format!(
            "quick_action rid={} action={action} term={} success={} inputs={inputs} inject_ms={inject_ms} total_ms={total_ms} focus={}",
            Self::rid(m.message_id),
            injection_log::token(&window.platform.app),
            u8::from(report.ok()),
            report.focus.map(FocusStep::as_str).unwrap_or("-"),
        ));
        if let Some(e) = &report.error {
            let f = describe_failure(e, "Key send failed");
            let detail =
                if f.detail.is_empty() { format!("action={action}") } else { format!("{} action={action}", f.detail) };
            self.logs.injection("quickAction", &window.id, Some(&window.platform.app), f.kind, &e.to_string(), &detail);
            self.error(f.reason, m.message_id);
        }
    }

    /// Spec 5.2: restore, measure, move, verify, retry (`arrange::execute`)
    /// on the input lane. A refused or gone window counts against the
    /// outcome and gets an `injection.log` line; one held off its target
    /// (an app's minimum size) gets a `websocket.log` line and is not
    /// counted.
    async fn arrange(&self, m: ArrangeWindows) {
        let plan = self.state().arrange_plan(m.layout);
        let plan = match plan {
            Ok(p) => p,
            Err(outcome) => {
                if let Some(msg) = outcome.message() {
                    self.error(msg, None);
                }
                return;
            }
        };
        let targets = plan.clone();
        let Ok(results) = self.lanes.input(move |p| arrange::execute(p, &targets, arrange::SETTLE)).await else {
            self.logs.ws(Severity::Error, &format!("arrange_windows: {INPUT_STOPPED}"));
            self.error(INPUT_STOPPED, None);
            return;
        };
        let mut refused = 0;
        for (i, t) in plan.iter().enumerate() {
            let (msg, detail, kind) = match results.get(i) {
                Some(TargetResult::Moved) => continue,
                Some(TargetResult::OffTarget { got }) => {
                    self.logs.ws(
                        Severity::Info,
                        &format!(
                            "arrange: {} ended at {}x{}, wanted {}x{} (minimum size?)",
                            t.id, got.width, got.height, t.visible.width, t.visible.height
                        ),
                    );
                    continue;
                }
                Some(TargetResult::Refused(why)) => (format!("refused: {why}"), why.clone(), InjectionKind::Unknown),
                // A stale id (self-heals on the next poll) greps apart from
                // a refusal (CLAUDE.md, injection.log `kind`).
                Some(TargetResult::Gone) => {
                    (PlatformError::WindowGone.to_string(), "window is gone".to_string(), InjectionKind::WindowClosed)
                }
                None => ("no result from the platform".to_string(), "no result".to_string(), InjectionKind::Unknown),
            };
            refused += 1;
            let app = self.state().find_tracked(&t.id).map(|w| w.platform.app.clone());
            self.logs.injection("arrange", &t.id, app.as_deref(), kind, &msg, &detail);
        }
        let outcome = ArrangeOutcome::evaluate(plan.len(), true, || refused);
        if let Some(msg) = outcome.message() {
            self.error(msg, None);
        }
        self.poll_tick().await;
    }

    async fn minimize(&self, m: MinimizeWindow) {
        if self.deduped("minimize_window", m.message_id) {
            return;
        }
        let found = self.state().find(&m.window_id).map(|w| (w.platform.window_ref(), w.platform.app.clone()));
        let Some((window, app)) = found else {
            self.error(WINDOW_GONE, m.message_id);
            return;
        };
        match self.lanes.input(move |p| p.minimize(window)).await {
            Ok(Ok(())) => self.poll_tick().await,
            Ok(Err(PlatformError::WindowGone)) => self.error(WINDOW_GONE, m.message_id),
            Ok(Err(e)) => {
                self.logs.ws(Severity::Warn, &format!("minimize_window {} ({app}): {e}", m.window_id));
                self.error(format!("Could not minimize {app} — {e} (see websocket.log)"), m.message_id);
            }
            Err(_) => self.error(INPUT_STOPPED, m.message_id),
        }
    }

    async fn close(&self, m: CloseWindow) {
        if self.deduped("close_window", m.message_id) {
            return;
        }
        let Some(window) = self.state().find(&m.window_id).map(|w| w.platform.window_ref()) else {
            // The Mac's close_window error carries no messageId.
            self.error(WINDOW_GONE, None);
            return;
        };
        match self.lanes.input(move |p| p.close(window)).await {
            Ok(Ok(())) => self.poll_tick().await,
            Ok(Err(PlatformError::WindowGone)) => self.error(WINDOW_GONE, None),
            Ok(Err(e)) => {
                self.logs.ws(Severity::Warn, &format!("close_window {}: {e}", m.window_id));
                self.error(format!("Could not close the window — {e}"), None);
            }
            Err(_) => self.error(INPUT_STOPPED, None),
        }
    }

    /// The phone asks every 2 s for the selected window's text. Phase 1
    /// cannot read a console, so a window the phone is shown gets a fixed
    /// "not available" `terminal_content`, to the asker only; without any
    /// answer the phone says "No reply from the Mac … It may have closed".
    /// An id it is not shown gets nothing, which is what that text means.
    fn request_content(&self, client: ClientId, m: RequestContent) {
        if self.state().find(&m.window_id).is_some() {
            self.send(client, &TerminalContent::not_available(m.window_id));
        } else {
            self.logs.debug(&format!("request_content {}: not in the broadcast set", m.window_id));
        }
    }

    /// `case "set_pin"` on the Mac: the host owns the pin set, so the phone
    /// asks and the next `layout_update` carries the order it produced. The
    /// Mac answers nothing, ever: an id the phone is not shown is ignored.
    fn set_pin_from_phone(&self, m: SetPin) {
        if self.state().find(&m.window_id).is_none() {
            self.logs.debug(&format!("set_pin {}: not in the broadcast set, ignored", m.window_id));
            return;
        }
        let change = self.state().set_pinned(&m.window_id, m.pinned);
        if let Some(c) = change {
            self.with_settings(|s| s.set_pinned(c.key, c.pinned));
        }
        self.publish();
    }

    /// `case "set_color"` on the Mac (`WindowManager.setColor`): a color
    /// that is not `#RRGGBB` is ignored; absent or null clears the choice.
    fn set_color_from_phone(&self, m: SetColor) {
        if self.state().find(&m.window_id).is_none() {
            self.logs.debug(&format!("set_color {}: not in the broadcast set, ignored", m.window_id));
            return;
        }
        if m.color.as_deref().is_some_and(|c| crate::services::window_color::normalized(c).is_none()) {
            self.logs.debug(&format!("set_color {}: not a #RRGGBB color, ignored", m.window_id));
            return;
        }
        let change = self.state().set_color(&m.window_id, m.color.as_deref());
        if let Some(c) = change {
            self.with_settings(|s| s.set_color_override(c.key, c.color));
        }
        self.publish();
    }

    async fn store_prefs(&self, m: PreferenceSnapshot) {
        let short: String = m.device_id.chars().take(8).collect();
        let keys: Vec<String> = m.preferences.keys().cloned().collect();
        let prefs = self.prefs.clone();
        let (device, body) = (m.device_id.clone(), m.preferences);
        let r = tokio::task::spawn_blocking(move || prefs.store(&device, body)).await;
        match r {
            Ok(Ok(stored)) => {
                if let Some(bad) = &stored.quarantined {
                    self.logs.ws(
                        Severity::Error,
                        &format!("phone-prefs.json was corrupt; moved to {} and started a new one", bad.display()),
                    );
                }
                if stored.stored {
                    self.logs.ws(Severity::Info, &format!("preferences_snapshot stored for device {short}"));
                } else {
                    // Fake mode: key names only, never values (fake-mac rule).
                    self.logs.ws(
                        Severity::Info,
                        &format!("preferences_snapshot dropped (no backup mode) keys={}", keys.join(",")),
                    );
                }
            }
            Ok(Err(e)) => self.logs.ws(
                Severity::Error,
                &format!("preferences_snapshot NOT stored for device {short} — {e}. This phone's settings are not backed up."),
            ),
            Err(e) => self.logs.ws(Severity::Error, &format!("preferences_snapshot NOT stored for device {short} — {e}")),
        }
    }

    async fn restore_prefs(&self, client: ClientId, m: PreferenceRequest) {
        let prefs = self.prefs.clone();
        let device = m.device_id.clone();
        let restored = tokio::task::spawn_blocking(move || prefs.restore(&device)).await;
        let value = match restored {
            Ok(r) => {
                if let Some(bad) = &r.quarantined {
                    self.logs.ws(Severity::Error, &format!("phone-prefs.json was corrupt; moved to {}", bad.display()));
                }
                if let Some(e) = &r.read_error {
                    self.logs.ws(Severity::Error, &format!("phone-prefs.json could not be read: {e}"));
                }
                r.prefs
            }
            Err(_) => serde_json::Value::Object(serde_json::Map::new()),
        };
        self.send(client, &PreferenceRestore::new(Some(m.device_id), value));
    }
}

#[cfg(test)]
mod tests {
    //! `SendTextSelfHealTests` shape: each failure kind -> the right log kind
    //! and phone reason. The routing itself is covered end to end, against
    //! the fake platform, in `tests/router.rs` and `tests/ws_integration.rs`.
    use super::*;

    #[test]
    fn gone_window_is_window_closed() {
        let f = describe_failure(&PlatformError::WindowGone, "x");
        assert_eq!(f.kind, InjectionKind::WindowClosed);
        assert_eq!(f.reason, WINDOW_GONE);
        assert!(f.detail.is_empty());
    }

    #[test]
    fn focus_refused_is_unknown_with_detail() {
        let f = describe_failure(&PlatformError::FocusRefused, "x");
        assert_eq!(f.kind, InjectionKind::Unknown);
        assert_eq!(f.reason, FOCUS_REFUSED);
        assert_eq!(f.detail, "focus refused");
    }

    #[test]
    fn focus_lost_carries_the_count() {
        let f = describe_failure(&PlatformError::FocusLost { after_chars: 12 }, "x");
        assert_eq!(f.kind, InjectionKind::Unknown);
        assert_eq!(f.detail, "focus lost after 12 chars");
        assert!(f.reason.contains("12"));
    }

    #[test]
    fn input_blocked_is_unknown_with_the_elevated_detail() {
        let f = describe_failure(&PlatformError::InputBlocked { after_chars: 3 }, "x");
        assert_eq!(f.kind, InjectionKind::Unknown);
        assert_eq!(f.detail, "input blocked (elevated window?)");
        assert!(f.reason.contains('3') && f.reason.contains("administrator"), "{}", f.reason);
    }

    fn fake_with(shells: &[&str]) -> (crate::platform::fake::FakePlatform, WindowRef) {
        use crate::platform::fake::{window_from_fixture, FakePlatform, FixtureRect, FixtureWindow};
        let w = window_from_fixture(&FixtureWindow {
            handle: 5,
            pid: 50,
            title: "t".into(),
            class_name: "ConsoleWindowClass".into(),
            exe_path: None,
            product_name: None,
            shells: vec!["pwsh.exe".into()],
            visible: FixtureRect { x: 0, y: 0, width: 10, height: 10 },
            border: 0,
            is_minimized: false,
        });
        let r = w.window_ref();
        let f = FakePlatform::new(vec![w], vec![]);
        f.set_foreground(Some(5));
        f.set_running(5, shells);
        (f, r)
    }

    #[test]
    fn the_shell_is_read_at_send_time_and_a_program_in_it_refuses_multi_line() {
        let (f, r) = fake_with(&["pwsh.exe", "python.exe"]);
        assert!(matches!(
            send_text_on_lane(
                &f, r, "a
b", true
            ),
            SendOutcome::Refused { shell: Shell::Unknown }
        ));
        assert!(f.typed(5).is_empty());
        // Single-line text is still fine: the multi-line rule is the only
        // thing the shell decides.
        assert!(matches!(send_text_on_lane(&f, r, "x", false), SendOutcome::Ran { shell: Shell::Unknown, .. }));
        f.set_running(5, &["pwsh.exe"]);
        let SendOutcome::Ran { shell, report, .. } = send_text_on_lane(
            &f, r, "a
b", true,
        ) else {
            panic!()
        };
        assert_eq!(shell, Shell::Pwsh);
        assert!(report.ok());
    }

    #[test]
    fn a_reused_handle_is_gone_before_anything_is_typed() {
        let (f, r) = fake_with(&["pwsh.exe"]);
        f.reuse_handle(5, 999, "other app");
        assert!(matches!(send_text_on_lane(&f, r, "x", true), SendOutcome::Gone));
        assert!(f.typed(5).is_empty() && f.calls().is_empty());
    }

    #[test]
    fn anything_else_is_prefixed() {
        let f = describe_failure(&PlatformError::Failed("boom".into()), "Text send failed");
        assert_eq!(f.reason, "Text send failed: boom");
        assert_eq!(f.kind, InjectionKind::Unknown);
    }
}
