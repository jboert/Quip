//! Wire protocol spoken with the Quip iPhone app.
//!
//! Copied from `QuipLinux/src/protocol/` and reconciled against
//! `Shared/MessageProtocol.swift` and `Shared/DisplayGeometry.swift`, which are
//! the source of truth (the Linux copy is from 1.3.3; the phone is 1.6.0). See
//! the table at the top of `messages.rs` for what changed.

pub mod limits;
pub mod messages;
pub mod types;
