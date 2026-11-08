//! The OS boundary. `traits` is the contract, `fake` the in-memory backend,
//! `win32` the real one (M2+). `Lanes` is how async code reaches a backend
//! without blocking the tokio reactor (spec 10.1, lesson of
//! `project_quip_hangs_not_crashes`: every Mac "crash" was a blocked thread).

pub mod fake;
pub mod integrity;
pub mod keymap;
pub mod listing;
pub mod traits;
#[cfg(windows)]
pub mod win32;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use traits::{
    FocusStep, InputAccess, InputBackend, Platform, PlatformDisplay, PlatformError, PlatformResult, PlatformWindow,
    WindowBackend, WindowMove, WindowRects, WindowRef,
};

use crate::services::keys::KeyChord;
use crate::services::multiline_policy::Shell;

type Job = Box<dyn FnOnce(&dyn Platform) + Send>;

/// How long ONE backend call on the input lane may take before the lane is
/// given up on (spec 6, hang guard). The slowest legitimate call is a focus
/// refusal (about 550 ms of waits, spec 5.3) or a restore (500 ms, 5.2);
/// a whole job (a long text) may take longer, as it is many calls.
pub const INPUT_STALL_LIMIT: Duration = Duration::from_secs(5);
/// How often a caller waiting on the input lane looks for a stall.
pub const STALL_CHECK: Duration = Duration::from_millis(250);

/// The text a backend call answers once its lane was replaced.
pub const LANE_REPLACED: &str = "the platform lane was replaced after a stalled call";

/// One worker thread's liveness: whether it is still the lane's current
/// worker, and since when its backend call has been running.
struct Guard {
    alive: AtomicBool,
    busy_since: Mutex<Option<Instant>>,
}

impl Guard {
    fn new() -> Guard {
        Guard { alive: AtomicBool::new(true), busy_since: Mutex::new(None) }
    }
    fn alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }
    fn busy(&self) -> std::sync::MutexGuard<'_, Option<Instant>> {
        self.busy_since.lock().unwrap_or_else(|p| p.into_inner())
    }
    /// One backend call has run for at least `limit`.
    fn stalled(&self, limit: Duration) -> bool {
        self.busy().is_some_and(|t| t.elapsed() >= limit)
    }
}

/// The backend as a worker sees it: each call is timed for the watchdog,
/// and once the worker is replaced every call fails at once, so a job that
/// comes back from a stuck call cannot type, focus or move anything more.
struct Watched {
    inner: Arc<dyn Platform>,
    guard: Arc<Guard>,
}

impl Watched {
    fn call<T>(&self, f: impl FnOnce(&dyn Platform) -> PlatformResult<T>) -> PlatformResult<T> {
        if !self.guard.alive() {
            return Err(PlatformError::Failed(LANE_REPLACED.into()));
        }
        *self.guard.busy() = Some(Instant::now());
        let r = f(self.inner.as_ref());
        *self.guard.busy() = None;
        r
    }
}

impl WindowBackend for Watched {
    fn list_windows(&self) -> PlatformResult<Vec<PlatformWindow>> {
        self.call(|p| p.list_windows())
    }
    fn list_displays(&self) -> PlatformResult<Vec<PlatformDisplay>> {
        self.call(|p| p.list_displays())
    }
    fn foreground_window(&self) -> PlatformResult<Option<WindowRef>> {
        self.call(|p| p.foreground_window())
    }
    fn current_shell(&self, w: WindowRef) -> PlatformResult<Option<Shell>> {
        self.call(|p| p.current_shell(w))
    }
    fn bring_to_foreground(&self, w: WindowRef) -> PlatformResult<FocusStep> {
        self.call(|p| p.bring_to_foreground(w))
    }
    fn restore(&self, w: WindowRef) -> PlatformResult<()> {
        self.call(|p| p.restore(w))
    }
    fn rects(&self, w: WindowRef) -> PlatformResult<WindowRects> {
        self.call(|p| p.rects(w))
    }
    fn move_windows(&self, moves: &[WindowMove]) -> Vec<PlatformResult<()>> {
        match self.call(|p| Ok(p.move_windows(moves))) {
            Ok(v) => v,
            Err(e) => moves.iter().map(|_| Err(e.clone())).collect(),
        }
    }
    fn minimize(&self, w: WindowRef) -> PlatformResult<()> {
        self.call(|p| p.minimize(w))
    }
    fn close(&self, w: WindowRef) -> PlatformResult<()> {
        self.call(|p| p.close(w))
    }
    fn input_access(&self, w: WindowRef) -> PlatformResult<InputAccess> {
        self.call(|p| p.input_access(w))
    }
}

impl InputBackend for Watched {
    fn send_units(&self, w: WindowRef, units: &[u16]) -> PlatformResult<usize> {
        self.call(|p| p.send_units(w, units))
    }
    fn press_key(&self, w: WindowRef, chord: KeyChord) -> PlatformResult<usize> {
        self.call(|p| p.press_key(w, chord))
    }
}

/// The lane's current worker thread: where jobs go, and its guard.
struct Worker {
    tx: mpsc::Sender<Job>,
    guard: Arc<Guard>,
}

