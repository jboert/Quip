//! Runs an input plan against a backend, on the input lane (blocking is fine
//! there). The plans come from `multiline_policy::windows_decide` and
//! `keys::plan`; the order of steps is the safety rule: focus first, never
//! type if focus failed (spec 5.3), stop at the first failure, and nothing
//! after it reaches any window.
//!
//! The checks are HERE, not in the backend, so the Win32 code cannot get them
//! wrong (`SendInput` types into whatever window is in front):
//! - before every typing batch and before every key (including the Return
//!   after the pause) the injector asks `foreground_window` and stops with
//!   `FocusLost` unless it is the target, handle AND pid;
//! - a batch or chord that Windows only partly inserted stops typing with
//!   `InputBlocked`.

use std::time::{Duration, Instant};

use super::keys::KeyChord;
use super::multiline_policy::WindowsSend;
use super::typing_plan::{self, Outcome};
use crate::platform::traits::{FocusStep, Platform, PlatformError, WindowRef};

/// Spec 5.4 step 6: the pause before Return.
pub const RETURN_PAUSE: Duration = Duration::from_millis(30);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Step {
    Focus,
    Type(String),
    Key(KeyChord),
    Pause(Duration),
}

/// `send_text` plan for an allowed `WindowsSend::Type`; `None` for `Refuse`.
pub fn send_text_steps(send: &WindowsSend) -> Option<Vec<Step>> {
    let WindowsSend::Type { segments, press_return } = send else { return None };
    let mut steps = vec![Step::Focus];
    for (i, seg) in segments.iter().enumerate() {
        if i > 0 {
            steps.push(Step::Key(KeyChord::SHIFT_ENTER));
        }
        if !seg.is_empty() {
            steps.push(Step::Type(seg.clone()));
        }
    }
    if *press_return {
        steps.push(Step::Pause(RETURN_PAUSE));
        steps.push(Step::Key(KeyChord::RETURN));
    }
    Some(steps)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    pub focus: Option<FocusStep>,
    /// Characters of text that landed (across segments).
    pub typed_chars: usize,
    pub error: Option<PlatformError>,
    pub elapsed: Duration,
}

impl Report {
    pub fn ok(&self) -> bool {
        self.error.is_none()
    }
}

/// True only when `window` (handle and pid) is the foreground window. A
/// failing query counts as "not in front": never type blind.
fn in_front(p: &dyn Platform, window: WindowRef) -> bool {
    matches!(p.foreground_window(), Ok(Some(f)) if f == window)
}

fn type_text(p: &dyn Platform, window: WindowRef, text: &str, before: usize) -> Result<usize, PlatformError> {
    let mut failure: Option<PlatformError> = None;
    let outcome = typing_plan::run(
        text,
        || in_front(p, window),
        |units| match p.send_units(window, units) {
            Ok(n) => n,
            Err(e) => {
                failure = Some(e);
                0
            }
        },
    );
    match (outcome, failure) {
        (Outcome::Done(n), _) => Ok(n),
        (Outcome::FocusLost(n), _) => Err(PlatformError::FocusLost { after_chars: before + n }),
        // The backend refused outright (window gone, its own focus check).
        (Outcome::Blocked(n), Some(e)) => Err(match e {
            PlatformError::FocusLost { .. } => PlatformError::FocusLost { after_chars: before + n },
            PlatformError::InputBlocked { .. } => PlatformError::InputBlocked { after_chars: before + n },
            other => other,
        }),
        (Outcome::Blocked(n), None) => Err(PlatformError::InputBlocked { after_chars: before + n }),
    }
}

fn press(p: &dyn Platform, window: WindowRef, chord: KeyChord, typed: usize) -> Result<(), PlatformError> {
    if !in_front(p, window) {
        return Err(PlatformError::FocusLost { after_chars: typed });
    }
    match p.press_key(window, chord) {
        Ok(n) if n >= chord.input_count() => Ok(()),
        Ok(_) | Err(PlatformError::InputBlocked { .. }) => Err(PlatformError::InputBlocked { after_chars: typed }),
        Err(PlatformError::FocusLost { .. }) => Err(PlatformError::FocusLost { after_chars: typed }),
        Err(e) => Err(e),
    }
}

