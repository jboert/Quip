//! The pairing PIN (`QuipMac/Services/PINManager.swift`): 8 digits for new
//! PINs (GH #14: ~27 bits; with `AuthThrottle` brute force at one host takes
//! centuries). Any stored non-empty PIN is honoured; the phone sends whatever
//! the user typed and any length compares (spec 2).

use rand::Rng;

pub const PIN_DIGITS: usize = 8;

/// `PINManager.generateRandomPIN`: zero-padded, uniform over 0..10^8.
pub fn generate(rng: &mut impl Rng) -> String {
    let upper = 10u32.pow(PIN_DIGITS as u32);
    format!("{:0width$}", rng.random_range(0..upper), width = PIN_DIGITS)
}

/// A PIN worth keeping from settings: non-empty, digits only.
pub fn is_valid_stored(pin: &str) -> bool {
    !pin.is_empty() && pin.chars().all(|c| c.is_ascii_digit())
}

/// Compare without an early exit, so response timing does not reveal how many
/// leading digits matched. (The Mac compares with `==`; the throttle delay
/// dominates there, this costs nothing.)
pub fn matches(expected: &str, given: &str) -> bool {
    let (a, b) = (expected.as_bytes(), given.as_bytes());
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        diff |= usize::from(x ^ y);
    }
    diff == 0 && !expected.is_empty()
}

/// Length-only description, the only form a PIN may take in a log line
/// (`WebSocketServer.handleAuthMessage`: "Never log either PIN").
pub fn describe_for_log(pin: &str) -> String {
    format!("len={}", pin.chars().count())
}

#[cfg(test)]
mod tests {
    //! `QuipMac/Tests/PINStoreTests.swift` (generation half; the round-trip
    //! and corrupt-file cases live with the store in `settings.rs`).
    #![allow(non_snake_case)]
    use super::*;
    use rand::rngs::StdRng;
    use rand::SeedableRng;

    #[test]
    fn test_freshInstall_pinManager_generates8DigitPIN() {
        let mut rng = StdRng::seed_from_u64(1);
        for _ in 0..200 {
            let p = generate(&mut rng);
            assert_eq!(p.len(), 8);
            assert!(p.chars().all(|c| c.is_ascii_digit()));
        }
    }

    #[test]
    fn leading_zeros_are_kept() {
        struct Zero;
        impl rand::RngCore for Zero {
            fn next_u32(&mut self) -> u32 {
                0
            }
            fn next_u64(&mut self) -> u64 {
                0
            }
            fn fill_bytes(&mut self, d: &mut [u8]) {
                d.fill(0)
            }
        }
        assert_eq!(generate(&mut Zero), "00000000");
    }

    #[test]
    fn generated_pins_vary() {
        let mut rng = StdRng::seed_from_u64(7);
        let a = generate(&mut rng);
        let b = generate(&mut rng);
        assert_ne!(a, b);
    }

    #[test]
    fn stored_validation() {
        assert!(is_valid_stored("12345678"));
        assert!(is_valid_stored("123456"), "6-digit PINs from older installs still count");
        assert!(!is_valid_stored(""));
        assert!(!is_valid_stored("12a4"));
    }

    #[test]
    fn matching() {
        assert!(matches("12345678", "12345678"));
        assert!(!matches("12345678", "12345679"));
        assert!(!matches("12345678", "1234567"));
        assert!(!matches("12345678", "123456780"));
        assert!(!matches("", ""), "an empty server PIN never authenticates");
    }

    #[test]
    fn log_form_is_length_only() {
        assert_eq!(describe_for_log("12345678"), "len=8");
    }
}
