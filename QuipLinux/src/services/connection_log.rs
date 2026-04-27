use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

/// What kind of connection event was recorded. Mirrors Mac's
/// `ConnectionEvent.Kind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionEventKind {
    Connected,
    Disconnected,
    AuthSucceeded,
    AuthFailed,
    Failed,
}

impl ConnectionEventKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Connected => "connected",
            Self::Disconnected => "disconnected",
            Self::AuthSucceeded => "auth_succeeded",
            Self::AuthFailed => "auth_failed",
            Self::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ConnectionEvent {
    pub timestamp: SystemTime,
    pub kind: ConnectionEventKind,
    pub remote: String,
    pub detail: Option<String>,
}

/// In-memory ring buffer of recent WebSocket connection events. Mirrors
/// `QuipMac/Services/ConnectionLog.swift`. Cap is 20 entries — enough to see
/// the last few connect/disconnect/auth cycles without ballooning into MBs
/// when a flaky tunnel reconnects every few seconds.
#[derive(Default)]
pub struct ConnectionLog {
    inner: Mutex<VecDeque<ConnectionEvent>>,
}

impl ConnectionLog {
    pub const MAX_EVENTS: usize = 20;

    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(VecDeque::new()),
        })
    }

    pub fn record(&self, kind: ConnectionEventKind, remote: impl Into<String>, detail: Option<String>) {
        let event = ConnectionEvent {
            timestamp: SystemTime::now(),
            kind,
            remote: remote.into(),
            detail,
        };
        let mut buf = self.inner.lock().expect("connection_log poisoned");
        buf.push_front(event);
        while buf.len() > Self::MAX_EVENTS {
            buf.pop_back();
        }
    }

    pub fn snapshot(&self) -> Vec<ConnectionEvent> {
        self.inner
            .lock()
            .expect("connection_log poisoned")
            .iter()
            .cloned()
            .collect()
    }

    pub fn clear(&self) {
        self.inner.lock().expect("connection_log poisoned").clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_inserts_at_front() {
        let log = ConnectionLog::new();
        log.record(ConnectionEventKind::Connected, "1.2.3.4:5555", None);
        log.record(ConnectionEventKind::AuthSucceeded, "1.2.3.4:5555", None);
        let events = log.snapshot();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, ConnectionEventKind::AuthSucceeded);
        assert_eq!(events[1].kind, ConnectionEventKind::Connected);
    }

    #[test]
    fn caps_at_max_events() {
        let log = ConnectionLog::new();
        for i in 0..(ConnectionLog::MAX_EVENTS + 5) {
            log.record(ConnectionEventKind::Connected, format!("client-{i}"), None);
        }
        let events = log.snapshot();
        assert_eq!(events.len(), ConnectionLog::MAX_EVENTS);
        // Newest first — last recorded is at the head.
        assert_eq!(
            events[0].remote,
            format!("client-{}", ConnectionLog::MAX_EVENTS + 4)
        );
    }

    #[test]
    fn clear_empties_buffer() {
        let log = ConnectionLog::new();
        log.record(ConnectionEventKind::Connected, "x", None);
        log.clear();
        assert!(log.snapshot().is_empty());
    }
}