pub fn execute(p: &dyn Platform, window: WindowRef, steps: &[Step]) -> Report {
    let start = Instant::now();
    let mut report = Report { focus: None, typed_chars: 0, error: None, elapsed: Duration::ZERO };
    for step in steps {
        let r = match step {
            Step::Focus => p.bring_to_foreground(window).map(|s| report.focus = Some(s)),
            Step::Type(t) => type_text(p, window, t, report.typed_chars).map(|n| report.typed_chars += n),
            Step::Key(k) => press(p, window, *k, report.typed_chars),
            Step::Pause(d) => {
                std::thread::sleep(*d);
                Ok(())
            }
        };
        if let Err(e) = r {
            report.error = Some(e);
            break;
        }
    }
    report.elapsed = start.elapsed();
    report
}

#[cfg(test)]
mod tests {
    //! Every focus / short-insert case runs with the fake's own input guard
    //! OFF (`set_input_guard(false)`): the fake then types into whatever is
    //! in front, like `SendInput`, so these pass only because the injector
    //! checks.
    use super::*;
    use crate::platform::fake::{FakeCall, FakePlatform, Typed};
    use crate::platform::traits::PlatformWindow;
    use crate::services::classify::TerminalHost;
    use crate::services::keys::Key;
    use crate::services::layout::PixelRect;
    use crate::services::multiline_policy::{windows_decide, Shell};

    const W1: WindowRef = WindowRef { handle: 1, pid: 1 };
    const W2: WindowRef = WindowRef { handle: 2, pid: 2 };

    fn fake() -> FakePlatform {
        let w = |h: u64| PlatformWindow {
            handle: h,
            pid: h as u32,
            title: "t".into(),
            class_name: "c".into(),
            exe_path: None,
            app: "PowerShell".into(),
            terminal: Some(TerminalHost::Console),
            shell: Some(Shell::PowerShell),
            visible: PixelRect::default(),
            outer: PixelRect::default(),
            is_minimized: false,
            is_maximized: false,
        };
        let f = FakePlatform::new(vec![w(1), w(2)], vec![]);
        f.set_input_guard(false);
        f
    }

    fn steps(text: &str, shell: Shell, ret: bool) -> Vec<Step> {
        send_text_steps(&windows_decide(text, shell, ret)).unwrap()
    }

    #[test]
    fn single_line_with_return() {
        let st = steps("Get-Date", Shell::PowerShell, true);
        assert_eq!(
            st,
            vec![Step::Focus, Step::Type("Get-Date".into()), Step::Pause(RETURN_PAUSE), Step::Key(KeyChord::RETURN)]
        );
        let f = fake();
        let r = execute(&f, W1, &st);
        assert!(r.ok());
        assert_eq!(r.typed_chars, 8);
        assert_eq!(f.typed(1), vec![Typed::Text("Get-Date".into()), Typed::Key(KeyChord::RETURN)]);
    }

    #[test]
    fn multi_line_uses_shift_enter_and_no_return() {
        assert_eq!(
            steps("a\n\nb\n", Shell::Pwsh, true),
            vec![
                Step::Focus,
                Step::Type("a".into()),
                Step::Key(KeyChord::SHIFT_ENTER),
                Step::Key(KeyChord::SHIFT_ENTER),
                Step::Type("b".into())
            ]
        );
    }

    #[test]
    fn refuse_has_no_steps() {
        assert_eq!(send_text_steps(&windows_decide("a\nb", Shell::Cmd, true)), None);
    }

    #[test]
    fn focus_refused_types_nothing() {
        let f = fake();
        f.set_refuse_focus(1, true);
        let r = execute(&f, W1, &steps("x", Shell::PowerShell, true));
        assert_eq!(r.error, Some(PlatformError::FocusRefused));
        assert!(f.typed(1).is_empty() && f.typed(2).is_empty());
        assert!(!f.calls().iter().any(|c| matches!(c, FakeCall::TypeText { .. } | FakeCall::Key { .. })));
    }

