//! Spec 5.2, the order of an arrange: restore, measure, move, verify, retry.
//! It sits above `platform/` (like `injector`), so the fake platform tests
//! the order on the Mac and the Win32 backend only makes the calls.
//!
//! 1. Restore every minimized or maximized target (`restore`), and only then
//!    read its rects: a minimized window has no DWM bounds, so its invisible
//!    border is known only once it is back.
//! 2. Read every target's rects; grow each visible target by its border
//!    (`layout::compensate_border`).
//! 3. ONE `move_windows` call for all of them, in broadcast order.
//! 4. After `settle`, read the rects again. A window more than 1 px off its
//!    target on any edge gets one more move, computed from its new rects
//!    (Windows rescales a window that lands on a monitor with another DPI).
//! 5. Still off after that: `OffTarget` (the app keeps a minimum size). That
//!    is logged, not counted as refused.
//!
//! Runs on the input lane, where blocking (the settle sleep) is fine.
//!
//! Mac parity: none for this order. The Mac (`WindowManager.swift`
//! arrange) sets AX position then size per window, with no batch, no
//! restore-then-measure, no verify and no retry; only the outcome
//! (`ArrangeOutcomeTests.swift`) and the tiling math
//! (`ArrangeLayoutMappingTests.swift`, `vectors/arrange.json`) are shared,
//! and those are held in `layout.rs`.

use std::time::Duration;

use super::layout::{self, PixelRect};
use crate::platform::traits::{InputAccess, Platform, PlatformError, WindowMove, WindowRects, WindowRef};
use crate::protocol::types::ArrangeLayout;

/// How long the host waits after the batch before it measures (spec 5.2).
pub const SETTLE: Duration = Duration::from_millis(150);

/// How far (px) any edge may be from its target and still count as there.
pub const TOLERANCE: i32 = 1;

/// The refusal text for a window Windows would not move (spec 5.2): one
/// above Quip's integrity level, or one still exactly where it was after
/// the move and its retry (Windows can ignore a move without an error).
pub const NOT_MOVED: &str = "elevated or refused";

/// One window to tile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    /// Wire id, for the logs.
    pub id: String,
    pub window: WindowRef,
    /// The VISIBLE rect it should end at (no border compensation yet).
    pub visible: PixelRect,
    /// Minimized or maximized when listed: restore before measuring.
    pub restore_first: bool,
}

/// What happened to one target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TargetResult {
    Moved,
    /// Windows would not move (or restore) it; the text says why
    /// (`elevated or refused`, `not responding`).
    Refused(String),
    /// The window closed (or its handle belongs to another process now).
    Gone,
    /// Moved, but still off its target after the retry: where it ended.
    OffTarget {
        got: PixelRect,
    },
}

impl TargetResult {
    /// Counts against "Windows refused to move N of M windows".
    pub fn is_refused(&self) -> bool {
        matches!(self, TargetResult::Refused(_) | TargetResult::Gone)
    }
}

fn failed(e: PlatformError) -> TargetResult {
    match e {
        PlatformError::WindowGone => TargetResult::Gone,
        PlatformError::Refused(m) => TargetResult::Refused(m),
        other => TargetResult::Refused(other.to_string()),
    }
}

/// True when every edge of `got` is within `TOLERANCE` of `want`.
pub fn on_target(got: PixelRect, want: PixelRect) -> bool {
    [(got.x, want.x), (got.y, want.y), (got.right(), want.right()), (got.bottom(), want.bottom())]
        .iter()
        .all(|(g, w)| (g - w).abs() <= TOLERANCE)
}

fn needs_restore(r: &WindowRects) -> bool {
    r.is_minimized || r.is_maximized
}

