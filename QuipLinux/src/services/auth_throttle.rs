//! Per-host failure throttle for the WebSocket auth path.
//!
//! Mirror of `QuipMac/Services/AuthThrottle.swift`. Used on the direct LAN
//! connection path; the Cloudflare-tunnel path proxies all requests through
//! 127.0.0.1, so per-IP lockout is useless there — Cloudflare's edge handles
//! that side's DDoS / brute-force concerns.
//!
//! Policy:
//!   - Each failed PIN attempt adds `PER_FAIL_DELAY_MS` to the next response,
//!     capped at `MAX_DELAY_MS`.
//!   - After `MAX_FAILS_BEFORE_LOCKOUT` consecutive failures, the host is
//!     locked out for `LOCKOUT_DURATION`. Auth attempts during a lockout are
//!     rejected without a PIN check.
//!   - A successful auth resets the per-host counter.
//!   - Idle entries (>1h, no active lockout) are GC'd on every check.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const MAX_FAILS_BEFORE_LOCKOUT: u32 = 10;
pub const PER_FAIL_DELAY_MS: u64 = 200;
pub const MAX_DELAY_MS: u64 = 2_000;
pub const LOCKOUT_DURATION: Duration = Duration::from_secs(15 * 60);
pub const STALE_ENTRY_AGE: Duration = Duration::from_secs(3_600);

#[derive(Debug, PartialEq, Eq)]
pub enum AuthDecision {
    /// Accept the auth attempt; sleep this long before responding.
    Proceed { delay_ms: u64 },
    /// Reject without checking the PIN; this much time left on the lockout.
    Locked { remaining: Duration },
}

#[derive(Default)]
pub struct AuthThrottle {
    state: Mutex<HashMap<IpAddr, Entry>>,
    /// Test hook — `None` in production means use real wall-clock time.
    /// When set, all reads of "now" return this Instant. Tests advance it
    /// directly via `advance_clock` to avoid sleeping in unit tests.
    test_clock: Mutex<Option<Instant>>,
}

#[derive(Debug)]
struct Entry {
    fails: u32,
    lockout_until: Option<Instant>,
    last_attempt: Instant,
}

impl AuthThrottle {
    pub fn new() -> Self {
        Self::default()
    }

    fn now(&self) -> Instant {
        match *self.test_clock.lock().unwrap() {
            Some(t) => t,
            None => Instant::now(),
        }
    }

    /// Decide whether to allow this auth attempt and how long to delay the
    /// response. Idempotent — calling `check` doesn't itself record a failure.
    pub fn check(&self, ip: IpAddr) -> AuthDecision {
        let now = self.now();
        let mut state = self.state.lock().unwrap();
        Self::gc_locked(&mut state, now);

        let entry = state.entry(ip).or_insert_with(|| Entry {
            fails: 0,
            lockout_until: None,
            last_attempt: now,
        });

        if let Some(until) = entry.lockout_until {
            if until > now {
                return AuthDecision::Locked {
                    remaining: until - now,
                };
            }
            // Lockout expired — reset.
            entry.lockout_until = None;
            entry.fails = 0;
        }

        let delay = (entry.fails as u64 * PER_FAIL_DELAY_MS).min(MAX_DELAY_MS);
        AuthDecision::Proceed { delay_ms: delay }
    }

    pub fn record_failure(&self, ip: IpAddr) {
        let now = self.now();
        let mut state = self.state.lock().unwrap();
        let entry = state.entry(ip).or_insert_with(|| Entry {
            fails: 0,
            lockout_until: None,
            last_attempt: now,
        });
        entry.fails += 1;
        entry.last_attempt = now;
        if entry.fails >= MAX_FAILS_BEFORE_LOCKOUT {
            entry.lockout_until = Some(now + LOCKOUT_DURATION);
        }
    }

    pub fn record_success(&self, ip: IpAddr) {
        self.state.lock().unwrap().remove(&ip);
    }

    fn gc_locked(state: &mut HashMap<IpAddr, Entry>, now: Instant) {
        state.retain(|_, entry| {
            if let Some(until) = entry.lockout_until {
                if until > now {
                    return true;
                }
            }
            now.duration_since(entry.last_attempt) < STALE_ENTRY_AGE
        });
    }

    // ------------- test hooks -------------

    #[cfg(test)]
    fn set_clock(&self, t: Instant) {
        *self.test_clock.lock().unwrap() = Some(t);
    }

