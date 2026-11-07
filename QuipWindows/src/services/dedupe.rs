//! Idempotency table for phone messages carrying `messageId`
//! (`QuipMac/Services/MessageDedupeTable.swift`, wishlist §27): a fresh id is
//! recorded and processed; a repeat within the TTL is skipped; `nil` ids are
//! always processed (older phones). Insertion-ordered, oldest evicted first.
//!
//! Capacity is 256 here (spec 3.3, "keep the last 256 ids"); the Mac uses 100.
//! The 30 s TTL is the Mac's.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::time::Duration;

use super::clock::SharedClock;
use crate::protocol::types::WireUuid;

pub const DEFAULT_CAPACITY: usize = 256;
pub const DEFAULT_TTL: Duration = Duration::from_secs(30);

struct Inner {
    entries: VecDeque<(WireUuid, Duration)>,
    index: HashMap<WireUuid, Duration>,
}

pub struct DedupeTable {
    capacity: usize,
    ttl: Duration,
    clock: SharedClock,
    inner: Mutex<Inner>,
}

impl DedupeTable {
    pub fn new(clock: SharedClock) -> Self {
        Self::with(DEFAULT_CAPACITY, DEFAULT_TTL, clock)
    }

    pub fn with(capacity: usize, ttl: Duration, clock: SharedClock) -> Self {
        Self { capacity, ttl, clock, inner: Mutex::new(Inner { entries: VecDeque::new(), index: HashMap::new() }) }
    }

    /// True when `id` was seen recently (skip the side effect). Otherwise
    /// records it and returns false.
    pub fn check_and_record(&self, id: Option<WireUuid>) -> bool {
        let Some(id) = id else { return false };
        let now = self.clock.monotonic();
        let mut g = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        let inner = &mut *g;
        // Purge expired: insertion-ordered, so stop at the first fresh one.
        while let Some(&(old, at)) = inner.entries.front() {
            if now.saturating_sub(at) > self.ttl {
                inner.entries.pop_front();
                if inner.index.get(&old) == Some(&at) {
                    inner.index.remove(&old);
                }
            } else {
                break;
            }
        }
        if inner.index.contains_key(&id) {
            return true;
        }
        inner.entries.push_back((id, now));
        inner.index.insert(id, now);
        if inner.entries.len() > self.capacity {
            if let Some((evicted, at)) = inner.entries.pop_front() {
                if inner.index.get(&evicted) == Some(&at) {
                    inner.index.remove(&evicted);
                }
            }
        }
        false
    }

    pub fn len(&self) -> usize {
        self.inner.lock().map(|g| g.entries.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    //! `QuipMac/Tests/MessageDedupeTableTests.swift` plus the cap-256 case.
    #![allow(non_snake_case)]
    use super::*;
    use crate::services::clock::{ManualClock, SystemClock};
    use std::sync::Arc;

    fn id() -> Option<WireUuid> {
        Some(WireUuid::new_v4())
    }

    #[test]
    fn test_firstArrivalReturnsFalse_secondReturnsTrue() {
        let t = DedupeTable::new(SystemClock::shared());
        let i = id();
        assert!(!t.check_and_record(i));
        assert!(t.check_and_record(i));
    }

    #[test]
    fn test_distinctIds_areAllProcessed() {
        let t = DedupeTable::new(SystemClock::shared());
        for _ in 0..10 {
            assert!(!t.check_and_record(id()));
        }
    }

    #[test]
    fn test_nilId_alwaysProcessed() {
        let t = DedupeTable::new(SystemClock::shared());
        for _ in 0..3 {
            assert!(!t.check_and_record(None));
        }
        assert!(t.is_empty());
    }

    #[test]
    fn test_capacityEvictsOldest() {
        let t = DedupeTable::with(3, Duration::from_secs(30), SystemClock::shared());
        let (a, b, c, d) = (id(), id(), id(), id());
        assert!(!t.check_and_record(a));
        assert!(!t.check_and_record(b));
        assert!(!t.check_and_record(c));
        assert_eq!(t.len(), 3);
        assert!(!t.check_and_record(d));
        assert_eq!(t.len(), 3);
        assert!(t.check_and_record(b));
        assert!(t.check_and_record(c));
        assert!(t.check_and_record(d));
        assert!(!t.check_and_record(a), "evicted id no longer dedupes");
    }

    #[test]
    fn test_ttlExpiresOldEntries() {
        let clock = ManualClock::new(0);
        let t = DedupeTable::with(100, Duration::from_secs(30), clock.clone());
        let i = id();
        assert!(!t.check_and_record(i));
        assert!(t.check_and_record(i));
        clock.advance(Duration::from_secs(31));
        assert!(!t.check_and_record(i));
    }

    #[test]
    fn exactly_at_ttl_still_dedupes() {
        // Mac: `recordedAt < cutoff` (now - ttl) purges; at exactly ttl it stays.
        let clock = ManualClock::new(0);
        let t = DedupeTable::with(100, Duration::from_secs(30), clock.clone());
        let i = id();
        assert!(!t.check_and_record(i));
        clock.advance(Duration::from_secs(30));
        assert!(t.check_and_record(i));
    }

    #[test]
    fn test_ttlPurgePreservesFreshAndDropsStale() {
        let clock = ManualClock::new(0);
        let t = DedupeTable::with(100, Duration::from_secs(30), clock.clone());
        let stale = id();
        assert!(!t.check_and_record(stale));
        clock.advance(Duration::from_secs(25));
        let fresh = id();
        assert!(!t.check_and_record(fresh));
        clock.advance(Duration::from_secs(10));
        assert!(!t.check_and_record(stale));
        assert!(t.check_and_record(fresh));
    }

    #[test]
    fn test_threadSafetyUnderConcurrentInsert() {
        let t = Arc::new(DedupeTable::with(100_000, Duration::from_secs(30), SystemClock::shared()));
        let hs: Vec<_> = (0..8)
            .map(|_| {
                let t = t.clone();
                std::thread::spawn(move || {
                    for _ in 0..1000 {
                        t.check_and_record(id());
                    }
                })
            })
            .collect();
        for h in hs {
            h.join().unwrap();
        }
        assert_eq!(t.len(), 8000);
    }

    #[test]
    fn default_cap_is_256_oldest_evicted() {
        let t = DedupeTable::new(SystemClock::shared());
        let first = id();
        assert!(!t.check_and_record(first));
        for _ in 0..255 {
            assert!(!t.check_and_record(id()));
        }
        assert_eq!(t.len(), 256);
        assert!(t.check_and_record(first), "256th-oldest still held");
        // One more pushes `first` out.
        let mut ids = vec![];
        let probe = id();
        assert!(!t.check_and_record(probe));
        ids.push(probe);
        assert_eq!(t.len(), 256);
        assert!(!t.check_and_record(first), "the 257th id evicted the oldest");
    }

    #[test]
    fn is_empty_tracks_len() {
        let t = DedupeTable::new(SystemClock::shared());
        assert!(t.is_empty());
        t.check_and_record(id());
        assert!(!t.is_empty());
    }
}
