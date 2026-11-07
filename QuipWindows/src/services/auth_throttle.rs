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
/// The longest a wrong PIN waits because of its network's failures
/// (`Sender::network`). Reached after 150 failures in one network.
pub const MAX_NETWORK_DELAY_MS: u64 = 30_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Check the PIN; answer after this long.
    Proceed { delay_ms: u64 },
    /// Refuse without a PIN check; this long left on the lockout.
    Locked { remaining: Duration },
}

/// One auth attempt, decided atomically per sender (`attempt`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Attempt {
    /// Refused without looking at the PIN.
    Locked { remaining: Duration },
    /// Right PIN; the address's record is cleared.
    Accepted,
    /// Wrong PIN, recorded; answer after `delay_ms`.
    Rejected { delay_ms: u64 },
}

/// Where an attempt came from, without the port (as on the Mac,
/// `AuthThrottle.host(from:)`, so many ports from one machine are one
/// sender).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sender {
    /// The exact address. It keys the lockout and the pre-auth socket cap,
    /// as on the Mac, so one device cannot lock out or crowd out another
    /// device on its network. An IPv4-mapped IPv6 address
    /// (`::ffff:192.0.2.1`, what a dual-stack listener reports for an IPv4
    /// peer) is its IPv4 address.
    pub address: String,
    /// The address's /64 for IPv6 (`2001:db8:1:2::/64`), the address itself
    /// for IPv4. One network hands a host a whole /64, so a peer rotating
    /// addresses gets a fresh lockout budget per address; the failures of a
    /// whole network only slow its wrong PINs down (`network_delay_ms`),
    /// never refuse a right one.
    pub network: String,
}

impl Sender {
    pub fn of(ip: IpAddr) -> Self {
        match ip.to_canonical() {
            IpAddr::V4(v4) => Self { address: v4.to_string(), network: v4.to_string() },
            IpAddr::V6(v6) => {
                let s = v6.segments();
                let net = Ipv6Addr::new(s[0], s[1], s[2], s[3], 0, 0, 0, 0);
                Self { address: v6.to_string(), network: format!("{net}/64") }
            }
        }
    }
}

#[derive(Debug, Clone)]
struct Entry {
    fails: u32,
    lockout_until: Option<Duration>,
    last_attempt: Duration,
}

#[derive(Debug, Clone)]
struct NetworkEntry {
    fails: u32,
    last_attempt: Duration,
}

#[derive(Default)]
struct Tables {
    by_address: HashMap<String, Entry>,
    by_network: HashMap<String, NetworkEntry>,
}

pub struct AuthThrottle {
    tables: Mutex<Tables>,
    clock: SharedClock,
}

/// The extra wait for a wrong PIN from a network with `fails` failures
/// (this one included). Nothing up to `MAX_FAILS_BEFORE_LOCKOUT`, which one
/// address can reach alone, so a single device sees the Mac's numbers; past
/// it, `PER_FAIL_DELAY_MS` per failure, capped at `MAX_NETWORK_DELAY_MS`.
pub fn network_delay_ms(fails: u32) -> u64 {
    if fails <= MAX_FAILS_BEFORE_LOCKOUT {
        return 0;
    }
    (u64::from(fails) * PER_FAIL_DELAY_MS).min(MAX_NETWORK_DELAY_MS)
}

