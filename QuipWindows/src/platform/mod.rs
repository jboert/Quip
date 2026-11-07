//! The OS boundary. `traits` is the contract, `fake` the in-memory backend,
//! `win32` the real one (M2+). `Lanes` is how async code reaches a backend
//! without blocking the tokio reactor (spec 10.1, lesson of
//! `project_quip_hangs_not_crashes`: every Mac "crash" was a blocked thread).

pub mod fake;
pub mod listing;
pub mod traits;
#[cfg(windows)]
pub mod win32;

use std::sync::mpsc;
use std::sync::Arc;

use traits::Platform;

type Job = Box<dyn FnOnce(&dyn Platform) + Send>;

/// One dedicated OS thread that runs platform jobs in order.
struct Lane {
    tx: mpsc::Sender<Job>,
}

impl Lane {
    fn spawn(name: &str, platform: Arc<dyn Platform>) -> std::io::Result<Lane> {
        let (tx, rx) = mpsc::channel::<Job>();
        std::thread::Builder::new().name(name.to_string()).spawn(move || {
            while let Ok(job) = rx.recv() {
                job(platform.as_ref());
            }
        })?;
        Ok(Lane { tx })
    }

    async fn run<T, F>(&self, f: F) -> Result<T, LaneGone>
    where
        T: Send + 'static,
        F: FnOnce(&dyn Platform) -> T + Send + 'static,
    {
        let (otx, orx) = tokio::sync::oneshot::channel();
        let job: Job = Box::new(move |p| {
            let _ = otx.send(f(p));
        });
        self.tx.send(job).map_err(|_| LaneGone)?;
        orx.await.map_err(|_| LaneGone)
    }
}

/// The platform thread died (a panic inside a backend call).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LaneGone;

/// Two lanes over one backend:
/// - `query`: listing windows, displays, the foreground window (the 1 s poll);
/// - `input`: focus, typing, keys, arrange, minimize, close.
///
/// The spec (6) puts every Win32 call on ONE platform thread. Two are used so
/// a slow or stuck `SendInput` cannot stall the poll that keeps every phone's
/// grid live (spec 10.4 hang guard). Typing stays serialized on `input`, and
/// listing APIs are safe from any thread.
#[derive(Clone)]
pub struct Lanes {
    query: Arc<Lane>,
    input: Arc<Lane>,
}

impl Lanes {
    pub fn spawn(platform: Arc<dyn Platform>) -> std::io::Result<Lanes> {
        Ok(Lanes {
            query: Arc::new(Lane::spawn("quip-platform-query", platform.clone())?),
            input: Arc::new(Lane::spawn("quip-platform-input", platform)?),
        })
    }

    pub async fn query<T, F>(&self, f: F) -> Result<T, LaneGone>
    where
        T: Send + 'static,
        F: FnOnce(&dyn Platform) -> T + Send + 'static,
    {
        self.query.run(f).await
    }

    pub async fn input<T, F>(&self, f: F) -> Result<T, LaneGone>
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
