//! Quip host for Windows (Q-91), as a library so the integration tests in
//! `tests/` can drive the real server. See
//! `docs/superpowers/specs/2026-11-06-q91-quip-windows-host.md`.
//!
//! A panic in the host is a dead remote for the user (spec 10.1): no
//! `unwrap`/`expect` outside tests, and every `unsafe` block says why it holds.
#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used))]
#![deny(clippy::undocumented_unsafe_blocks)]

pub mod app;
pub mod app_state;
pub mod fake_mode;
pub mod host;
pub mod platform;
pub mod protocol;
pub mod selftest;
pub mod services;
pub mod tray;
