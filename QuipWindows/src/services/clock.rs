//! Injectable time. Every rule that depends on "now" (auth lockout, dedupe
//! TTL, heartbeat timing, log timestamps) reads it through `Clock`, so tests
//! drive time with an assignment instead of sleeping (the Mac's
//! `AuthThrottle(now:)` / `MessageDedupeTable(clock:)` pattern).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub trait Clock: Send + Sync {
    /// Monotonic time since an arbitrary origin.
    fn monotonic(&self) -> Duration;
    /// Wall-clock seconds since 1970 (heartbeat `ts`, log timestamps).
    fn unix_seconds(&self) -> f64;
}

pub type SharedClock = Arc<dyn Clock>;

/// The real clock.
pub struct SystemClock {
    origin: Instant,
}

impl SystemClock {
    pub fn shared() -> SharedClock {
        Arc::new(SystemClock { origin: Instant::now() })
    }
}

impl Clock for SystemClock {
    fn monotonic(&self) -> Duration {
        self.origin.elapsed()
    }

    fn unix_seconds(&self) -> f64 {
        SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
    }
}

/// A clock tests move by hand. Both readings advance together.
#[derive(Default)]
pub struct ManualClock {
    millis: AtomicU64,
    unix_base_millis: AtomicU64,
}

impl ManualClock {
    pub fn new(unix_seconds: u64) -> Arc<Self> {
        let c = ManualClock::default();
        c.unix_base_millis.store(unix_seconds * 1000, Ordering::SeqCst);
        Arc::new(c)
    }

    pub fn advance(&self, by: Duration) {
        self.millis.fetch_add(by.as_millis() as u64, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn monotonic(&self) -> Duration {
        Duration::from_millis(self.millis.load(Ordering::SeqCst))
    }

    fn unix_seconds(&self) -> f64 {
        let ms = self.unix_base_millis.load(Ordering::SeqCst) + self.millis.load(Ordering::SeqCst);
        ms as f64 / 1000.0
    }
}

/// `Date().ISO8601Format()` on the Mac: `2026-11-06T12:34:56Z`, UTC, whole
/// seconds. Hand-rolled (days-to-civil, Howard Hinnant's algorithm) to avoid a
/// date crate for one format.
pub fn iso8601(unix_seconds: f64) -> String {
    let secs = if unix_seconds.is_finite() && unix_seconds > 0.0 { unix_seconds as i64 } else { 0 };
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso8601_known_instants() {
        assert_eq!(iso8601(0.0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(1_800_000_000.0), "2027-01-15T08:00:00Z");
        assert_eq!(iso8601(951_782_400.0), "2000-02-29T00:00:00Z", "leap day");
        assert_eq!(iso8601(1_709_164_799.9), "2024-02-28T23:59:59Z");
        assert_eq!(iso8601(4_102_444_800.0), "2100-01-01T00:00:00Z");
    }

    #[test]
    fn iso8601_garbage_is_the_epoch_not_a_panic() {
        assert_eq!(iso8601(f64::NAN), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(-5.0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn manual_clock_moves_both_readings() {
        let c = ManualClock::new(100);
        c.advance(Duration::from_millis(1500));
        assert_eq!(c.monotonic(), Duration::from_millis(1500));
        assert_eq!(c.unix_seconds(), 101.5);
    }

    #[test]
    fn more_calendar_edges() {
        assert_eq!(iso8601(5_097_600.0), "1970-03-01T00:00:00Z");
        assert_eq!(iso8601(946_684_799.0), "1999-12-31T23:59:59Z");
        assert_eq!(iso8601(13_574_563_200.0), "2400-02-29T00:00:00Z");
        assert_eq!(iso8601(1_735_689_600.0 + 3_723.0), "2025-01-01T01:02:03Z");
    }

    #[test]
    fn system_clock_is_real() {
        let c = SystemClock::shared();
        assert!(c.unix_seconds() > 1.7e9);
        let a = c.monotonic();
        std::thread::sleep(Duration::from_millis(5));
        assert!(c.monotonic() > a);
    }
}
