//! A dedicated OS thread for blocking file work: log appends, settings
//! saves. Spec 10.1: no blocking call on the tokio reactor (lesson of
//! `project_quip_hangs_not_crashes`: every Mac "crash" was a blocked
//! thread), and a disk that stalls must not stall a heartbeat.
//!
//! Jobs run one at a time, in the order they were queued, so two writes to
//! one file can never land out of order. `flush` waits for everything queued
//! before it (tests and shutdown).

use std::sync::{mpsc, Mutex};

type Job = Box<dyn FnOnce() + Send>;

enum Msg {
    Run(Job),
    Flush(mpsc::Sender<()>),
}

pub struct Writer {
    /// `None` when the thread could not be started: jobs then run inline,
    /// which is slower but never loses a write.
    tx: Mutex<Option<mpsc::Sender<Msg>>>,
}

impl Writer {
    pub fn spawn(name: &str) -> Writer {
        let (tx, rx) = mpsc::channel::<Msg>();
        let started = std::thread::Builder::new().name(name.to_string()).spawn(move || {
            while let Ok(m) = rx.recv() {
                match m {
                    Msg::Run(job) => job(),
                    Msg::Flush(done) => {
                        let _ = done.send(());
                    }
                }
            }
        });
        Writer { tx: Mutex::new(started.ok().map(|_| tx)) }
    }

    fn sender(&self) -> Option<mpsc::Sender<Msg>> {
        self.tx.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }

    /// Queue `job`. Never blocks on I/O.
    pub fn run(&self, job: impl FnOnce() + Send + 'static) {
        match self.sender() {
            Some(tx) => {
                if let Err(mpsc::SendError(Msg::Run(job))) = tx.send(Msg::Run(Box::new(job))) {
                    job(); // the thread died (a panic in a job): do it here
                }
            }
            None => job(),
        }
    }

    /// Block until every job queued before this call has run.
    pub fn flush(&self) {
        if let Some(tx) = self.sender() {
            let (done_tx, done_rx) = mpsc::channel();
            if tx.send(Msg::Flush(done_tx)).is_ok() {
                let _ = done_rx.recv();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn jobs_run_off_the_calling_thread_in_order() {
        let w = Writer::spawn("t");
        let seen = Arc::new(Mutex::new(vec![]));
        let me = std::thread::current().id();
        for i in 0..20 {
            let s = seen.clone();
            w.run(move || {
                assert_ne!(std::thread::current().id(), me);
                s.lock().unwrap().push(i);
            });
        }
        w.flush();
        assert_eq!(*seen.lock().unwrap(), (0..20).collect::<Vec<_>>());
    }

    #[test]
    fn run_does_not_wait_for_a_slow_job() {
        let w = Writer::spawn("t");
        let t0 = std::time::Instant::now();
        w.run(|| std::thread::sleep(std::time::Duration::from_millis(300)));
        assert!(t0.elapsed() < std::time::Duration::from_millis(100));
        w.flush();
        assert!(t0.elapsed() >= std::time::Duration::from_millis(300));
    }

    #[test]
    fn a_panicking_job_does_not_lose_later_writes() {
        let w = Writer::spawn("t");
        w.run(|| panic!("boom"));
        w.flush();
        let hit = Arc::new(Mutex::new(false));
        let h = hit.clone();
        w.run(move || *h.lock().unwrap() = true);
        w.flush();
        assert!(*hit.lock().unwrap());
    }
}
