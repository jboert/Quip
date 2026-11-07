//! The four log files as one handle (spec 8). Line formats are the Mac's:
//! - `websocket.log`: `QuipLog.line` (`[ts] [SEV] [ws] msg`), `WebSocketServer.wslog`;
//! - `injection.log`: `<ts> DROPPED op=… window=… app=… kind=… msg="…"[ detail="…"]`;
//! - `phone.log`: `PhoneLogSink.format`;
//! - `latency.log`: `<ts> send_text rid=… …` (`appendLatency`).
//!
//! Text the user dictated never reaches any of them.
//!
//! Every append goes to one writer thread (`writer`): a log call made on a
//! tokio worker formats the line and returns; the file I/O happens elsewhere,
//! in order. `flush` waits for it (tests read the files after flushing).

use std::sync::Arc;

use super::clock::SharedClock;
use super::injection_log::{self, InjectionKind};
use super::log_paths::LogPaths;
use super::quip_log::{self, Severity};
use super::writer::Writer;
use super::{phone_log, secret_redactor};

#[derive(Clone)]
pub struct Logs {
    paths: LogPaths,
    clock: SharedClock,
    /// Also echo websocket lines to stderr (`--fake-platform`, like fake-mac).
    echo: bool,
    writer: Arc<Writer>,
}

impl Logs {
    pub fn new(paths: LogPaths, clock: SharedClock, echo: bool) -> Self {
        let writer = Arc::new(Writer::spawn("quip-log-writer"));
        let p = paths.clone();
        writer.run(move || p.ensure_dir());
        Self { paths, clock, echo, writer }
    }

    fn append(&self, path: std::path::PathBuf, text: String) {
        self.writer.run(move || quip_log::append(&path, &text));
    }

    /// Wait until every line logged so far is in its file.
    pub fn flush(&self) {
        self.writer.flush();
    }

    pub fn paths(&self) -> &LogPaths {
        &self.paths
    }

    /// `websocket.log`. The message is redacted first: an auth envelope or a
    /// token must never land in a log (`b6a8498`).
    pub fn ws(&self, severity: Severity, message: &str) {
        let msg = secret_redactor::redact(message);
        if self.echo {
            eprintln!("[ws] [{}] {msg}", severity.as_str());
        }
        self.append(self.paths.websocket(), quip_log::line(severity, "ws", &msg, self.clock.unix_seconds()));
    }

    /// Debug-level: stderr only when echoing, never a file (spec 3: unknown
    /// types are "logged at debug level").
    pub fn debug(&self, message: &str) {
        if self.echo {
            eprintln!("[debug] {}", secret_redactor::redact(message));
        }
    }

    pub fn injection(&self, op: &str, window: &str, app: Option<&str>, kind: InjectionKind, msg: &str, detail: &str) {
        let line = injection_log::redacted_file_line(self.clock.unix_seconds(), op, window, app, kind, msg, detail);
        if self.echo {
            eprint!("[injection] {line}");
        }
        self.append(self.paths.injection(), line);
    }

    pub fn phone(&self, lines: &[String]) {
        let text = phone_log::format(lines, self.clock.unix_seconds());
        if !text.is_empty() {
            self.append(self.paths.phone(), text);
        }
    }

    pub fn latency(&self, message: &str) {
        let line = format!("{} {}\n", super::clock::iso8601(self.clock.unix_seconds()), message);
        if self.echo {
            eprint!("[latency] {line}");
        }
        self.append(self.paths.latency(), line);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::clock::ManualClock;

    #[test]
    fn each_file_gets_its_format() {
        let dir = tempfile::tempdir().unwrap();
        let logs = Logs::new(LogPaths::new(dir.path()), ManualClock::new(0), false);
        logs.ws(Severity::Warn, r#"recv {"type":"auth","pin":"12345678"}"#);
        logs.injection("sendText", "w-1", Some("PowerShell"), InjectionKind::WindowClosed, "gone", "");
        logs.phone(&["ptt start".to_string()]);
        logs.latency("send_text rid=ABCDEF12 success=1");
        logs.flush();
        let ws = std::fs::read_to_string(logs.paths().websocket()).unwrap();
        assert!(ws.starts_with("[1970-01-01T00:00:00Z] [WARN] [ws] "));
        assert!(!ws.contains("12345678"), "PIN redacted: {ws}");
        let inj = std::fs::read_to_string(logs.paths().injection()).unwrap();
        assert_eq!(
            inj,
            "1970-01-01T00:00:00Z DROPPED op=sendText window=w-1 app=PowerShell kind=windowClosed msg=\"gone\"\n"
        );
        assert_eq!(std::fs::read_to_string(logs.paths().phone()).unwrap(), "1970-01-01T00:00:00Z ptt start\n");
        assert_eq!(
            std::fs::read_to_string(logs.paths().latency()).unwrap(),
            "1970-01-01T00:00:00Z send_text rid=ABCDEF12 success=1\n"
        );
    }

    #[test]
    fn a_log_call_never_waits_for_the_disk() {
        let dir = tempfile::tempdir().unwrap();
        let logs = Logs::new(LogPaths::new(dir.path()), ManualClock::new(0), false);
        let gate = std::sync::Arc::new(std::sync::Barrier::new(2));
        let g = gate.clone();
        logs.writer.run(move || {
            g.wait();
        }); // the writer is now stuck until the barrier
        let t0 = std::time::Instant::now();
        logs.ws(Severity::Info, "queued");
        assert!(t0.elapsed() < std::time::Duration::from_millis(50));
        assert!(!logs.paths().websocket().exists(), "not written on the caller's thread");
        gate.wait();
        logs.flush();
        assert!(std::fs::read_to_string(logs.paths().websocket()).unwrap().contains("queued"));
    }

    #[test]
    fn debug_never_writes_a_file() {
        let dir = tempfile::tempdir().unwrap();
        let logs = Logs::new(LogPaths::new(dir.path()), ManualClock::new(0), false);
        logs.debug("ignored type=request_content");
        logs.flush();
        assert!(!logs.paths().websocket().exists());
    }
}