impl Worker {
    fn spawn(name: &str, platform: Arc<dyn Platform>) -> std::io::Result<Worker> {
        let (tx, rx) = mpsc::channel::<Job>();
        let guard = Arc::new(Guard::new());
        let watched = Watched { inner: platform, guard: guard.clone() };
        std::thread::Builder::new().name(name.to_string()).spawn(move || {
            while let Ok(job) = rx.recv() {
                // A replaced worker drops what is still queued: its callers
                // were already answered (`LaneError::Stalled`).
                if watched.guard.alive() {
                    job(&watched);
                }
            }
        })?;
        Ok(Worker { tx, guard })
    }
}

/// One dedicated OS thread that runs platform jobs in order. With a stall
/// limit, a backend call that runs past it (a Win32 call blocked on a window
/// that stopped pumping messages) gets the lane a NEW thread: the stuck one
/// is left behind, every call it makes from then on fails, and the jobs
/// queued behind it are answered `Stalled` instead of waiting forever.
struct Lane {
    name: String,
    platform: Arc<dyn Platform>,
    stall: Option<Duration>,
    check: Duration,
    worker: Mutex<Worker>,
}

impl Lane {
    fn spawn(
        name: &str,
        platform: Arc<dyn Platform>,
        stall: Option<Duration>,
        check: Duration,
    ) -> std::io::Result<Lane> {
        let worker = Mutex::new(Worker::spawn(name, platform.clone())?);
        Ok(Lane { name: name.to_string(), platform, stall, check, worker })
    }

    fn worker(&self) -> std::sync::MutexGuard<'_, Worker> {
        self.worker.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Gives up on the worker `stuck` (if it is still the current one) and
    /// starts another. If no thread can be started, the old worker stays,
    /// dead: every later job is answered `Stalled`.
    fn replace(&self, stuck: &Arc<Guard>) {
        let mut w = self.worker();
        if !Arc::ptr_eq(&w.guard, stuck) {
            return;
        }
        stuck.alive.store(false, Ordering::SeqCst);
        if let Ok(fresh) = Worker::spawn(&self.name, self.platform.clone()) {
            *w = fresh;
        }
    }

    async fn run<T, F>(&self, f: F) -> Result<T, LaneError>
    where
        T: Send + 'static,
        F: FnOnce(&dyn Platform) -> T + Send + 'static,
    {
        let (otx, mut orx) = tokio::sync::oneshot::channel();
        let job: Job = Box::new(move |p| {
            let _ = otx.send(f(p));
        });
        let guard = {
            let w = self.worker();
            w.tx.send(job).map_err(|_| LaneError::Gone)?;
            w.guard.clone()
        };
        let lost = |g: &Guard| if g.alive() { LaneError::Gone } else { LaneError::Stalled };
        let Some(limit) = self.stall else { return orx.await.map_err(|_| lost(&guard)) };
        loop {
            tokio::select! {
                r = &mut orx => return r.map_err(|_| lost(&guard)),
                _ = tokio::time::sleep(self.check) => {
                    if !guard.alive() {
                        return Err(LaneError::Stalled);
                    }
                    if guard.stalled(limit) {
                        self.replace(&guard);
                        return Err(LaneError::Stalled);
                    }
                }
            }
        }
    }
}

/// Why a lane job has no result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaneError {
    /// The platform thread died (a panic inside a backend call). It does
    /// not come back until a restart.
    Gone,
    /// A backend call on the lane ran past its stall limit (or this job was
    /// queued behind one). The lane has a new thread; the next job runs.
    Stalled,
}

/// Two lanes over one backend:
/// - `query`: listing windows, displays, the foreground window (the 1 s poll);
/// - `input`: focus, typing, keys, arrange, minimize, close.
///
/// The spec (6) puts every Win32 call on ONE platform thread. Two are used so
/// a slow or stuck `SendInput` cannot stall the poll that keeps every phone's
/// grid live (spec 10.4 hang guard). Typing stays serialized on `input`, and
/// listing APIs are safe from any thread. Only `input` has a stall limit
/// (`INPUT_STALL_LIMIT`): its calls reach other apps' windows, the query
/// lane's only read.
#[derive(Clone)]
pub struct Lanes {
    query: Arc<Lane>,
    input: Arc<Lane>,
}

impl Lanes {
    pub fn spawn(platform: Arc<dyn Platform>) -> std::io::Result<Lanes> {
        Self::spawn_with(platform, INPUT_STALL_LIMIT, STALL_CHECK)
    }

    /// `spawn` with another input stall limit and check interval (tests).
    pub fn spawn_with(platform: Arc<dyn Platform>, stall: Duration, check: Duration) -> std::io::Result<Lanes> {
        Ok(Lanes {
            query: Arc::new(Lane::spawn("quip-platform-query", platform.clone(), None, check)?),
            input: Arc::new(Lane::spawn("quip-platform-input", platform, Some(stall), check)?),
        })
    }

    pub async fn query<T, F>(&self, f: F) -> Result<T, LaneError>
    where
        T: Send + 'static,
        F: FnOnce(&dyn Platform) -> T + Send + 'static,
    {
        self.query.run(f).await
    }