    #[cfg(test)]
    fn advance_clock(&self, d: Duration) {
        let mut g = self.test_clock.lock().unwrap();
        let next = match *g {
            Some(t) => t + d,
            None => Instant::now() + d,
        };
        *g = Some(next);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    fn fixed_now() -> Instant {
        // Pinning to a known instant avoids drift during the test run.
        Instant::now()
    }

    #[test]
    fn fresh_host_proceeds_with_zero_delay() {
        let t = AuthThrottle::new();
        t.set_clock(fixed_now());
        assert_eq!(
            t.check(ip("192.168.1.10")),
            AuthDecision::Proceed { delay_ms: 0 }
        );
    }

    #[test]
    fn failures_increase_delay_linearly() {
        let t = AuthThrottle::new();
        t.set_clock(fixed_now());
        let host = ip("192.168.1.10");

        t.record_failure(host);
        assert_eq!(t.check(host), AuthDecision::Proceed { delay_ms: 200 });
        t.record_failure(host);
        assert_eq!(t.check(host), AuthDecision::Proceed { delay_ms: 400 });
        t.record_failure(host);
        assert_eq!(t.check(host), AuthDecision::Proceed { delay_ms: 600 });
    }

    #[test]
    fn delay_is_capped() {
        let t = AuthThrottle::new();
        t.set_clock(fixed_now());
        let host = ip("192.168.1.10");
        // Many failures, but check between recording and the lockout-trip.
        for _ in 0..9 {
            t.record_failure(host);
        }
        // 9 fails × 200 = 1800 (under cap)
        assert_eq!(t.check(host), AuthDecision::Proceed { delay_ms: 1800 });
    }

    #[test]
    fn lockout_triggers_after_max_fails() {
        let t = AuthThrottle::new();
        t.set_clock(fixed_now());
        let host = ip("192.168.1.10");

        for _ in 0..9 {
            t.record_failure(host);
        }
        if matches!(t.check(host), AuthDecision::Locked { .. }) {
            panic!("should not be locked after 9 fails");
        }

        t.record_failure(host);
        match t.check(host) {
            AuthDecision::Locked { remaining } => {
                assert!(remaining <= LOCKOUT_DURATION);
                assert!(remaining > LOCKOUT_DURATION - Duration::from_secs(1));
            }
            other => panic!("should be locked, got {other:?}"),
        }
    }

    #[test]
    fn lockout_expires_and_counter_resets() {
        let t = AuthThrottle::new();
        t.set_clock(fixed_now());
        let host = ip("192.168.1.10");
        for _ in 0..10 {
            t.record_failure(host);
        }
        assert!(matches!(t.check(host), AuthDecision::Locked { .. }));

        // Advance past the lockout.
        t.advance_clock(LOCKOUT_DURATION + Duration::from_secs(1));
        assert_eq!(t.check(host), AuthDecision::Proceed { delay_ms: 0 });
    }

    #[test]
    fn lockout_is_per_host() {
        let t = AuthThrottle::new();
        t.set_clock(fixed_now());
        let attacker = ip("10.0.0.1");
        for _ in 0..10 {
            t.record_failure(attacker);
        }
        assert!(matches!(t.check(attacker), AuthDecision::Locked { .. }));
        assert_eq!(
            t.check(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2))),
            AuthDecision::Proceed { delay_ms: 0 }
        );
    }

    #[test]
    fn success_clears_fail_counter() {
        let t = AuthThrottle::new();
        t.set_clock(fixed_now());
        let host = ip("192.168.1.10");
        for _ in 0..5 {
            t.record_failure(host);
        }
        assert_eq!(t.check(host), AuthDecision::Proceed { delay_ms: 1000 });

        t.record_success(host);
        assert_eq!(t.check(host), AuthDecision::Proceed { delay_ms: 0 });
    }

    #[test]
    fn stale_entries_gc_after_an_hour() {
        let t = AuthThrottle::new();
        t.set_clock(fixed_now());
        let host = ip("192.168.1.10");
        t.record_failure(host);
        t.record_failure(host);
        assert_eq!(t.check(host), AuthDecision::Proceed { delay_ms: 400 });

        t.advance_clock(STALE_ENTRY_AGE + Duration::from_secs(1));
        assert_eq!(t.check(host), AuthDecision::Proceed { delay_ms: 0 });
    }

    #[test]
    fn lockout_holds_through_short_idle() {
        let t = AuthThrottle::new();
        t.set_clock(fixed_now());
        let host = ip("192.168.1.10");
        for _ in 0..10 {
            t.record_failure(host);
        }
        // Advance halfway into the lockout — it must still be active.
        t.advance_clock(LOCKOUT_DURATION / 2);
        assert!(matches!(t.check(host), AuthDecision::Locked { .. }));
    }
}
