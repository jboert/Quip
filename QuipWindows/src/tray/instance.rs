//! One Quip per Windows session (spec 6): the named mutex
//! `Local\QuipWindows`. A second launch finds it taken and exits at once
//! with code 0, before reading settings or binding the port.

pub const MUTEX_NAME: &str = r"Local\QuipWindows";

#[cfg(windows)]
pub use self::win32::{acquire, Acquired, InstanceGuard};

#[cfg(windows)]
mod win32 {
    use windows::core::HSTRING;
    use windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HANDLE};
    use windows::Win32::System::Threading::CreateMutexW;

    use super::MUTEX_NAME;

    /// Holds the mutex. Dropping it (or exiting) lets the next launch run.
    pub struct InstanceGuard(HANDLE);

    impl Drop for InstanceGuard {
        fn drop(&mut self) {
            // SAFETY: the handle came from CreateMutexW and is closed once.
            let _ = unsafe { CloseHandle(self.0) };
        }
    }

    pub enum Acquired {
        First(InstanceGuard),
        AlreadyRunning,
    }

    /// Takes `Local\QuipWindows`, or reports that another Quip has it.
    pub fn acquire() -> Result<Acquired, String> {
        let name = HSTRING::from(MUTEX_NAME);
        // SAFETY: default security, not initially owned (existence is the
        // signal), the name outlives the call.
        let handle =
            unsafe { CreateMutexW(None, false, &name) }.map_err(|e| format!("cannot create {MUTEX_NAME}: {e}"))?;
        // SAFETY: no arguments; read right after the call that set it.
        let already = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
        let guard = InstanceGuard(handle);
        if already {
            drop(guard);
            Ok(Acquired::AlreadyRunning)
        } else {
            Ok(Acquired::First(guard))
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_mutex_is_per_session() {
        assert_eq!(super::MUTEX_NAME, r"Local\QuipWindows");
    }
}
