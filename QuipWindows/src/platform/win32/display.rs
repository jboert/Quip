//! Monitors: `EnumDisplayMonitors` + `GetMonitorInfoW` (bounds, work area,
//! primary flag, device name) + `EnumDisplayDevicesW` (a human name), and
//! `GetDpiForMonitor` for the selftest header.

use windows::core::PCWSTR;
use windows::Win32::Foundation::{BOOL, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{
    EnumDisplayDevicesW, EnumDisplayMonitors, GetMonitorInfoW, DISPLAY_DEVICEW, HDC, HMONITOR, MONITORINFO,
    MONITORINFOEXW,
};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::MONITORINFOF_PRIMARY;

use super::window::{from_wide, pixel_rect};
use crate::platform::listing::{display_name, ensure_one_primary};
use crate::platform::traits::{PlatformDisplay, PlatformError, PlatformResult};

fn monitors() -> Vec<HMONITOR> {
    unsafe extern "system" fn collect(m: HMONITOR, _dc: HDC, _clip: *mut RECT, lp: LPARAM) -> BOOL {
        // SAFETY: `lp` is the `&mut Vec<HMONITOR>` passed below; it outlives
        // the synchronous `EnumDisplayMonitors` call.
        let out = unsafe { &mut *(lp.0 as *mut Vec<HMONITOR>) };
        out.push(m);
        BOOL(1)
    }
    let mut out: Vec<HMONITOR> = Vec::new();
    // SAFETY: no DC and no clip rect (every monitor of the desktop); the
    // callback only writes through the pointer to `out`.
    let _ = unsafe {
        EnumDisplayMonitors(HDC::default(), None, Some(collect), LPARAM(&mut out as *mut Vec<HMONITOR> as isize))
    };
    out
}

/// The adapter's description of the monitor on `device`, e.g. a model name
/// or "Generic PnP Monitor".
fn monitor_description(device: &[u16]) -> Option<String> {
    let mut dd = DISPLAY_DEVICEW { cb: size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
    // SAFETY: `device` is the NUL-terminated `szDevice` of a live monitor and
    // `dd` is writable with `cb` set. Device 0 is the first monitor on it.
    let ok = unsafe { EnumDisplayDevicesW(PCWSTR(device.as_ptr()), 0, &mut dd, 0) }.as_bool();
    ok.then(|| from_wide(&dd.DeviceString))
}

fn monitor_info(m: HMONITOR) -> Option<MONITORINFOEXW> {
    let mut info = MONITORINFOEXW {
        monitorInfo: MONITORINFO { cbSize: size_of::<MONITORINFOEXW>() as u32, ..Default::default() },
        ..Default::default()
    };
    // SAFETY: `info` is a writable MONITORINFOEXW whose `cbSize` says so;
    // GetMonitorInfoW takes it through its leading MONITORINFO.
    unsafe { GetMonitorInfoW(m, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) }.as_bool().then_some(info)
}

pub fn list() -> PlatformResult<Vec<PlatformDisplay>> {
    let mut out = Vec::new();
    for m in monitors() {
        let Some(info) = monitor_info(m) else { continue };
        let device_name = from_wide(&info.szDevice);
        let mut device_z = info.szDevice.to_vec();
        device_z.push(0);
        out.push(PlatformDisplay {
            name: display_name(&device_name, monitor_description(&device_z).as_deref()),
            device_name,
            bounds: pixel_rect(info.monitorInfo.rcMonitor),
            work_area: pixel_rect(info.monitorInfo.rcWork),
            is_primary: info.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0,
        });
    }
    if out.is_empty() {
        return Err(PlatformError::Failed("EnumDisplayMonitors found no display".into()));
    }
    ensure_one_primary(&mut out);
    Ok(out)
}

/// (device name, effective DPI) per monitor: 96 is 100 % scaling. A monitor
/// Windows gives no DPI for is left out.
pub fn effective_dpis() -> Vec<(String, u32)> {
    monitors()
        .into_iter()
        .filter_map(|m| {
            let info = monitor_info(m)?;
            let (mut x, mut y) = (0u32, 0u32);
            // SAFETY: a monitor handle from EnumDisplayMonitors and two
            // writable u32s.
            unsafe { GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut x, &mut y) }.ok()?;
            Some((from_wide(&info.szDevice), x))
        })
        .collect()
}
