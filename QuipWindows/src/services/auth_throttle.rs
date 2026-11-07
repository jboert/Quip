//! Per-host failure throttle for the auth path.
//!
//! Port of `QuipMac/Services/AuthThrottle.swift` (QuipLinux's
//! `auth_throttle.rs` has the same numbers). The Mac keys on the endpoint
//! with its port stripped, one exact address per bucket; this keys on
//! `sender_key`, which also folds IPv4-mapped IPv6 into IPv4 and an IPv6
//! address into its /64, so a peer cannot get fresh PIN guesses by rotating
//! through the 2^64 addresses its own network gives it:
//! - each failed PIN adds `PER_FAIL_DELAY_MS` to the next answer, capped at
//!   `MAX_DELAY_MS`;
//! - `MAX_FAILS_BEFORE_LOCKOUT` failures lock the host out for
//!   `LOCKOUT_DURATION`, during which auth is refused without a PIN check;
//! - success clears the host; idle entries (> 1 h, no lockout) are dropped on
//!   every check.
//!
//! There is no lockout across all senders: one would let any LAN peer lock
//! the owner's phone out by guessing wrong ten times.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv6Addr};
use std::sync::Mutex;
use std::time::Duration;

use super::clock::SharedClock;

pub const MAX_FAILS_BEFORE_LOCKOUT: u32 = 10;
pub const PER_FAIL_DELAY_MS: u64 = 200;
pub const MAX_DELAY_MS: u64 = 2_000;
pub const LOCKOUT_DURATION: Duration = Duration::from_secs(15 * 60);
pub const STALE_ENTRY_AGE: Duration = Duration::from_secs(3_600);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Check the PIN; answer after this long.
    Proceed { delay_ms: u64 },
    /// Refuse without a PIN check; this long left on the lockout.
    Locked { remaining: Duration },
}

/// One auth attempt, decided atomically per host (`attempt`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Attempt {
    /// Refused without looking at the PIN.
    Locked { remaining: Duration },
    /// Right PIN; the host's record is cleared.
    Accepted,
    /// Wrong PIN, recorded; answer after `delay_ms` (0 when this failure
    /// started the lockout, as on the Mac).
    Rejected { delay_ms: u64 },
}

#[derive(Debug, Clone)]
struct Entry {
    fails: u32,
    lockout_until: Option<Duration>,
    last_attempt: Duration,
}

pub struct AuthThrottle {
    entries: Mutex<HashMap<String, Entry>>,
    clock: SharedClock,
}