/// One `move_windows` call for `which` (indexes into `targets`), each
/// computed from its `rects`. Failures land in `results`.
fn move_batch(
    p: &dyn Platform,
    targets: &[Target],
    which: &[usize],
    rects: &[Option<WindowRects>],
    results: &mut [Option<TargetResult>],
) -> Vec<usize> {
    let mut moved = Vec::with_capacity(which.len());
    let moves: Vec<WindowMove> = which
        .iter()
        .filter_map(|&i| {
            let r = rects[i]?;
            moved.push(i);
            Some(WindowMove {
                window: targets[i].window,
                outer: layout::compensate_border(targets[i].visible, r.outer, r.visible),
            })
        })
        .collect();
    if moves.is_empty() {
        return moved;
    }
    let out = p.move_windows(&moves);
    let mut ok = Vec::with_capacity(moved.len());
    for (k, &i) in moved.iter().enumerate() {
        match out.get(k) {
            Some(Ok(())) => ok.push(i),
            Some(Err(e)) => results[i] = Some(failed(e.clone())),
            None => results[i] = Some(TargetResult::Refused("no result from the platform".into())),
        }
    }
    ok
}

/// Reads the rects of `which` into `rects`; a failure lands in `results`.
fn measure(
    p: &dyn Platform,
    targets: &[Target],
    which: &[usize],
    rects: &mut [Option<WindowRects>],
    results: &mut [Option<TargetResult>],
) {
    for &i in which {
        match p.rects(targets[i].window) {
            Ok(r) => rects[i] = Some(r),
            Err(e) => {
                rects[i] = None;
                results[i] = Some(failed(e));
            }
        }
    }
}

/// Spec 5.2 for `targets`, in order. One result per target.
pub fn execute(p: &dyn Platform, targets: &[Target], settle: Duration) -> Vec<TargetResult> {
    let n = targets.len();
    let mut results: Vec<Option<TargetResult>> = vec![None; n];
    let mut rects: Vec<Option<WindowRects>> = vec![None; n];

    // 1. Restore, then 2. measure. A window minimized or maximized since the
    // listing is restored too, and measured again.
    // UIPI: a window above Quip's integrity level ignores the move without
    // an error, so it is refused up front, like typing (spec 5.4 step 2b).
    for (i, t) in targets.iter().enumerate() {
        results[i] = match p.input_access(t.window) {
            Ok(InputAccess::Allowed) => None,
            Ok(InputAccess::Elevated | InputAccess::Unknown) => Some(TargetResult::Refused(NOT_MOVED.into())),
            Err(e) => Some(failed(e)),
        };
    }

    let mut restored = vec![false; n];
    for (i, t) in targets.iter().enumerate() {
        if results[i].is_some() {
            continue;
        }
        if t.restore_first {
            restored[i] = true;
            if let Err(e) = p.restore(t.window) {
                results[i] = Some(failed(e));
            }
        }
    }
    let pending: Vec<usize> = (0..n).filter(|&i| results[i].is_none()).collect();
    measure(p, targets, &pending, &mut rects, &mut results);
    let late: Vec<usize> =
        pending.iter().copied().filter(|&i| !restored[i] && rects[i].as_ref().is_some_and(needs_restore)).collect();
    for &i in &late {
        if let Err(e) = p.restore(targets[i].window) {
            rects[i] = None;
            results[i] = Some(failed(e));
        }
    }
    let again: Vec<usize> = late.iter().copied().filter(|&i| results[i].is_none()).collect();
    measure(p, targets, &again, &mut rects, &mut results);

    // 3. One batch.
    let pending: Vec<usize> = (0..n).filter(|&i| results[i].is_none()).collect();
    // Where each was before the first move: one still there after the retry
    // was not moved at all, which is a refusal, not a minimum size.
    let before: Vec<Option<PixelRect>> = rects.iter().map(|r| r.map(|r| r.visible)).collect();
    let moved = move_batch(p, targets, &pending, &rects, &mut results);
    if moved.is_empty() {
        return finish(results);
    }

    // 4. Verify; one retry for whatever is off.
    sleep(settle);
    measure(p, targets, &moved, &mut rects, &mut results);
    let off: Vec<usize> = moved
        .iter()
        .copied()
        .filter(|&i| rects[i].is_some_and(|r| !on_target(r.visible, targets[i].visible)))
        .collect();
    for &i in &moved {
        if results[i].is_none() && !off.contains(&i) {
            results[i] = Some(TargetResult::Moved);
        }
    }
    if off.is_empty() {
        return finish(results);
    }
    let retried = move_batch(p, targets, &off, &rects, &mut results);
    if retried.is_empty() {
        return finish(results);
    }

    // 5. Still off: where it ended.
    sleep(settle);
    measure(p, targets, &retried, &mut rects, &mut results);
    for &i in &retried {
        if results[i].is_none() {
            results[i] = Some(match rects[i] {
                Some(r) if on_target(r.visible, targets[i].visible) => TargetResult::Moved,
                Some(r) if before[i] == Some(r.visible) => TargetResult::Refused(NOT_MOVED.into()),
                Some(r) => TargetResult::OffTarget { got: r.visible },
                _ => TargetResult::Moved,
            });
        }
    }
    finish(results)
}

