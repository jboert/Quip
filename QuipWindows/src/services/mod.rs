//! Host services. Everything here except `ws_server` and `router` is a pure
//! rule with its own tests, each ported from the Mac / Shared test file named
//! in its module doc (spec 10.3).

pub mod auth_throttle;
pub mod broadcast;
pub mod classify;
pub mod clock;
pub mod dedupe;
pub mod device_id;
pub mod geometry;
pub mod injection_log;
pub mod injector;
pub mod keys;
pub mod layout;
pub mod local_addresses;
pub mod log_paths;
pub mod logs;
pub mod multiline_policy;
pub mod pairing;
pub mod phone_log;
pub mod pin_store;
pub mod prefs_store;
pub mod quip_log;
pub mod router;
pub mod secret_redactor;
pub mod settings;
pub mod typing_plan;
pub mod window_color;
pub mod window_id;
pub mod writer;
pub mod ws_server;