    #[test]
    fn focus_lost_between_batches_counts_across_segments_and_stops() {
        let f = fake();
        let text = format!("ab\n{}", "y".repeat(40));
        // Inputs: "ab", Shift+Enter; then focus moves before the "y" batch.
        f.set_steal_focus(2, 2);
        let r = execute(&f, W1, &steps(&text, Shell::Pwsh, false));
        assert_eq!(r.error, Some(PlatformError::FocusLost { after_chars: 2 }));
        assert!(f.typed(2).is_empty(), "nothing reached the window that took focus");
    }

    #[test]
    fn focus_lost_inside_one_long_segment() {
        let f = fake();
        f.set_steal_focus(1, 2);
        let r = execute(&f, W1, &steps(&"z".repeat(100), Shell::Pwsh, true));
        assert_eq!(r.error, Some(PlatformError::FocusLost { after_chars: 32 }));
        assert_eq!(f.typed(1), vec![Typed::Text("z".repeat(32))]);
        assert!(f.typed(2).is_empty());
    }

    #[test]
    fn focus_is_checked_again_before_the_return_after_the_pause() {
        let f = fake();
        f.set_steal_focus(1, 2); // the user clicks away during the 30 ms pause
        let r = execute(&f, W1, &steps("Get-Date", Shell::PowerShell, true));
        assert_eq!(r.error, Some(PlatformError::FocusLost { after_chars: 8 }));
        assert!(f.typed(2).is_empty(), "the Return never ran in the other window");
        assert_eq!(f.typed(1), vec![Typed::Text("Get-Date".into())]);
    }

    #[test]
    fn focus_is_checked_before_every_key() {
        let f = fake();
        f.set_steal_focus(1, 2);
        let keys = [Step::Focus, Step::Key(KeyChord::ctrl(Key::Letter('c'))), Step::Key(KeyChord::RETURN)];
        let r = execute(&f, W1, &keys);
        assert_eq!(r.error, Some(PlatformError::FocusLost { after_chars: 0 }));
        assert!(f.typed(2).is_empty());
        assert_eq!(f.typed(1), vec![Typed::Key(KeyChord::ctrl(Key::Letter('c')))]);
    }

    #[test]
    fn the_target_must_match_by_pid_too() {
        let f = fake();
        // Window 1 is in front, but the injector was told pid 9 owns it.
        let r = execute(&f, WindowRef { handle: 1, pid: 9 }, &[Step::Type("x".into())]);
        assert_eq!(r.error, Some(PlatformError::FocusLost { after_chars: 0 }));
        assert!(f.typed(1).is_empty());
    }

    #[test]
    fn a_short_insert_stops_typing_and_never_presses_return() {
        let f = fake();
        f.set_input_limit(Some(5));
        let r = execute(&f, W1, &steps(&"q".repeat(20), Shell::PowerShell, true));
        assert_eq!(r.error, Some(PlatformError::InputBlocked { after_chars: 5 }));
        assert_eq!(f.typed(1), vec![Typed::Text("q".repeat(5))], "no Return after a blocked batch");
    }

    #[test]
    fn fully_blocked_input_types_nothing_and_stops() {
        let f = fake();
        f.set_input_limit(Some(0));
        let r = execute(&f, W1, &[Step::Focus, Step::Type("abc".into()), Step::Type("d".into())]);
        assert_eq!(r.error, Some(PlatformError::InputBlocked { after_chars: 0 }));
        assert!(f.typed(1).is_empty());
    }

    #[test]
    fn a_blocked_chord_is_input_blocked() {
        let f = fake();
        f.set_input_limit(Some(2));
        let r = execute(&f, W1, &[Step::Focus, Step::Type("ab".into()), Step::Key(KeyChord::SHIFT_ENTER)]);
        assert_eq!(r.error, Some(PlatformError::InputBlocked { after_chars: 2 }));
        let r = execute(&f, W1, &[Step::Focus, Step::Key(KeyChord::RETURN)]);
        assert!(r.ok(), "2 events is a whole plain key");
    }

    #[test]
    fn the_backends_own_refusal_keeps_the_count() {
        let f = fake();
        f.set_input_guard(true);
        f.set_steal_focus(1, 2);
        // With the fake's guard on, the injector's check fires first anyway.
        let r = execute(&f, W1, &steps(&"z".repeat(40), Shell::Pwsh, false));
        assert_eq!(r.error, Some(PlatformError::FocusLost { after_chars: 32 }));
    }

