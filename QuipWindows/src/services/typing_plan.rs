//! How text becomes `SendInput` batches (spec 5.4 steps 3-4), pure.
//!
//! - One `KEYEVENTF_UNICODE` down/up pair per UTF-16 code unit; a surrogate
//!   pair is two units, which Windows reassembles, so emoji arrive intact.
//! - At most `MAX_INPUTS_PER_BATCH` inputs per call (32 units).
//! - A batch never ends between the two halves of a surrogate pair, so a
//!   focus change caught between batches can never leave half an emoji.
//! - Before every batch the caller checks the target is still foreground; on
//!   failure it stops, and nothing more is sent. What already landed stays.

pub const MAX_INPUTS_PER_BATCH: usize = 64;
/// Two inputs (down + up) per code unit.
pub const MAX_UNITS_PER_BATCH: usize = MAX_INPUTS_PER_BATCH / 2;

/// One batch: the code units, and how many whole `char`s they finish.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    pub units: Vec<u16>,
    pub chars: usize,
}

pub fn batches(text: &str) -> Vec<Batch> {
    let mut out = Vec::new();
    let mut cur = Batch { units: Vec::new(), chars: 0 };
    for c in text.chars() {
        let mut buf = [0u16; 2];
        let enc = c.encode_utf16(&mut buf);
        if cur.units.len() + enc.len() > MAX_UNITS_PER_BATCH {
            out.push(std::mem::replace(&mut cur, Batch { units: Vec::new(), chars: 0 }));
        }
        cur.units.extend_from_slice(enc);
        cur.chars += 1;
    }
    if !cur.units.is_empty() {
        out.push(cur);
    }
    out
}

/// How a `run` ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Every batch landed; this many chars.
    Done(usize),
    /// The foreground check failed before a batch; this many chars had landed.
    FocusLost(usize),
    /// A batch was only partly inserted (Windows blocked the input, UIPI);
    /// this many WHOLE chars had landed, counting the partial batch.
    Blocked(usize),
}

/// Whole chars in the first `inserted` units of `units` (a lone high
/// surrogate at the cut does not count).
pub fn chars_in(units: &[u16], inserted: usize) -> usize {
    char::decode_utf16(units[..inserted.min(units.len())].iter().copied()).filter(Result::is_ok).count()
}

/// Run the batches: `still_foreground` before each, then `send`, which
/// returns how many units it inserted. A short insert stops at once: nothing
/// more is sent.
pub fn run(text: &str, mut still_foreground: impl FnMut() -> bool, mut send: impl FnMut(&[u16]) -> usize) -> Outcome {
    let mut typed = 0;
    for b in batches(text) {
        if !still_foreground() {
            return Outcome::FocusLost(typed);
        }
        let inserted = send(&b.units);
        if inserted < b.units.len() {
            return Outcome::Blocked(typed + chars_in(&b.units, inserted));
        }
        typed += b.chars;
    }
    Outcome::Done(typed)
}

#[cfg(test)]
mod tests {
    //! Shape of `KeystrokeInjectorWriteExpressionTests` (text in, exact key
    //! stream out), with the spec 10.3 Windows cases.
    use super::*;

    #[test]
    fn empty_text_is_no_batches() {
        assert!(batches("").is_empty());
        assert_eq!(run("", || false, |_| panic!("nothing to send")), Outcome::Done(0));
    }

    #[test]
    fn ascii_fits_32_units_per_batch() {
        let t = "a".repeat(70);
        let b = batches(&t);
        assert_eq!(b.iter().map(|x| x.units.len()).collect::<Vec<_>>(), [32, 32, 6]);
        assert!(b.iter().all(|x| x.units.len() * 2 <= MAX_INPUTS_PER_BATCH));
        assert_eq!(b.iter().map(|x| x.chars).sum::<usize>(), 70);
    }

    #[test]
    fn surrogate_pairs_are_two_units_and_never_split() {
        let t = format!("{}😀", "a".repeat(31)); // 31 + 2 units: the pair must move to batch 2
        let b = batches(&t);
        assert_eq!(b[0].units.len(), 31);
        assert_eq!(b[1].units, "😀".encode_utf16().collect::<Vec<_>>());
        assert_eq!(b[1].units.len(), 2);
        let all: Vec<u16> = b.iter().flat_map(|x| x.units.clone()).collect();
        assert_eq!(String::from_utf16(&all).unwrap(), t, "round-trips exactly");
    }

    #[test]
    fn exact_fit_stays_in_one_batch() {
        let t = format!("{}😀", "a".repeat(30));
        assert_eq!(batches(&t).len(), 1);
    }

    #[test]
    fn focus_is_checked_before_every_batch() {
        let t = "b".repeat(65);
        let mut checks = 0;
        let mut sent = 0;
        assert_eq!(
            run(
                &t,
                || {
                    checks += 1;
                    true
                },
                |u| {
                    sent += u.len();
                    u.len()
                }
            ),
            Outcome::Done(65)
        );
        assert_eq!(checks, 3);
        assert_eq!(sent, 65);
    }

    #[test]
    fn focus_lost_stops_and_reports_chars_typed() {
        let t = "c".repeat(100);
        let mut n = 0;
        let mut sent = 0;
        let r = run(
            &t,
            || {
                n += 1;
                n <= 2
            },
            |u| {
                sent += u.len();
                u.len()
            },
        );
        assert_eq!(r, Outcome::FocusLost(64));
        assert_eq!(sent, 64, "nothing after the failed check");
    }

    #[test]
    fn focus_lost_before_the_first_batch_types_nothing() {
        let mut sent = false;
        assert_eq!(
            run(
                "x",
                || false,
                |_| {
                    sent = true;
                    1
                }
            ),
            Outcome::FocusLost(0)
        );
        assert!(!sent);
    }

    #[test]
    fn non_bmp_text_counts_chars_not_units() {
        assert_eq!(run("😀😀", || true, |u| u.len()), Outcome::Done(2));
    }

    #[test]
    fn a_short_insert_stops_typing_and_counts_whole_chars() {
        let t = "d".repeat(100);
        let mut calls = 0;
        // The second batch only gets 5 of its 32 units in.
        let r = run(
            &t,
            || true,
            |u| {
                calls += 1;
                if calls == 2 {
                    5
                } else {
                    u.len()
                }
            },
        );
        assert_eq!(r, Outcome::Blocked(37));
        assert_eq!(calls, 2, "nothing is sent after a short insert");
    }

    #[test]
    fn a_fully_blocked_first_batch_types_nothing() {
        assert_eq!(run("abc", || true, |_| 0), Outcome::Blocked(0));
    }

    #[test]
    fn a_cut_between_surrogate_halves_counts_only_whole_chars() {
        let u: Vec<u16> = "a😀b".encode_utf16().collect();
        assert_eq!(chars_in(&u, 1), 1);
        assert_eq!(chars_in(&u, 2), 1, "half an emoji is not a char");
        assert_eq!(chars_in(&u, 3), 2);
        assert_eq!(chars_in(&u, 4), 3);
        assert_eq!(chars_in(&u, 99), 3);
    }
}
