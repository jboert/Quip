//! "Start with Windows" (spec 6): the value `Quip` under
//! `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, holding the quoted
//! full path of `Quip.exe`. Default off. The value's text is pure and tested
//! here; reading and writing it is Windows only.

use std::path::Path;

pub const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
pub const VALUE_NAME: &str = "Quip";

/// The Run value the selftest round-trips instead of `VALUE_NAME`, so a
/// selftest killed half way never loses or changes the user's setting.
pub fn selftest_value_name(pid: u32) -> String {
    format!("{VALUE_NAME}-selftest-{pid}")
}

/// `"C:\Program Files\Quip\Quip.exe"`: quoted, so a path with spaces is one
/// command, not a program `C:\Program` with arguments.
pub fn run_value(exe: &Path) -> String {
    format!("\"{}\"", exe.to_string_lossy())
}

/// Whether a stored Run value starts `exe` (quoted or not, any case, as
/// Windows paths are). A value naming another copy of Quip is not this one,
/// so the toggle shows off and turning it on points it here.
pub fn points_at(value: &str, exe: &Path) -> bool {
    let v = value.trim();
    let program = match v.strip_prefix('"') {
        Some(rest) => rest.split('"').next().unwrap_or(""),
        None => v,
    };
    program.eq_ignore_ascii_case(&exe.to_string_lossy())
}

#[cfg(windows)]
pub use self::win32::{read, read_named, remove, round_trip, write};

#[cfg(windows)]
mod win32 {
    use windows::core::{HSTRING, PCWSTR};
    use windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS, WIN32_ERROR};
    use windows::Win32::System::Registry::{
        RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW, HKEY_CURRENT_USER, REG_SZ, RRF_RT_REG_SZ,
    };

    use super::{RUN_KEY, VALUE_NAME};

    fn err(what: &str, value: &str, e: WIN32_ERROR) -> String {
        format!("{what} {value} in HKCU\\{RUN_KEY}: {}", windows::core::Error::from(e.to_hresult()).message())
    }

    /// The current Run value, `None` when there is none.
    pub fn read() -> Result<Option<String>, String> {
        read_named(VALUE_NAME)
    }

    /// Sets the Run value to `value` (see `run_value`).
    pub fn write(value: &str) -> Result<(), String> {
        write_named(VALUE_NAME, value)
    }

    /// Deletes the Run value. No value is not an error.
    pub fn remove() -> Result<(), String> {
        remove_named(VALUE_NAME)
    }

    /// The Run key's value `value_name`, `None` when there is none.
    pub fn read_named(value_name: &str) -> Result<Option<String>, String> {
        let (key, name) = (HSTRING::from(RUN_KEY), HSTRING::from(value_name));
        let mut bytes: u32 = 0;
        // SAFETY: the strings outlive the call; a null data pointer with a
        // size pointer asks for the size only.
        let e = unsafe { RegGetValueW(HKEY_CURRENT_USER, &key, &name, RRF_RT_REG_SZ, None, None, Some(&mut bytes)) };
        if e == ERROR_FILE_NOT_FOUND {
            return Ok(None);
        }
        if e != ERROR_SUCCESS {
            return Err(err("cannot read", value_name, e));
        }
        let mut buf = vec![0u16; (bytes as usize).div_ceil(2) + 1];
        let mut size = (buf.len() * 2) as u32;
        // SAFETY: `buf` is writable for `size` bytes, as the call is told.
        let e = unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                &key,
                &name,
                RRF_RT_REG_SZ,
                None,
                Some(buf.as_mut_ptr().cast()),
                Some(&mut size),
            )
        };
        if e == ERROR_FILE_NOT_FOUND {
            return Ok(None);
        }
        if e != ERROR_SUCCESS {
            return Err(err("cannot read", value_name, e));
        }
        let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        Ok(Some(String::from_utf16_lossy(&buf[..len])))
    }

    fn write_named(value_name: &str, value: &str) -> Result<(), String> {
        let (key, name) = (HSTRING::from(RUN_KEY), HSTRING::from(value_name));
        let data: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
        // SAFETY: `data` is a NUL-terminated UTF-16 string of exactly the
        // byte count passed, alive for the call.
        let e = unsafe {
            RegSetKeyValueW(
                HKEY_CURRENT_USER,
                &key,
                &name,
                REG_SZ.0,
                Some(data.as_ptr().cast()),
                (data.len() * 2) as u32,
            )
        };
        if e == ERROR_SUCCESS {
            Ok(())
        } else {
            Err(err("cannot write", value_name, e))
        }
    }

    /// The selftest case: under `selftest_value_name(<this pid>)`, never the
    /// user's `Quip` value, sets the value for `exe`, checks it reads back,
    /// deletes it and checks it is gone. `Quip` is only read, before and
    /// after, and must not have changed.
    pub fn round_trip(exe: &std::path::Path) -> Result<(), String> {
        let name = super::selftest_value_name(std::process::id());
        let users = read()?;
        let checked = (|| {
            let value = super::run_value(exe);
            write_named(&name, &value)?;
            match read_named(&name)? {
                Some(got) if got == value => {}
                other => return Err(format!("wrote {value:?}, read back {other:?}")),
            }
            remove_named(&name)?;
            match read_named(&name)? {
                None => Ok(()),
                Some(got) => Err(format!("still set after the delete: {got:?}")),
            }
        })();
        // Never left behind, even when a check failed.
        let cleaned = remove_named(&name).map_err(|e| format!("{name} was not deleted: {e}"));
        let untouched = match read()? {
            now if now == users => Ok(()),
            now => Err(format!("{VALUE_NAME} changed from {users:?} to {now:?}")),
        };
        checked.and(cleaned).and(untouched)
    }

    fn remove_named(value_name: &str) -> Result<(), String> {
        let (key, name) = (HSTRING::from(RUN_KEY), HSTRING::from(value_name));
        // SAFETY: the strings outlive the call.
        let e = unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, &key, PCWSTR(name.as_ptr())) };
        if e == ERROR_SUCCESS || e == ERROR_FILE_NOT_FOUND {
            Ok(())
        } else {
            Err(err("cannot delete", value_name, e))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn the_value_is_the_quoted_exe_path() {
        let exe = PathBuf::from(r"C:\Program Files\Quip\Quip.exe");
        assert_eq!(run_value(&exe), r#""C:\Program Files\Quip\Quip.exe""#);
    }

    #[test]
    fn points_at_accepts_quoted_unquoted_and_any_case() {
        let exe = PathBuf::from(r"C:\Program Files\Quip\Quip.exe");
        assert!(points_at(&run_value(&exe), &exe));
        assert!(points_at(r#""c:\program files\quip\QUIP.EXE" --flag"#, &exe));
        assert!(points_at(r"C:\Program Files\Quip\Quip.exe", &exe));
        assert!(!points_at(r#""D:\Tools\Quip.exe""#, &exe));
        assert!(!points_at("", &exe));
    }

    #[test]
    fn the_selftest_round_trips_its_own_value_name() {
        assert_eq!(selftest_value_name(4242), "Quip-selftest-4242");
        assert_ne!(selftest_value_name(4242), VALUE_NAME);
        assert_ne!(selftest_value_name(4242), selftest_value_name(4243));
    }

    #[test]
    fn the_run_key_is_the_per_user_one() {
        assert_eq!(RUN_KEY, r"Software\Microsoft\Windows\CurrentVersion\Run");
        assert_eq!(VALUE_NAME, "Quip");
    }
}
