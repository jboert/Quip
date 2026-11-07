//! Wire ids for windows (spec 3.4).
//!
//! An HWND is reused by Windows after its window closes, so it is not an id by
//! itself. The id is `w-<hwnd hex>-<pid hex>-<order hex>`, where `order` is
//! the order in which this host first saw the (HWND, pid) pair alive. A pair
//! that stays listed keeps its id across polls; a pair that drops out of a
//! poll and comes back (or an HWND that comes back under another process) gets
//! a new id, so an id never moves to a different window.

use std::collections::HashMap;

#[derive(Debug, Default)]
pub struct WindowIdTable {
    live: HashMap<(u64, u32), String>,
    next_order: u64,
}

impl WindowIdTable {
    /// Ids for this poll's windows, in input order. Pairs not in `current`
    /// are forgotten.
    pub fn assign(&mut self, current: &[(u64, u32)]) -> Vec<String> {
        let mut next: HashMap<(u64, u32), String> = HashMap::with_capacity(current.len());
        let mut out = Vec::with_capacity(current.len());
        for &(hwnd, pid) in current {
            let id = if let Some(id) = next.get(&(hwnd, pid)) {
                id.clone()
            } else if let Some(id) = self.live.get(&(hwnd, pid)) {
                id.clone()
            } else {
                self.next_order += 1;
                format!("w-{hwnd:x}-{pid:x}-{:x}", self.next_order)
            };
            next.insert((hwnd, pid), id.clone());
            out.push(id);
        }
        self.live = next;
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_window_across_polls_keeps_its_id() {
        let mut t = WindowIdTable::default();
        let a = t.assign(&[(0x1a2b, 100), (0x3c4d, 200)]);
        let b = t.assign(&[(0x3c4d, 200), (0x1a2b, 100)]);
        assert_eq!(a[0], b[1]);
        assert_eq!(a[1], b[0]);
        assert_eq!(a[0], "w-1a2b-64-1");
    }

    #[test]
    fn hwnd_reused_by_a_new_process_gets_a_new_id() {
        let mut t = WindowIdTable::default();
        let a = t.assign(&[(0x10, 100)]);
        let b = t.assign(&[(0x10, 101)]);
        assert_ne!(a[0], b[0]);
    }

    #[test]
    fn hwnd_reused_by_the_same_process_after_a_gap_gets_a_new_id() {
        let mut t = WindowIdTable::default();
        let a = t.assign(&[(0x10, 100)]);
        t.assign(&[]);
        let b = t.assign(&[(0x10, 100)]);
        assert_ne!(a[0], b[0], "the window closed in between; the id must not move to its successor");
    }

    #[test]
    fn ids_are_unique_and_space_free() {
        let mut t = WindowIdTable::default();
        let ids = t.assign(&[(1, 1), (2, 1), (1, 2)]);
        let set: std::collections::HashSet<_> = ids.iter().collect();
        assert_eq!(set.len(), 3);
        assert!(ids.iter().all(|i| i.starts_with("w-") && !i.contains(' ')));
    }

    #[test]
    fn a_duplicate_pair_in_one_poll_shares_the_id() {
        let mut t = WindowIdTable::default();
        let ids = t.assign(&[(5, 5), (5, 5)]);
        assert_eq!(ids[0], ids[1]);
    }
}