    pub async fn input<T, F>(&self, f: F) -> Result<T, LaneError>
    where
        T: Send + 'static,
        F: FnOnce(&dyn Platform) -> T + Send + 'static,
    {
        self.input.run(f).await
    }
}

#[cfg(test)]
mod tests {
    use super::fake::FakePlatform;
    use super::*;
    use std::time::{Duration, Instant};

    #[tokio::test]
    async fn a_blocked_input_lane_does_not_block_queries() {
        let fake = FakePlatform::new(vec![], vec![]);
        fake.set_input_guard(false);
        fake.set_block_typing(Some(Duration::from_millis(500)));
        let lanes = Lanes::spawn(Arc::new(fake)).unwrap();
        let l2 = lanes.clone();
        let w = traits::WindowRef { handle: 1, pid: 1 };
        let typing = tokio::spawn(async move { l2.input(move |p| p.send_units(w, &[0x78])).await });
        tokio::time::sleep(Duration::from_millis(20)).await;
        let t0 = Instant::now();
        let listed = lanes.query(|p| p.list_windows()).await.unwrap();
        assert!(listed.is_ok());
        assert!(t0.elapsed() < Duration::from_millis(100));
        let _ = typing.await;
    }

    fn one_window() -> FakePlatform {
        let w = traits::PlatformWindow {
            handle: 1,
            pid: 1,
            title: "t".into(),
            class_name: "c".into(),
            exe_path: None,
            app: "PowerShell".into(),
            terminal: None,
            shell: None,
            visible: crate::services::layout::PixelRect::default(),
            outer: crate::services::layout::PixelRect::default(),
            is_minimized: false,
            is_maximized: false,
        };
        let f = FakePlatform::new(vec![w], vec![]);
        f.set_input_guard(false);
        f
    }

    fn keys(f: &FakePlatform) -> usize {
        f.calls().iter().filter(|c| matches!(c, fake::FakeCall::Key { .. })).count()
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_stalled_input_call_is_given_up_and_the_lane_runs_the_next_job() {
        let fake = one_window();
        fake.set_block_typing(Some(Duration::from_millis(800)));
        let lanes =
            Lanes::spawn_with(Arc::new(fake.clone()), Duration::from_millis(150), Duration::from_millis(20)).unwrap();
        let w = traits::WindowRef { handle: 1, pid: 1 };
        let t0 = Instant::now();
        let l = lanes.clone();
        let stuck = tokio::spawn(async move {
            l.input(move |p| {
                let typed = p.send_units(w, &[0x78]);
                // Runs after the stuck call returns, on a replaced worker.
                let key = p.press_key(w, crate::services::keys::KeyChord::RETURN);
                (typed, key)
            })
            .await
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        let l = lanes.clone();
        let queued = tokio::spawn(async move { l.input(move |p| p.minimize(w)).await });
        assert_eq!(stuck.await.unwrap(), Err(LaneError::Stalled));
        assert_eq!(queued.await.unwrap(), Err(LaneError::Stalled), "queued behind the stall");
        assert!(t0.elapsed() < Duration::from_millis(600), "given up at the limit: {:?}", t0.elapsed());
        fake.set_block_typing(None);
        let next = lanes.input(move |p| p.press_key(w, crate::services::keys::KeyChord::RETURN)).await;
        assert_eq!(next, Ok(Ok(2)), "a new thread runs the next job");
        // Let the stuck call come back: what it does next must fail.
        tokio::time::sleep(Duration::from_millis(1000).saturating_sub(t0.elapsed())).await;
        assert_eq!(keys(&fake), 1, "only the new job's key; the old job's key never reached the window");
        assert!(!fake.calls().iter().any(|c| matches!(c, fake::FakeCall::Minimize { .. })), "the queued job never ran");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_long_job_of_quick_calls_is_not_a_stall() {
        let fake = one_window();
        fake.set_block_typing(Some(Duration::from_millis(60)));
        let lanes =
            Lanes::spawn_with(Arc::new(fake.clone()), Duration::from_millis(150), Duration::from_millis(20)).unwrap();
        let w = traits::WindowRef { handle: 1, pid: 1 };
        let r = lanes.input(move |p| (0..8).map(|_| p.send_units(w, &[0x78])).collect::<Vec<_>>()).await;
        assert_eq!(r, Ok(vec![Ok(1); 8]), "480 ms in all, no call over 150 ms");
    }

    #[tokio::test]
    async fn jobs_on_a_lane_run_in_order() {
        let lanes = Lanes::spawn(Arc::new(FakePlatform::default())).unwrap();
        let order = Arc::new(std::sync::Mutex::new(vec![]));
        let mut hs = vec![];
        for i in 0..5 {
            let o = order.clone();
            let l = lanes.clone();
            hs.push(tokio::spawn(async move { l.input(move |_| o.lock().unwrap().push(i)).await }));
            tokio::task::yield_now().await;
        }
        for h in hs {
            h.await.unwrap().unwrap();
        }
        assert_eq!(*order.lock().unwrap(), vec![0, 1, 2, 3, 4]);
    }
}