    /// A backend that does its own checks and refuses the `fail_on`-th
    /// batch with `err` (a Win32 backend may check foreground too).
    struct Refusing {
        inner: FakePlatform,
        fail_on: usize,
        err: PlatformError,
        batches: std::sync::atomic::AtomicUsize,
    }

    impl crate::platform::traits::WindowBackend for Refusing {
        fn list_windows(&self) -> crate::platform::traits::PlatformResult<Vec<PlatformWindow>> {
            self.inner.list_windows()
        }
        fn list_displays(
            &self,
        ) -> crate::platform::traits::PlatformResult<Vec<crate::platform::traits::PlatformDisplay>> {
            self.inner.list_displays()
        }
        fn foreground_window(&self) -> crate::platform::traits::PlatformResult<Option<WindowRef>> {
            self.inner.foreground_window()
        }
        fn current_shell(&self, w: WindowRef) -> crate::platform::traits::PlatformResult<Option<Shell>> {
            self.inner.current_shell(w)
        }
        fn bring_to_foreground(&self, w: WindowRef) -> crate::platform::traits::PlatformResult<FocusStep> {
            self.inner.bring_to_foreground(w)
        }
        fn restore(&self, w: WindowRef) -> crate::platform::traits::PlatformResult<()> {
            self.inner.restore(w)
        }
        fn rects(&self, w: WindowRef) -> crate::platform::traits::PlatformResult<crate::platform::traits::WindowRects> {
            self.inner.rects(w)
        }
        fn move_windows(
            &self,
            m: &[crate::platform::traits::WindowMove],
        ) -> Vec<crate::platform::traits::PlatformResult<()>> {
            self.inner.move_windows(m)
        }
        fn minimize(&self, w: WindowRef) -> crate::platform::traits::PlatformResult<()> {
            self.inner.minimize(w)
        }
        fn close(&self, w: WindowRef) -> crate::platform::traits::PlatformResult<()> {
            self.inner.close(w)
        }
    }

    impl crate::platform::traits::InputBackend for Refusing {
        fn send_units(&self, w: WindowRef, u: &[u16]) -> crate::platform::traits::PlatformResult<usize> {
            let n = self.batches.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
            if n == self.fail_on {
                return Err(self.err.clone());
            }
            self.inner.send_units(w, u)
        }
        fn press_key(&self, w: WindowRef, k: KeyChord) -> crate::platform::traits::PlatformResult<usize> {
            self.inner.press_key(w, k)
        }
    }

    #[test]
    fn a_backend_refusal_mid_text_keeps_the_count_across_segments() {
        for (err, want) in [
            (PlatformError::FocusLost { after_chars: 0 }, PlatformError::FocusLost { after_chars: 35 }),
            (PlatformError::InputBlocked { after_chars: 0 }, PlatformError::InputBlocked { after_chars: 35 }),
            (PlatformError::WindowGone, PlatformError::WindowGone),
        ] {
            let p = Refusing { inner: fake(), fail_on: 3, err, batches: Default::default() };
            // Batches: "abc" (3), then 32 of the 40 "y"s, then the 3rd fails.
            let text = format!("abc\n{}", "y".repeat(40));
            let r = execute(&p, W1, &steps(&text, Shell::Pwsh, false));
            assert_eq!(r.error, Some(want));
        }
    }

    #[test]
    fn focus_step_is_reported() {
        let f = fake();
        f.set_focus_step(FocusStep::AltFallback);
        let r = execute(&f, W2, &[Step::Focus]);
        assert_eq!(r.focus, Some(FocusStep::AltFallback));
    }

    #[test]
    fn a_gone_or_reused_window_fails_at_focus() {
        let f = fake();
        let r = execute(&f, WindowRef { handle: 99, pid: 1 }, &[Step::Focus, Step::Type("x".into())]);
        assert_eq!(r.error, Some(PlatformError::WindowGone));
        assert_eq!(r.typed_chars, 0);
        f.reuse_handle(1, 500, "new");
        let r = execute(&f, W1, &[Step::Focus, Step::Type("x".into())]);
        assert_eq!(r.error, Some(PlatformError::WindowGone));
        assert!(f.typed(1).is_empty());
    }
}