fn sleep(d: Duration) {
    if !d.is_zero() {
        std::thread::sleep(d);
    }
}

fn finish(results: Vec<Option<TargetResult>>) -> Vec<TargetResult> {
    results.into_iter().map(|r| r.unwrap_or_else(|| TargetResult::Refused("not measured".into()))).collect()
}

/// What is wrong with `got` (visible rects, in tile order) as a `layout`
/// tiling of `work`, every rule within `TOLERANCE`: the first tile starts
/// at the work area's edge, the last ends at the other edge, neighbours
/// leave no gap and do not overlap, and the cross axis spans the work area.
/// Empty when it is a clean tiling. Shared by the Win32 UI tests and the
/// selftest.
pub fn tiling_problems(layout: ArrangeLayout, work: PixelRect, got: &[PixelRect]) -> Vec<String> {
    let mut problems = Vec::new();
    let near = |a: i32, b: i32| (a - b).abs() <= TOLERANCE;
    let (Some(first), Some(last)) = (got.first(), got.last()) else { return vec!["no windows".into()] };
    // (start, end) along the tiling axis, (start, end) across it.
    let axes = |r: &PixelRect| match layout {
        ArrangeLayout::Horizontal => ((r.x, r.right()), (r.y, r.bottom())),
        ArrangeLayout::Vertical => ((r.y, r.bottom()), (r.x, r.right())),
    };
    let ((w_start, w_end), (c_start, c_end)) = axes(&work);
    if !near(axes(first).0 .0, w_start) {
        problems.push(format!("the first window starts at {}, the work area at {w_start}", axes(first).0 .0));
    }
    if !near(axes(last).0 .1, w_end) {
        problems.push(format!("the last window ends at {}, the work area at {w_end}", axes(last).0 .1));
    }
    for (i, pair) in got.windows(2).enumerate() {
        let (end, start) = (axes(&pair[0]).0 .1, axes(&pair[1]).0 .0);
        if !near(end, start) {
            problems.push(format!("windows {i} and {} leave {} px between them", i + 1, start - end));
        }
    }
    for (i, r) in got.iter().enumerate() {
        let (s, e) = axes(r).1;
        if !near(s, c_start) || !near(e, c_end) {
            problems.push(format!("window {i} spans {s}..{e} across, the work area {c_start}..{c_end}"));
        }
    }
    problems
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::fake::{FakeCall, FakePlatform, Fixture};
    use crate::platform::traits::WindowBackend;

    const WORK: PixelRect = PixelRect { x: 0, y: 0, width: 1920, height: 1040 };

    fn fake() -> FakePlatform {
        FakePlatform::from_fixture(
            &Fixture::parse(
                r#"{
                  "displays":[{"deviceName":"d1","name":"FakeWindows Display",
                     "bounds":{"x":0,"y":0,"width":1920,"height":1080},
                     "workArea":{"x":0,"y":0,"width":1920,"height":1040},"isPrimary":true}],
                  "windows":[
                    {"handle":1,"pid":10,"title":"one","className":"ConsoleWindowClass","shells":["cmd.exe"],
                     "visible":{"x":100,"y":100,"width":800,"height":600}},
                    {"handle":2,"pid":20,"title":"two","className":"ConsoleWindowClass","shells":["cmd.exe"],
                     "visible":{"x":300,"y":200,"width":700,"height":500}},
                    {"handle":3,"pid":30,"title":"three","className":"ConsoleWindowClass","shells":["cmd.exe"],
                     "visible":{"x":500,"y":300,"width":600,"height":400}}
                  ]}"#,
            )
            .unwrap(),
        )
    }

    fn targets(p: &FakePlatform, handles: &[u64], layout: ArrangeLayout) -> Vec<Target> {
        let tiles = layout::arrange(layout, handles.len(), WORK);
        handles
            .iter()
            .zip(tiles)
            .map(|(&h, t)| {
                let w = p.windows().into_iter().find(|w| w.handle == h).unwrap();
                Target {
                    id: format!("w{h}"),
                    window: w.window_ref(),
                    visible: t,
                    restore_first: w.is_minimized || w.is_maximized,
                }
            })
            .collect()
    }

    fn visible(p: &FakePlatform, h: u64) -> PixelRect {
        p.windows().into_iter().find(|w| w.handle == h).unwrap().visible
    }

    fn moves(p: &FakePlatform) -> Vec<u64> {
        p.calls()
            .into_iter()
            .filter_map(|c| match c {
                FakeCall::Move { handle, .. } => Some(handle),
                _ => None,
            })
            .collect()
    }

    type R<T> = crate::platform::traits::PlatformResult<T>;

    /// The fake, recording each `move_windows` batch (as handles) and able
    /// to run `before_rects` before its `n`-th `rects` call.
    #[derive(Default)]
    struct Spy {
        inner: FakePlatform,
        batches: std::sync::Mutex<Vec<Vec<u64>>>,
        before_rects: Option<(usize, Box<dyn Fn() + Send + Sync>)>,
        rects_seen: std::sync::atomic::AtomicUsize,
    }

    impl Spy {
        fn new(inner: FakePlatform) -> Spy {
            Spy { inner, ..Default::default() }
        }
    }

    impl WindowBackend for Spy {
        fn list_windows(&self) -> R<Vec<crate::platform::traits::PlatformWindow>> {
            self.inner.list_windows()
        }
        fn list_displays(&self) -> R<Vec<crate::platform::traits::PlatformDisplay>> {
            self.inner.list_displays()
        }
        fn foreground_window(&self) -> R<Option<WindowRef>> {
            self.inner.foreground_window()
        }
        fn current_shell(&self, w: WindowRef) -> R<Option<crate::services::multiline_policy::Shell>> {
            self.inner.current_shell(w)
        }
        fn bring_to_foreground(&self, w: WindowRef) -> R<crate::platform::traits::FocusStep> {
            self.inner.bring_to_foreground(w)
        }
        fn restore(&self, w: WindowRef) -> R<()> {
            self.inner.restore(w)
        }
        fn rects(&self, w: WindowRef) -> R<WindowRects> {
            let n = self.rects_seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
            if let Some((at, f)) = &self.before_rects {
                if *at == n {
                    f();
                }
            }
            self.inner.rects(w)
        }
        fn move_windows(&self, m: &[WindowMove]) -> Vec<R<()>> {
            self.batches.lock().unwrap().push(m.iter().map(|m| m.window.handle).collect());
            self.inner.move_windows(m)
        }
        fn minimize(&self, w: WindowRef) -> R<()> {
            self.inner.minimize(w)
        }
        fn close(&self, w: WindowRef) -> R<()> {
            self.inner.close(w)
        }
        fn input_access(&self, w: WindowRef) -> R<crate::platform::traits::InputAccess> {
            self.inner.input_access(w)
        }
    }

    impl crate::platform::traits::InputBackend for Spy {
        fn send_units(&self, w: WindowRef, u: &[u16]) -> R<usize> {
            self.inner.send_units(w, u)
        }
        fn press_key(&self, w: WindowRef, k: crate::services::keys::KeyChord) -> R<usize> {
            self.inner.press_key(w, k)
        }
    }

    #[test]
    fn restores_first_then_measures_the_border() {
        let p = fake();
        p.set_minimized(1, true);
        p.set_border_after_restore(1, 7);
        let t = targets(&p, &[1, 2], ArrangeLayout::Horizontal);
        assert!(t[0].restore_first);
        let r = execute(&p, &t, Duration::ZERO);
        assert_eq!(r, vec![TargetResult::Moved, TargetResult::Moved]);
        assert!(on_target(visible(&p, 1), t[0].visible), "{:?} vs {:?}", visible(&p, 1), t[0].visible);
        assert_eq!(visible(&p, 1), t[0].visible, "exact: the border was measured after the restore");
        let calls = p.calls();
        let restore = calls.iter().position(|c| *c == FakeCall::Restore { handle: 1 }).unwrap();
        let mv = calls.iter().position(|c| matches!(c, FakeCall::Move { handle: 1, .. })).unwrap();
        assert!(restore < mv);
        assert_eq!(moves(&p), [1, 2], "on target the first time: no retry");
        let restored: Vec<u64> = calls
            .iter()
            .filter_map(|c| match c {
                FakeCall::Restore { handle } => Some(*handle),
                _ => None,
            })
            .collect();
        assert_eq!(restored, [1], "once, and never a window that is neither minimized nor maximized");
    }

    #[test]
    fn targets_move_in_one_batch_in_broadcast_order() {
        let b = Spy::new(fake());
        let t = targets(&b.inner, &[3, 1, 2], ArrangeLayout::Vertical);
        let r = execute(&b, &t, Duration::ZERO);
        assert!(r.iter().all(|r| *r == TargetResult::Moved), "{r:?}");
        assert_eq!(*b.batches.lock().unwrap(), vec![vec![3, 1, 2]]);
        for t in &t {
            assert_eq!(visible(&b.inner, t.window.handle), t.visible);
        }
    }

    #[test]
    fn one_refused_window_does_not_stop_the_others() {
        let p = fake();
        p.set_refuse_move(2, true);
        let t = targets(&p, &[1, 2, 3], ArrangeLayout::Horizontal);
        let r = execute(&p, &t, Duration::ZERO);
        assert_eq!(
            r,
            vec![TargetResult::Moved, TargetResult::Refused("elevated or refused".into()), TargetResult::Moved]
        );
        assert!(r[1].is_refused() && !r[0].is_refused());
        assert_eq!(visible(&p, 3), t[2].visible);
        assert_eq!(moves(&p), [1, 3], "a refused window is not retried");
    }

    #[test]
    fn a_gone_window_is_gone_not_moved() {
        let p = fake();
        let t = targets(&p, &[1, 2], ArrangeLayout::Horizontal);
        p.remove_window(1);
        let r = execute(&p, &t, Duration::ZERO);
        assert_eq!(r, vec![TargetResult::Gone, TargetResult::Moved]);
        assert!(r[0].is_refused());
        assert_eq!(moves(&p), [2]);
        // A handle now owned by another process is gone too, and never moved.
        let p = fake();
        let t = targets(&p, &[1], ArrangeLayout::Horizontal);
        p.reuse_handle(1, 77, "someone else");
        assert_eq!(execute(&p, &t, Duration::ZERO), vec![TargetResult::Gone]);
        assert!(moves(&p).is_empty());
    }

    #[test]
    fn a_rescaled_window_gets_exactly_one_more_move() {
        let p = fake();
        p.set_rescale_once(1, 125);
        let t = targets(&p, &[1, 2], ArrangeLayout::Horizontal);
        let r = execute(&p, &t, Duration::ZERO);
        assert_eq!(r, vec![TargetResult::Moved, TargetResult::Moved]);
        assert_eq!(moves(&p), [1, 2, 1]);
        assert_eq!(visible(&p, 1), t[0].visible);
    }

    #[test]
    fn no_second_move_when_every_window_is_on_target() {
        let p = fake();
        let t = targets(&p, &[1, 2, 3], ArrangeLayout::Vertical);
        execute(&p, &t, Duration::ZERO);
        assert_eq!(moves(&p), [1, 2, 3]);
        p.clear_calls();
        // Again, already in place: one move each, still no retry.
        execute(&p, &t, Duration::ZERO);
        assert_eq!(moves(&p), [1, 2, 3]);
    }

    #[test]
    fn the_verify_waits_for_the_settle_time() {
        let p = fake();
        let t = targets(&p, &[1], ArrangeLayout::Vertical);
        let start = std::time::Instant::now();
        execute(&p, &t, Duration::from_millis(60));
        assert!(start.elapsed() >= Duration::from_millis(60), "{:?}", start.elapsed());
        // Nothing moved: nothing to verify, no wait.
        let start = std::time::Instant::now();
        assert!(execute(&p, &[], Duration::from_secs(5)).is_empty());
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn a_window_held_at_minimum_size_is_off_target_not_refused() {
        let p = fake();
        p.set_min_size(2, 1200, 700);
        let t = targets(&p, &[1, 2], ArrangeLayout::Horizontal);
        let r = execute(&p, &t, Duration::ZERO);
        assert_eq!(r[0], TargetResult::Moved);
        let got = visible(&p, 2);
        assert_eq!(r[1], TargetResult::OffTarget { got });
        assert!(!r[1].is_refused());
        assert_eq!(got.width, 1200 - 14, "the minimum outer width, less the border");
        assert_eq!(moves(&p), [1, 2, 2], "one retry, then it is left alone");
    }

    #[test]
    fn an_elevated_or_unreadable_window_is_refused_before_anything_is_done_to_it() {
        use crate::platform::traits::InputAccess;
        let p = fake();
        p.set_minimized(2, true);
        p.set_input_access(2, InputAccess::Elevated);
        p.set_input_access(3, InputAccess::Unknown);
        let t = targets(&p, &[1, 2, 3], ArrangeLayout::Horizontal);
        let r = execute(&p, &t, Duration::ZERO);
        let refused = TargetResult::Refused(NOT_MOVED.into());
        assert_eq!(r, vec![TargetResult::Moved, refused.clone(), refused]);
        assert_eq!(NOT_MOVED, "elevated or refused");
        assert_eq!(moves(&p), [1]);
        assert!(!p.calls().contains(&FakeCall::Restore { handle: 2 }), "not restored either");
    }

    #[test]
    fn a_window_that_closed_before_its_access_check_is_gone() {
        let p = fake();
        let t = targets(&p, &[1, 2], ArrangeLayout::Horizontal);
        p.set_input_access_error(1, Some(PlatformError::WindowGone));
        let r = execute(&p, &t, Duration::ZERO);
        assert_eq!(r, vec![TargetResult::Gone, TargetResult::Moved]);
    }

    #[test]
    fn a_window_windows_silently_leaves_in_place_is_refused_not_off_target() {
        let p = fake();
        p.set_ignore_move(2, true);
        let before = visible(&p, 2);
        let t = targets(&p, &[1, 2], ArrangeLayout::Horizontal);
        let r = execute(&p, &t, Duration::ZERO);
        assert_eq!(r, vec![TargetResult::Moved, TargetResult::Refused(NOT_MOVED.into())]);
        assert!(r[1].is_refused());
        assert_eq!(visible(&p, 2), before);
        assert_eq!(moves(&p), [1, 2, 2], "moved, retried once, then refused");
    }

    #[test]
    fn a_maximized_window_is_restored_before_it_is_measured() {
        let p = fake();
        p.set_maximized(1, true);
        p.set_border_after_restore(1, 7);
        let t = targets(&p, &[1, 2], ArrangeLayout::Vertical);
        assert!(t[0].restore_first);
        let r = execute(&p, &t, Duration::ZERO);
        assert_eq!(r, vec![TargetResult::Moved, TargetResult::Moved]);
        assert_eq!(visible(&p, 1), t[0].visible);
        assert!(!p.rects(t[0].window).unwrap().is_maximized);
        assert_eq!(moves(&p), [1, 2], "measured after the restore: no retry needed");
    }

    #[test]
    fn a_window_minimized_after_the_listing_is_restored_too() {
        let p = fake();
        let t = targets(&p, &[1, 2], ArrangeLayout::Horizontal);
        assert!(!t[0].restore_first);
        p.set_minimized(1, true);
        p.set_border_after_restore(1, 7);
        let r = execute(&p, &t, Duration::ZERO);
        assert_eq!(r, vec![TargetResult::Moved, TargetResult::Moved]);
        assert!(p.calls().contains(&FakeCall::Restore { handle: 1 }));
        assert_eq!(visible(&p, 1), t[0].visible);
        assert_eq!(moves(&p), [1, 2]);
    }

    #[test]
    fn a_window_that_closes_before_the_verify_is_gone() {
        let p = fake();
        let t = targets(&p, &[1, 2], ArrangeLayout::Horizontal);
        let gone = p.clone();
        // rects calls: 1 and 2 measure, 3 verifies window 1.
        let spy = Spy {
            before_rects: Some((
                3,
                Box::new(move || {
                    gone.remove_window(1);
                }),
            )),
            ..Spy::new(p)
        };
        let r = execute(&spy, &t, Duration::ZERO);
        assert_eq!(r, vec![TargetResult::Gone, TargetResult::Moved]);
    }

    #[test]
    fn on_target_allows_one_px_on_each_edge_and_no_more() {
        let want = PixelRect::new(10, 20, 100, 50);
        assert!(on_target(want, want));
        assert!(on_target(PixelRect::new(11, 19, 100, 50), want));
        assert!(on_target(PixelRect::new(10, 20, 101, 51), want));
        for off in [
            PixelRect::new(12, 20, 98, 50),
            PixelRect::new(10, 22, 100, 48),
            PixelRect::new(10, 20, 102, 50),
            PixelRect::new(10, 20, 100, 52),
            PixelRect::new(8, 20, 102, 50),
            PixelRect::new(10, 18, 100, 52),
        ] {
            assert!(!on_target(off, want), "{off:?}");
        }
    }

    #[test]
    fn the_targets_border_is_compensated_from_the_measured_rects() {
        // Moved from app_state: the fixture border is 7 px left, right and
        // bottom, 0 on top.
        let p = fake();
        let t = targets(&p, &[1, 2], ArrangeLayout::Horizontal);
        execute(&p, &t, Duration::ZERO);
        let outers: Vec<PixelRect> = p
            .calls()
            .into_iter()
            .filter_map(|c| match c {
                FakeCall::Move { outer, .. } => Some(outer),
                _ => None,
            })
            .collect();
        assert_eq!(outers, [PixelRect::new(-7, 0, 974, 1047), PixelRect::new(953, 0, 974, 1047)]);
    }

    #[test]
    fn tiling_problems_holds_every_edge_rule() {
        let work = PixelRect::new(0, 0, 1920, 1040);
        for layout in [ArrangeLayout::Horizontal, ArrangeLayout::Vertical] {
            let tiles = layout::arrange(layout, 3, work);
            assert!(tiling_problems(layout, work, &tiles).is_empty(), "{layout:?}");
            let mut nudged = tiles.clone();
            nudged[1].x += 1;
            nudged[1].y += 1;
            assert!(tiling_problems(layout, work, &nudged).is_empty(), "1 px is allowed");
        }
        let cols = layout::arrange(ArrangeLayout::Horizontal, 2, work);
        let bad = |f: &dyn Fn(&mut Vec<PixelRect>)| {
            let mut v = cols.clone();
            f(&mut v);
            tiling_problems(ArrangeLayout::Horizontal, work, &v)
        };
        assert!(bad(&|v| v[0].x = 2)[0].contains("first window starts at 2"));
        assert!(bad(&|v| v[1].width -= 2)[0].contains("last window ends at 1918"));
        assert!(bad(&|v| {
            v[1].x += 7;
            v[1].width -= 7;
        })[0]
            .contains("leave 7 px"));
        assert!(bad(&|v| v[0].width += 2)[0].contains("leave -2 px"));
        assert!(bad(&|v| v[0].height -= 2)[0].contains("window 0 spans 0..1038"));
        assert!(bad(&|v| v[1].y = 2)[0].contains("window 1 spans 2.."));
        let rows = layout::arrange(ArrangeLayout::Vertical, 2, work);
        let mut r = rows.clone();
        r[0].width = 1000;
        assert!(tiling_problems(ArrangeLayout::Vertical, work, &r)[0].contains("across"));
        r = rows.clone();
        r[1].y += 3;
        r[1].height -= 3;
        assert!(tiling_problems(ArrangeLayout::Vertical, work, &r)[0].contains("leave 3 px"));
        assert_eq!(tiling_problems(ArrangeLayout::Vertical, work, &[]), ["no windows"]);
    }

    #[test]
    fn nothing_to_do_makes_no_call() {
        let b = Spy::new(fake());
        assert!(execute(&b, &[], Duration::ZERO).is_empty());
        assert!(b.batches.lock().unwrap().is_empty());
    }
}