impl AuthThrottle {
    pub fn new(clock: SharedClock) -> Self {
        Self { tables: Mutex::new(Tables::default()), clock }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Tables> {
        self.tables.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Idempotent: does not record anything. Per exact address (the Mac's
    /// `check(host:)`).
    pub fn check(&self, host: &str) -> Decision {
        let now = self.clock.monotonic();
        let mut t = self.lock();
        Self::gc(&mut t, now);
        let entry =
            t.by_address.entry(host.to_string()).or_insert(Entry { fails: 0, lockout_until: None, last_attempt: now });
        if let Some(until) = entry.lockout_until {
            if until > now {
                return Decision::Locked { remaining: until - now };
            }
            entry.fails = 0;
            entry.lockout_until = None;
        }
        let delay = (u64::from(entry.fails) * PER_FAIL_DELAY_MS).min(MAX_DELAY_MS);
        Decision::Proceed { delay_ms: delay }
    }

    /// Check, compare and record under ONE lock, so two sockets from the same
    /// address racing their PINs in cannot both pass a check that only one
    /// should (the 10th failure locks out the 11th attempt, however they
    /// interleave). `correct` is whether the PIN matched.
    ///
    /// Only the address's own lockout refuses; a right PIN from an address
    /// that is not locked is accepted at once, whatever its network did. A
    /// wrong PIN waits the longer of the address's delay (the Mac's 200 ms
    /// per failure up to 2 s, 0 on the failure that starts the lockout) and
    /// its network's (`network_delay_ms`). The delay is spent on the reply,
    /// holding the socket's pre-auth slot, so a peer rotating addresses
    /// gets no more than `MAX_UNAUTHENTICATED` guesses per that delay.
    /// A success does not clear the network count: the owner's phone
    /// pairing must not reset the delay of a neighbour guessing.
    pub fn attempt(&self, sender: &Sender, correct: bool) -> Attempt {
        let now = self.clock.monotonic();
        let mut t = self.lock();
        Self::gc(&mut t, now);
        let entry = t.by_address.entry(sender.address.clone()).or_insert(Entry {
            fails: 0,
            lockout_until: None,
            last_attempt: now,
        });
        if let Some(until) = entry.lockout_until {
            if until > now {
                return Attempt::Locked { remaining: until - now };
            }
            entry.fails = 0;
            entry.lockout_until = None;
        }
        if correct {
            t.by_address.remove(&sender.address);
            return Attempt::Accepted;
        }
        entry.fails += 1;
        entry.last_attempt = now;
        let own_delay = if entry.fails >= MAX_FAILS_BEFORE_LOCKOUT {
            entry.lockout_until = Some(now + LOCKOUT_DURATION);
            0
        } else {
            (u64::from(entry.fails) * PER_FAIL_DELAY_MS).min(MAX_DELAY_MS)
        };
        let net = t.by_network.entry(sender.network.clone()).or_insert(NetworkEntry { fails: 0, last_attempt: now });
        net.fails += 1;
        net.last_attempt = now;
        Attempt::Rejected { delay_ms: own_delay.max(network_delay_ms(net.fails)) }
    }

    pub fn record_failure(&self, host: &str) {
        let now = self.clock.monotonic();
        let mut t = self.lock();
        let entry =
            t.by_address.entry(host.to_string()).or_insert(Entry { fails: 0, lockout_until: None, last_attempt: now });
        entry.fails += 1;
        entry.last_attempt = now;
        if entry.fails >= MAX_FAILS_BEFORE_LOCKOUT {
            entry.lockout_until = Some(now + LOCKOUT_DURATION);
        }
    }

    pub fn record_success(&self, host: &str) {
        self.lock().by_address.remove(host);
    }

    fn gc(t: &mut Tables, now: Duration) {
        t.by_address.retain(|_, e| {
            if let Some(until) = e.lockout_until {
                if until > now {
                    return true;
                }
            }
            now.saturating_sub(e.last_attempt) < STALE_ENTRY_AGE
        });
        t.by_network.retain(|_, e| now.saturating_sub(e.last_attempt) < STALE_ENTRY_AGE);
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
        let h = sender(H);
        let delays: Vec<Attempt> = (0..10).map(|_| t.attempt(&h, false)).collect();
        let want: Vec<Attempt> = [200, 400, 600, 800, 1000, 1200, 1400, 1600, 1800, 0]
            .into_iter()
            .map(|d| Attempt::Rejected { delay_ms: d })
            .collect();
        assert_eq!(delays, want);
        assert_eq!(t.attempt(&h, true), Attempt::Locked { remaining: LOCKOUT_DURATION }, "the right PIN is refused");
        let (t, _) = make();
        t.attempt(&h, false);
        assert_eq!(t.attempt(&h, true), Attempt::Accepted);
        assert_eq!(t.check(H), Decision::Proceed { delay_ms: 0 }, "success clears the host");
    }

    #[test]
    fn attempt_after_the_lockout_expires_starts_fresh() {
        let (t, c) = make();
        let h = sender(H);
        for _ in 0..10 {
            t.attempt(&h, false);
        }
        c.advance(Duration::from_secs(60));
        assert_eq!(t.attempt(&h, false), Attempt::Locked { remaining: LOCKOUT_DURATION - Duration::from_secs(60) });
        c.advance(LOCKOUT_DURATION - Duration::from_secs(60));
        // The address starts fresh; its network remembers the 10 (an 11th).
        assert_eq!(t.attempt(&h, false), Attempt::Rejected { delay_ms: 2_200 }, "ends exactly at 15 min");
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
                    t.attempt(&sender(H), false)
                })
            })
            .collect();
        let checked =
            hs.into_iter().map(|h| h.join().unwrap()).filter(|a| matches!(a, Attempt::Rejected { .. })).count();
        assert_eq!(checked, MAX_FAILS_BEFORE_LOCKOUT as usize);
    }

    fn sender(s: &str) -> Sender {
        Sender::of(s.parse().unwrap())
    }

    #[test]
    fn sender_of_ipv4_is_the_address_twice() {
        assert_eq!(sender("192.168.1.10"), Sender { address: "192.168.1.10".into(), network: "192.168.1.10".into() });
        assert_ne!(sender("192.168.1.10"), sender("192.168.1.11"), "each IPv4 address is its own sender");
    }

    #[test]
    fn sender_of_folds_ipv4_mapped_ipv6_into_ipv4() {
        assert_eq!(sender("::ffff:192.0.2.1"), sender("192.0.2.1"));
        assert_eq!(sender("::ffff:192.0.2.1").address, "192.0.2.1");
    }

    #[test]
    fn sender_of_ipv6_is_the_exact_address_in_its_slash_64() {
        let s = sender("2001:db8:1:2:aaaa:bbbb:cccc:dddd");
        assert_eq!(s.address, "2001:db8:1:2:aaaa:bbbb:cccc:dddd");
        assert_eq!(s.network, "2001:db8:1:2::/64");
        assert_ne!(sender("2001:db8:1:2::1").address, sender("2001:db8:1:2::2").address);
        assert_eq!(sender("2001:db8:1:2::1").network, sender("2001:db8:1:2:ffff:ffff:ffff:ffff").network);
        assert_ne!(sender("2001:db8:1:2::1").network, sender("2001:db8:1:3::1").network, "the next /64");
        assert_ne!(sender("2001:db8:1:2::1").network, sender("2001:db9:1:2::1").network);
        assert_eq!(sender("::1"), Sender { address: "::1".into(), network: "::/64".into() });
    }

    #[test]
    fn network_delay_is_zero_within_one_addresss_budget_then_grows_to_the_cap() {
        assert_eq!(network_delay_ms(0), 0);
        assert_eq!(network_delay_ms(MAX_FAILS_BEFORE_LOCKOUT), 0);
        assert_eq!(network_delay_ms(11), 2_200);
        assert_eq!(network_delay_ms(12), 2_400);
        assert_eq!(network_delay_ms(149), 29_800);
        assert_eq!(network_delay_ms(150), 30_000);
        assert_eq!(network_delay_ms(151), MAX_NETWORK_DELAY_MS);
        assert_eq!(network_delay_ms(u32::MAX), MAX_NETWORK_DELAY_MS);
    }

    #[test]
    fn two_addresses_in_one_slash_64_do_not_share_a_lockout() {
        let (t, _) = make();
        let (a, b) = (sender("2001:db8:1:2::a"), sender("2001:db8:1:2::b"));
        for _ in 0..MAX_FAILS_BEFORE_LOCKOUT {
            t.attempt(&a, false);
        }
        assert!(matches!(t.attempt(&a, true), Attempt::Locked { .. }), "the guessing address is locked");
        assert_eq!(t.attempt(&b, true), Attempt::Accepted, "its neighbour still pairs with the right PIN");
        assert_eq!(t.check(&b.address), Decision::Proceed { delay_ms: 0 });
    }

    #[test]
    fn a_right_pin_is_accepted_however_slow_its_network_has_become() {
        let (t, _) = make();
        for i in 0..200u32 {
            t.attempt(&sender(&format!("2001:db8:1:2::{:x}", 0x1000 + i)), false);
        }
        let Attempt::Rejected { delay_ms } = t.attempt(&sender("2001:db8:1:2::ffff"), false) else { panic!() };
        assert_eq!(delay_ms, MAX_NETWORK_DELAY_MS, "the network is at the cap");
        assert_eq!(t.attempt(&sender("2001:db8:1:2::1"), true), Attempt::Accepted);
        let Attempt::Rejected { delay_ms } = t.attempt(&sender("2001:db8:1:2::ffff"), false) else { panic!() };
        assert_eq!(delay_ms, MAX_NETWORK_DELAY_MS, "a neighbour's success does not reset the network");
    }

    #[test]
    fn rotating_addresses_in_one_slash_64_get_a_growing_delay() {
        let (t, _) = make();
        let delays: Vec<u64> = (0..14u32)
            .map(|i| match t.attempt(&sender(&format!("2001:db8:1:2::{:x}", 0x100 + i)), false) {
                Attempt::Rejected { delay_ms } => delay_ms,
                other => panic!("{other:?}"),
            })
            .collect();
        assert_eq!(delays, [200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 2_200, 2_400, 2_600, 2_800]);
        let Attempt::Rejected { delay_ms } = t.attempt(&sender("2001:db8:1:3::1"), false) else { panic!() };
        assert_eq!(delay_ms, 200, "the next /64 is another network");
    }

    #[test]
    fn the_failure_that_locks_an_address_still_waits_its_networks_delay() {
        let (t, _) = make();
        for i in 0..MAX_FAILS_BEFORE_LOCKOUT {
            t.attempt(&sender(&format!("2001:db8:1:2::{:x}", 0x100 + i)), false);
        }
        let a = sender("2001:db8:1:2::a");
        let last: Vec<Attempt> = (0..MAX_FAILS_BEFORE_LOCKOUT).map(|_| t.attempt(&a, false)).collect();
        assert_eq!(last[MAX_FAILS_BEFORE_LOCKOUT as usize - 1], Attempt::Rejected { delay_ms: 4_000 });
        assert!(matches!(t.attempt(&a, false), Attempt::Locked { .. }));
    }

    #[test]
    fn network_counts_are_dropped_after_an_hour_idle() {
        let (t, c) = make();
        for i in 0..20u32 {
            t.attempt(&sender(&format!("2001:db8:1:2::{:x}", 0x100 + i)), false);
        }
        c.advance(Duration::from_secs(3599));
        assert_eq!(t.attempt(&sender("2001:db8:1:2::1"), false), Attempt::Rejected { delay_ms: 4_200 });
        c.advance(Duration::from_secs(3600));
        assert_eq!(t.attempt(&sender("2001:db8:1:2::2"), false), Attempt::Rejected { delay_ms: 200 });
    }

    #[test]
    fn mapped_and_plain_ipv4_share_a_lockout() {
        let (t, _) = make();
        for _ in 0..MAX_FAILS_BEFORE_LOCKOUT {
            t.attempt(&sender("::ffff:192.0.2.1"), false);
        }
        assert!(matches!(t.attempt(&sender("192.0.2.1"), true), Attempt::Locked { .. }));
        assert_eq!(t.attempt(&sender("192.0.2.2"), true), Attempt::Accepted, "no lockout across senders");
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