impl AuthThrottle {
    pub fn new(clock: SharedClock) -> Self {
        Self { entries: Mutex::new(HashMap::new()), clock }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Entry>> {
        self.entries.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Idempotent: does not record anything.
    pub fn check(&self, host: &str) -> Decision {
        let now = self.clock.monotonic();
        let mut entries = self.lock();
        Self::gc(&mut entries, now);
        let entry =
            entries.entry(host.to_string()).or_insert(Entry { fails: 0, lockout_until: None, last_attempt: now });
        if let Some(until) = entry.lockout_until {
            if until > now {
                return Decision::Locked { remaining: until - now };
            }
            // Lockout expired: reset.
            entry.fails = 0;
            entry.lockout_until = None;
        }
        let delay = (u64::from(entry.fails) * PER_FAIL_DELAY_MS).min(MAX_DELAY_MS);
        Decision::Proceed { delay_ms: delay }
    }

    /// Check, compare and record under ONE lock, so two sockets from the same
    /// host racing their PINs in cannot both pass a check that only one
    /// should (the 10th failure locks out the 11th attempt, however they
    /// interleave). `correct` is whether the PIN matched.
    pub fn attempt(&self, host: &str, correct: bool) -> Attempt {
        let now = self.clock.monotonic();
        let mut entries = self.lock();
        Self::gc(&mut entries, now);
        let entry =
            entries.entry(host.to_string()).or_insert(Entry { fails: 0, lockout_until: None, last_attempt: now });
        if let Some(until) = entry.lockout_until {
            if until > now {
                return Attempt::Locked { remaining: until - now };
            }
            entry.fails = 0;
            entry.lockout_until = None;
        }
        if correct {
            entries.remove(host);
            return Attempt::Accepted;
        }
        entry.fails += 1;
        entry.last_attempt = now;
        if entry.fails >= MAX_FAILS_BEFORE_LOCKOUT {
            entry.lockout_until = Some(now + LOCKOUT_DURATION);
            return Attempt::Rejected { delay_ms: 0 };
        }
        Attempt::Rejected { delay_ms: (u64::from(entry.fails) * PER_FAIL_DELAY_MS).min(MAX_DELAY_MS) }
    }

    pub fn record_failure(&self, host: &str) {
        let now = self.clock.monotonic();
        let mut entries = self.lock();
        let entry =
            entries.entry(host.to_string()).or_insert(Entry { fails: 0, lockout_until: None, last_attempt: now });
        entry.fails += 1;
        entry.last_attempt = now;
        if entry.fails >= MAX_FAILS_BEFORE_LOCKOUT {
            entry.lockout_until = Some(now + LOCKOUT_DURATION);
        }
    }

    pub fn record_success(&self, host: &str) {
        self.lock().remove(host);
    }

    fn gc(entries: &mut HashMap<String, Entry>, now: Duration) {
        entries.retain(|_, e| {
            if let Some(until) = e.lockout_until {
                if until > now {
                    return true;
                }
            }
            now.saturating_sub(e.last_attempt) < STALE_ENTRY_AGE
        });
    }

    /// The bucket a peer's attempts (and its pre-auth sockets) count in. The
    /// port is ignored, as on the Mac (`AuthThrottle.host(from:)`), so many
    /// ports from one machine share a bucket. An IPv4-mapped IPv6 address
    /// (`::ffff:192.0.2.1`, what a dual-stack listener reports for an IPv4
    /// peer) is its IPv4 address. Any other IPv6 address counts as its /64
    /// (`2001:db8:1:2::/64`): one network hands a host a whole /64, so
    /// exact-address keys would give it unlimited buckets.
    pub fn sender_key(ip: IpAddr) -> String {
        match ip.to_canonical() {
            IpAddr::V4(v4) => v4.to_string(),
            IpAddr::V6(v6) => {
                let s = v6.segments();
                format!("{}/64", Ipv6Addr::new(s[0], s[1], s[2], s[3], 0, 0, 0, 0))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    //! `QuipMac/Tests/AuthThrottleTests.swift`.
    #![allow(non_snake_case)]
    use super::*;
    use crate::services::clock::ManualClock;
    use std::sync::Arc;

    fn make() -> (AuthThrottle, Arc<ManualClock>) {
        let c = ManualClock::new(0);
        (AuthThrottle::new(c.clone()), c)
    }

    const H: &str = "192.168.1.10";

    #[test]
    fn test_freshHostProceedsWithZeroDelay() {
        let (t, _) = make();
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 0 });
    }

    #[test]
    fn test_failuresIncreaseTheNextDelayLinearly() {
        let (t, _) = make();
        t.record_failure(H);
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 200 });
        t.record_failure(H);
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 400 });
        t.record_failure(H);
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 600 });
    }

    #[test]
    fn test_delayIsCappedAtMaxDelayMs() {
        let (t, _) = make();
        for _ in 0..20 {
            t.record_failure(H);
        }
        assert!(matches!(t.check(H), Decision::Locked { .. }));
    }

    /// The cap itself is only reachable below the lockout when the numbers
    /// change; check the arithmetic directly so a broken `min` is caught.
    #[test]
    fn delay_cap_arithmetic() {
        let (t, _) = make();
        for _ in 0..9 {
            t.record_failure(H);
        }
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 1800 });
        const { assert!(9 * PER_FAIL_DELAY_MS <= MAX_DELAY_MS) };
        assert_eq!(MAX_DELAY_MS, 2000);
    }

    #[test]
    fn test_lockoutTriggersAfterMaxFails() {
        let (t, _) = make();
        for _ in 0..9 {
            t.record_failure(H);
        }
        assert!(matches!(t.check(H), Decision::Proceed { .. }), "not locked after 9");
        t.record_failure(H);
        let Decision::Locked { remaining } = t.check(H) else { panic!("locked after 10") };
        assert!(remaining > Duration::from_secs(14 * 60));
        assert!(remaining <= Duration::from_secs(15 * 60));
    }

    #[test]
    fn test_lockoutExpiresAndCounterResets() {
        let (t, c) = make();
        for _ in 0..10 {
            t.record_failure(H);
        }
        assert!(matches!(t.check(H), Decision::Locked { .. }));
        c.advance(Duration::from_secs(15 * 60 + 1));
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 0 });
    }

    #[test]
    fn test_lockoutIsPerHost() {
        let (t, _) = make();
        for _ in 0..10 {
            t.record_failure("10.0.0.1");
        }
        assert!(matches!(t.check("10.0.0.1"), Decision::Locked { .. }));
        assert_eq!(t.check("10.0.0.2"), Decision::Proceed { delay_ms: 0 });
    }

    #[test]
    fn test_successClearsTheFailCounter() {
        let (t, _) = make();
        for _ in 0..5 {
            t.record_failure(H);
        }
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 1000 });
        t.record_success(H);
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 0 });
    }

    #[test]
    fn test_staleEntriesGetGCdAfterAnHour() {
        let (t, c) = make();
        t.record_failure(H);
        t.record_failure(H);
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 400 });
        c.advance(Duration::from_secs(3601));
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 0 });
    }

    #[test]
    fn entries_younger_than_an_hour_survive_gc() {
        let (t, c) = make();
        t.record_failure(H);
        c.advance(Duration::from_secs(3599));
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 200 });
    }

    #[test]
    fn test_lockoutHoldsThroughShortIdle() {
        let (t, c) = make();
        for _ in 0..10 {
            t.record_failure(H);
        }
        c.advance(Duration::from_secs(7 * 60 + 30));
        assert!(matches!(t.check(H), Decision::Locked { .. }));
    }

    #[test]
    fn lockout_survives_gc_past_an_hour_of_idle_only_while_active() {
        let (t, c) = make();
        for _ in 0..10 {
            t.record_failure(H);
        }
        c.advance(Duration::from_secs(14 * 60));
        assert!(matches!(t.check(H), Decision::Locked { .. }));
    }

    #[test]
    fn attempt_matches_check_then_record() {
        let (t, _) = make();
        let delays: Vec<Attempt> = (0..10).map(|_| t.attempt(H, false)).collect();
        let want: Vec<Attempt> = [200, 400, 600, 800, 1000, 1200, 1400, 1600, 1800, 0]
            .into_iter()
            .map(|d| Attempt::Rejected { delay_ms: d })
            .collect();
        assert_eq!(delays, want);
        assert_eq!(t.attempt(H, true), Attempt::Locked { remaining: LOCKOUT_DURATION }, "the right PIN is refused");
        let (t, _) = make();
        t.attempt(H, false);
        assert_eq!(t.attempt(H, true), Attempt::Accepted);
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 0 }, "success clears the host");
    }

    #[test]
    fn attempt_after_the_lockout_expires_starts_fresh() {
        let (t, c) = make();
        for _ in 0..10 {
            t.attempt(H, false);
        }
        c.advance(Duration::from_secs(60));
        assert_eq!(t.attempt(H, false), Attempt::Locked { remaining: LOCKOUT_DURATION - Duration::from_secs(60) });
        c.advance(LOCKOUT_DURATION - Duration::from_secs(60));
        assert_eq!(t.attempt(H, false), Attempt::Rejected { delay_ms: 200 }, "ends exactly at 15 min");
    }

    /// Fifty sockets from one host fire wrong PINs at once: exactly ten get
    /// a PIN check, however the threads interleave.
    #[test]
    fn racing_attempts_from_one_host_never_exceed_the_lockout() {
        let (t, _) = make();
        let t = Arc::new(t);
        let gate = Arc::new(std::sync::Barrier::new(50));
        let hs: Vec<_> = (0..50)
            .map(|_| {
                let (t, g) = (t.clone(), gate.clone());
                std::thread::spawn(move || {
                    g.wait();
                    t.attempt(H, false)
                })
            })
            .collect();
        let checked =
            hs.into_iter().map(|h| h.join().unwrap()).filter(|a| matches!(a, Attempt::Rejected { .. })).count();
        assert_eq!(checked, MAX_FAILS_BEFORE_LOCKOUT as usize);
    }

    fn key(s: &str) -> String {
        AuthThrottle::sender_key(s.parse().unwrap())
    }

    #[test]
    fn sender_key_is_the_ipv4_address() {
        assert_eq!(key("192.168.1.10"), "192.168.1.10");
        assert_ne!(key("192.168.1.10"), key("192.168.1.11"), "each IPv4 address is its own sender");
    }

    #[test]
    fn sender_key_folds_ipv4_mapped_ipv6_into_ipv4() {
        assert_eq!(key("::ffff:192.0.2.1"), "192.0.2.1");
        assert_eq!(key("::ffff:192.0.2.1"), key("192.0.2.1"));
    }

    #[test]
    fn sender_key_buckets_ipv6_by_slash_64() {
        assert_eq!(key("2001:db8:1:2:aaaa:bbbb:cccc:dddd"), "2001:db8:1:2::/64");
        assert_eq!(key("2001:db8:1:2::1"), key("2001:db8:1:2:ffff:ffff:ffff:ffff"));
        assert_ne!(key("2001:db8:1:2::1"), key("2001:db8:1:3::1"), "the next /64 is another sender");
        assert_ne!(key("2001:db8:1:2::1"), key("2001:db9:1:2::1"));
        assert_eq!(key("::1"), "::/64");
    }

    #[test]
    fn two_addresses_in_one_slash_64_share_a_lockout() {
        let (t, _) = make();
        let a = key("2001:db8:1:2::a");
        for i in 0..MAX_FAILS_BEFORE_LOCKOUT {
            let rotating = key(&format!("2001:db8:1:2::{:x}", 0x100 + i));
            t.attempt(&rotating, false);
        }
        assert!(matches!(t.attempt(&a, true), Attempt::Locked { .. }), "right PIN refused while locked");
        assert_eq!(t.check(&key("2001:db8:1:3::a")), Decision::Proceed { delay_ms: 0 }, "other /64 unaffected");
    }

    #[test]
    fn mapped_and_plain_ipv4_share_a_lockout() {
        let (t, _) = make();
        for _ in 0..MAX_FAILS_BEFORE_LOCKOUT {
            t.attempt(&key("::ffff:192.0.2.1"), false);
        }
        assert!(matches!(t.check(&key("192.0.2.1")), Decision::Locked { .. }));
        assert_eq!(t.check(&key("192.0.2.2")), Decision::Proceed { delay_ms: 0 }, "no lockout across senders");
    }

    #[test]
    fn lockout_ends_exactly_at_fifteen_minutes() {
        let (t, c) = make();
        for _ in 0..10 {
            t.record_failure(H);
        }
        c.advance(Duration::from_secs(5 * 60));
        assert_eq!(t.check(H), Decision::Locked { remaining: Duration::from_secs(10 * 60) });
        c.advance(Duration::from_secs(10 * 60));
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 0 }, "Mac: locked only while until > now");
    }

    #[test]
    fn idle_entry_is_dropped_at_exactly_an_hour() {
        let (t, c) = make();
        t.record_failure(H);
        c.advance(Duration::from_secs(3600));
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 0 });
    }
}
