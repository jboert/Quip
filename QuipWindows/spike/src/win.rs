//! Windows half of the spike. See `main.rs` for what it answers.

use std::collections::HashSet;
use std::ffi::c_void;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use windows::Win32::Foundation::{BOOL, HANDLE, HWND, LPARAM, WPARAM};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, SetFocus, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, VIRTUAL_KEY, VK_CONTROL, VK_MENU, VK_RETURN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, EnumWindows, GetClassNameW, GetForegroundWindow,
    GetWindowThreadProcessId, IsIconic, IsWindow, IsWindowVisible, PostMessageW,
    SetForegroundWindow, ShowWindow, SW_RESTORE, WM_CLOSE,
};

const CONSOLE_CLASS: &str = "ConsoleWindowClass";
const WT_CLASS: &str = "CASCADIA_HOSTING_WINDOW_CLASS";
const VK_V: VIRTUAL_KEY = VIRTUAL_KEY(0x56);
const VK_C: VIRTUAL_KEY = VIRTUAL_KEY(0x43);

// ---------------------------------------------------------------- report

#[derive(Default)]
struct Report {
    text: String,
    mechanics_failed: bool,
}

impl Report {
    fn line(&mut self, s: impl AsRef<str>) {
        println!("{}", s.as_ref());
        let _ = writeln!(self.text, "{}", s.as_ref());
    }
    fn pass(&mut self, what: &str, detail: impl AsRef<str>) {
        self.line(format!("PASS   {what}: {}", detail.as_ref()));
    }
    fn fail(&mut self, what: &str, detail: impl AsRef<str>) {
        self.mechanics_failed = true;
        self.line(format!("FAIL   {what}: {}", detail.as_ref()));
    }
    fn result(&mut self, what: &str, detail: impl AsRef<str>) {
        self.line(format!("RESULT {what}: {}", detail.as_ref()));
    }
    fn info(&mut self, what: &str, detail: impl AsRef<str>) {
        self.line(format!("INFO   {what}: {}", detail.as_ref()));
    }
}

// ---------------------------------------------------------------- windows

fn hwnd(v: isize) -> HWND {
    HWND(v as *mut c_void)
}

fn class_of(h: HWND) -> String {
    let mut buf = [0u16; 256];
    // SAFETY: buf is a valid, writable UTF-16 buffer for the call's duration.
    let n = unsafe { GetClassNameW(h, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

/// Every visible top-level window: (handle, class).
fn top_windows() -> Vec<(isize, String)> {
    unsafe extern "system" fn cb(h: HWND, lp: LPARAM) -> BOOL {
        // SAFETY: lp carries the &mut Vec passed below, alive for the whole
        // EnumWindows call, which is synchronous.
        let out = unsafe { &mut *(lp.0 as *mut Vec<(isize, String)>) };
        // SAFETY: h is a window handle supplied by EnumWindows.
        if unsafe { IsWindowVisible(h) }.as_bool() {
            out.push((h.0 as isize, class_of(h)));
        }
        BOOL(1)
    }
    let mut out: Vec<(isize, String)> = Vec::new();
    // SAFETY: the callback only touches `out` through the pointer we pass.
    let _ = unsafe { EnumWindows(Some(cb), LPARAM(&mut out as *mut _ as isize)) };
    out
}

fn wait_new_window(before: &HashSet<isize>, class: &str, timeout: Duration) -> Option<isize> {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if let Some((h, _)) = top_windows()
            .into_iter()
            .find(|(h, c)| c == class && !before.contains(h))
        {
            return Some(h);
        }
        sleep(Duration::from_millis(100));
    }
    None
}

fn foreground_is(h: isize) -> bool {
    // SAFETY: no arguments; returns the current foreground handle.
    unsafe { GetForegroundWindow() }.0 as isize == h
}

fn wait_foreground(h: isize, ms: u64) -> bool {
    let start = Instant::now();
    while start.elapsed() < Duration::from_millis(ms) {
        if foreground_is(h) {
            return true;
        }
        sleep(Duration::from_millis(20));
    }
    foreground_is(h)
}

/// Spec 5.3. Returns the step that worked, or None.
fn bring_to_front(h: isize) -> Option<&'static str> {
    let w = hwnd(h);
    // SAFETY: w is a live top-level window we opened; all calls below take a
    // handle and plain values.
    unsafe {
        if IsIconic(w).as_bool() {
            let _ = ShowWindow(w, SW_RESTORE);
        }
        let _ = SetForegroundWindow(w);
    }
    if wait_foreground(h, 100) {
        return Some("SetForegroundWindow");
    }
    // SAFETY: as above; thread ids come from the OS for live windows.
    unsafe {
        let fg = GetForegroundWindow();
        let fg_thread = GetWindowThreadProcessId(fg, None);
        let me = GetCurrentThreadId();
        let attached = fg_thread != 0 && AttachThreadInput(me, fg_thread, BOOL(1)).as_bool();
        let _ = BringWindowToTop(w);
        let _ = SetForegroundWindow(w);
        let _ = SetFocus(w);
        if attached {
            let _ = AttachThreadInput(me, fg_thread, BOOL(0));
        }
    }
    if wait_foreground(h, 150) {
        return Some("AttachThreadInput");
    }
    key_tap(VK_MENU, &[]);
    // SAFETY: as above.
    unsafe {
        let _ = SetForegroundWindow(w);
    }
    if wait_foreground(h, 300) {
        return Some("Alt+SetForegroundWindow");
    }
    None
}

fn close_window(h: isize) {
    // SAFETY: posting WM_CLOSE to a window handle is always safe; a dead
    // handle just fails.
    unsafe {
        if IsWindow(hwnd(h)).as_bool() {
            let _ = PostMessageW(hwnd(h), WM_CLOSE, WPARAM(0), LPARAM(0));
        }
    }
}

// ---------------------------------------------------------------- input

fn key(vk: VIRTUAL_KEY, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    }
}

fn send(inputs: &[INPUT]) -> u32 {
    // SAFETY: inputs is a valid slice of fully initialised INPUT structs.
    unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) }
}

/// Press `vk` with `mods` held.
fn key_tap(vk: VIRTUAL_KEY, mods: &[VIRTUAL_KEY]) {
    let mut v = Vec::new();
    for m in mods {
        v.push(key(*m, 0, KEYBD_EVENT_FLAGS(0)));
    }
    v.push(key(vk, 0, KEYBD_EVENT_FLAGS(0)));
    v.push(key(vk, 0, KEYEVENTF_KEYUP));
    for m in mods.iter().rev() {
        v.push(key(*m, 0, KEYEVENTF_KEYUP));
    }
    send(&v);
}

/// Types `text` (no line breaks) as UTF-16 code units. Returns units sent.
fn type_unicode(text: &str) -> usize {
    let units: Vec<u16> = text.encode_utf16().collect();
    let mut sent = 0;
    for chunk in units.chunks(32) {
        let mut v = Vec::with_capacity(chunk.len() * 2);
        for &u in chunk {
            v.push(key(VIRTUAL_KEY(0), u, KEYEVENTF_UNICODE));
            v.push(key(VIRTUAL_KEY(0), u, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
        }
        sent += send(&v) as usize / 2;
        sleep(Duration::from_millis(5));
    }
    sent
}

// ---------------------------------------------------------------- clipboard

fn clipboard_get() -> Option<String> {
    // SAFETY: open/close bracket every access; the locked pointer is read only
    // up to the terminating NUL while the clipboard is open.
    unsafe {
        OpenClipboard(HWND::default()).ok()?;
        let out = (|| {
            let h = GetClipboardData(CF_UNICODETEXT.0 as u32).ok()?;
            let g = windows::Win32::Foundation::HGLOBAL(h.0);
            let p = GlobalLock(g) as *const u16;
            if p.is_null() {
                return None;
            }
            let mut n = 0;
            while *p.add(n) != 0 {
                n += 1;
            }
            let s = String::from_utf16_lossy(std::slice::from_raw_parts(p, n));
            let _ = GlobalUnlock(g);
            Some(s)
        })();
        let _ = CloseClipboard();
        out
    }
}

fn clipboard_set(text: &str) -> bool {
    let mut units: Vec<u16> = text.encode_utf16().collect();
    units.push(0);
    // SAFETY: the allocation is sized for `units`; ownership passes to the
    // clipboard on a successful SetClipboardData.
    unsafe {
        if OpenClipboard(HWND::default()).is_err() {
            return false;
        }
        let ok = (|| {
            EmptyClipboard().ok()?;
            let g = GlobalAlloc(GMEM_MOVEABLE, units.len() * 2).ok()?;
            let p = GlobalLock(g) as *mut u16;
            if p.is_null() {
                return None;
            }
            std::ptr::copy_nonoverlapping(units.as_ptr(), p, units.len());
            let _ = GlobalUnlock(g);
            SetClipboardData(CF_UNICODETEXT.0 as u32, HANDLE(g.0)).ok()?;
            Some(())
        })()
        .is_some();
        let _ = CloseClipboard();
        ok
    }
}

// ---------------------------------------------------------------- shells

#[derive(Clone, Copy, PartialEq)]
enum Shell {
    PowerShell,
    Cmd,
}

struct Target {
    label: &'static str,
    shell: Shell,
    hwnd: isize,
    child: Option<Child>,
}

impl Target {
    /// A command that writes `marker` to `file`.
    fn write_cmd(&self, marker: &str, file: &Path) -> String {
        match self.shell {
            Shell::PowerShell => format!(
                "'{marker}' | Out-File -Encoding utf8 '{}'",
                file.display()
            ),
            Shell::Cmd => format!("echo {marker}> \"{}\"", file.display()),
        }
    }
}

fn which(exe: &str) -> bool {
    Command::new("where")
        .arg(exe)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn open_conhost(label: &'static str, shell: Shell, dir: &Path, r: &mut Report) -> Option<Target> {
    let before: HashSet<isize> = top_windows().into_iter().map(|(h, _)| h).collect();
    let mut cmd = Command::new("conhost.exe");
    match shell {
        Shell::PowerShell => {
            cmd.args(["powershell.exe", "-NoLogo", "-NoExit", "-Command"])
                .arg(format!("Set-Location '{}'", dir.display()));
        }
        Shell::Cmd => {
            cmd.args(["cmd.exe", "/K"]).arg(format!("cd /d \"{}\"", dir.display()));
        }
    }
    let child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            r.fail(label, format!("spawn failed: {e}"));
            return None;
        }
    };
    match wait_new_window(&before, CONSOLE_CLASS, Duration::from_secs(10)) {
        Some(h) => {
            r.pass(&format!("{label} open"), "console window found");
            Some(Target { label, shell, hwnd: h, child: Some(child) })
        }
        None => {
            r.fail(&format!("{label} open"), "no new ConsoleWindowClass window in 10 s");
            None
        }
    }
}

fn open_wt(dir: &Path, r: &mut Report) -> Option<Target> {
    let label = "wt-powershell";
    if !which("wt.exe") {
        r.info(label, "wt.exe not installed; Windows Terminal not tested here");
        return None;
    }
    let before: HashSet<isize> = top_windows().into_iter().map(|(h, _)| h).collect();
    let spawned = Command::new("wt.exe")
        .args(["-w", "new", "powershell.exe", "-NoLogo", "-NoExit", "-Command"])
        .arg(format!("Set-Location '{}'", dir.display()))
        .spawn();
    if let Err(e) = spawned {
        r.fail(label, format!("spawn failed: {e}"));
        return None;
    }
    match wait_new_window(&before, WT_CLASS, Duration::from_secs(15)) {
        Some(h) => {
            r.pass(&format!("{label} open"), "Windows Terminal window found");
            Some(Target { label, shell: Shell::PowerShell, hwnd: h, child: None })
        }
        None => {
            r.fail(&format!("{label} open"), "no new Windows Terminal window in 15 s");
            None
        }
    }
}

fn wait_file(p: &Path, ms: u64) -> bool {
    let start = Instant::now();
    while start.elapsed() < Duration::from_millis(ms) {
        if p.exists() {
            return true;
        }
        sleep(Duration::from_millis(100));
    }
    p.exists()
}

fn read_marker(p: &Path) -> String {
    std::fs::read(p)
        .map(|b| String::from_utf8_lossy(&b).trim_start_matches('\u{feff}').trim().to_string())
        .unwrap_or_default()
}

/// Clear whatever is on the command line.
fn clear_line(t: &Target) {
    if bring_to_front(t.hwnd).is_some() {
        key_tap(VK_C, &[VK_CONTROL]);
        sleep(Duration::from_millis(600));
    }
}

fn front_or_fail(t: &Target, what: &str, r: &mut Report) -> bool {
    match bring_to_front(t.hwnd) {
        Some(step) => {
            r.pass(&format!("{} {what} focus", t.label), format!("foreground via {step}"));
            true
        }
        None => {
            r.fail(&format!("{} {what} focus", t.label), "window never became foreground");
            false
        }
    }
}

fn test_target(t: &Target, dir: &Path, others: &[isize], r: &mut Report) {
    let tag = t.label;
    // Put another window in front first, so every focus below is real work.
    if let Some(&o) = others.first() {
        let _ = bring_to_front(o);
        sleep(Duration::from_millis(300));
    }

    // 1. Single line + Return, ASCII. Also proves the shell is ready.
    let f1 = dir.join(format!("{tag}-1.txt"));
    let m1 = format!("q91m{}", std::process::id());
    let mut ran = false;
    for attempt in 0..3 {
        if !front_or_fail(t, "single-line", r) {
            return;
        }
        type_unicode(&t.write_cmd(&m1, &f1));
        key_tap(VK_RETURN, &[]);
        if wait_file(&f1, 8000) {
            ran = true;
            break;
        }
        r.info(&format!("{tag} single-line"), format!("no file after attempt {}", attempt + 1));
        clear_line(t);
    }
    if ran && read_marker(&f1) == m1 {
        r.pass(&format!("{tag} single-line"), "typed command ran, marker matches");
    } else if ran {
        r.fail(&format!("{tag} single-line"), format!("marker differs: {:?}", read_marker(&f1)));
    } else {
        r.fail(&format!("{tag} single-line"), "command never ran");
        return;
    }

    // 2. Non-ASCII (PowerShell only; cmd's code page makes this meaningless).
    if t.shell == Shell::PowerShell {
        let f2 = dir.join(format!("{tag}-2.txt"));
        let m2 = "q91-é-漢字-🙂";
        if front_or_fail(t, "unicode", r) {
            type_unicode(&t.write_cmd(m2, &f2));
            key_tap(VK_RETURN, &[]);
            if wait_file(&f2, 8000) {
                let got = read_marker(&f2);
                if got == m2 {
                    r.pass(&format!("{tag} unicode"), "accented, CJK and emoji arrived intact");
                } else {
                    r.fail(&format!("{tag} unicode"), format!("got {got:?}"));
                }
            } else {
                r.fail(&format!("{tag} unicode"), "command never ran");
            }
        }
    }

    // 3. Two lines joined by Shift+Enter, no Return: must not run.
    let a = dir.join(format!("{tag}-3a.txt"));
    let b = dir.join(format!("{tag}-3b.txt"));
    if front_or_fail(t, "shift-enter", r) {
        type_unicode(&t.write_cmd("a", &a));
        key_tap(VK_RETURN, &[VK_SHIFT]);
        type_unicode(&t.write_cmd("b", &b));
        sleep(Duration::from_millis(2500));
        let early = a.exists() || b.exists();
        if early {
            r.result(&format!("{tag} shift-enter"), "UNSAFE: a line ran before Return");
        } else if bring_to_front(t.hwnd).is_some() {
            key_tap(VK_RETURN, &[]);
            let both = wait_file(&a, 6000) && wait_file(&b, 2000);
            r.result(
                &format!("{tag} shift-enter"),
                if both {
                    "SAFE: nothing ran early; one Return ran both lines"
                } else if a.exists() || b.exists() {
                    "PARTIAL: nothing ran early; Return ran only one line"
                } else {
                    "SAFE-BUT-STUCK: nothing ran early; Return ran nothing"
                },
            );
        }
        clear_line(t);
    }

    // 4. Two lines by clipboard paste (Ctrl+V), no Return: must not run.
    let a = dir.join(format!("{tag}-4a.txt"));
    let b = dir.join(format!("{tag}-4b.txt"));
    let saved = clipboard_get();
    let text = format!("{}\r\n{}", t.write_cmd("a", &a), t.write_cmd("b", &b));
    if !clipboard_set(&text) {
        r.fail(&format!("{tag} paste"), "could not set the clipboard");
    } else if front_or_fail(t, "paste", r) {
        key_tap(VK_V, &[VK_CONTROL]);
        sleep(Duration::from_millis(2500));
        let early = a.exists() || b.exists();
        if early {
            r.result(&format!("{tag} paste"), "UNSAFE: a line ran before Return");
        } else if bring_to_front(t.hwnd).is_some() {
            key_tap(VK_RETURN, &[]);
            let both = wait_file(&a, 6000) && wait_file(&b, 2000);
            r.result(
                &format!("{tag} paste"),
                if both {
                    "SAFE: nothing ran early; one Return ran both lines"
                } else if a.exists() || b.exists() {
                    "PARTIAL: nothing ran early; Return ran only one line"
                } else {
                    "SAFE-BUT-STUCK: nothing ran early; Return ran nothing (paste dialog?)"
                },
            );
        }
        clear_line(t);
    }
    match saved {
        Some(s) => {
            if clipboard_set(&s) {
                r.info(&format!("{tag} paste"), "clipboard text put back");
            } else {
                r.fail(&format!("{tag} paste"), "could not put the clipboard back");
            }
        }
        None => r.info(&format!("{tag} paste"), "clipboard held no text before; left as is"),
    }
}

fn powershell_info(r: &mut Report) {
    let out = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-Command",
            "$PSVersionTable.PSVersion.ToString(); (Get-Module -ListAvailable PSReadLine | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()",
        ])
        .output();
    match out {
        Ok(o) => {
            let s = String::from_utf8_lossy(&o.stdout);
            let mut lines = s.lines();
            r.info("powershell", lines.next().unwrap_or("?").trim());
            r.info("psreadline", lines.next().unwrap_or("not installed").trim());
        }
        Err(e) => r.info("powershell", format!("could not run: {e}")),
    }
}

fn windows_version() -> String {
    Command::new("cmd")
        .args(["/c", "ver"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|_| "?".into())
}

pub fn run() -> i32 {
    let mut r = Report::default();
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    r.line(format!("quip-spike (Q-91 M0) {}", env!("CARGO_PKG_VERSION")));
    r.info("windows", windows_version());
    // SAFETY: no arguments.
    let fg = unsafe { GetForegroundWindow() };
    r.info(
        "desktop",
        if fg.0.is_null() { "no foreground window (non-interactive session?)" } else { "interactive" },
    );
    powershell_info(&mut r);

    let dir: PathBuf = std::env::temp_dir().join(format!("quip-spike-{now}"));
    if let Err(e) = std::fs::create_dir_all(&dir) {
        r.fail("temp dir", e.to_string());
    }

    let mut targets: Vec<Target> = Vec::new();
    if let Some(t) = open_conhost("conhost-powershell", Shell::PowerShell, &dir, &mut r) {
        targets.push(t);
    }
    if let Some(t) = open_conhost("conhost-cmd", Shell::Cmd, &dir, &mut r) {
        targets.push(t);
    }
    if let Some(t) = open_wt(&dir, &mut r) {
        targets.push(t);
    }
    // Give PowerShell time to load PSReadLine and draw its prompt.
    sleep(Duration::from_secs(4));

    let handles: Vec<isize> = targets.iter().map(|t| t.hwnd).collect();
    for t in &targets {
        let others: Vec<isize> = handles.iter().copied().filter(|h| *h != t.hwnd).collect();
        test_target(t, &dir, &others, &mut r);
    }

    for t in &mut targets {
        close_window(t.hwnd);
        if let Some(c) = t.child.as_mut() {
            let _ = c.kill();
        }
    }
    let _ = std::fs::remove_dir_all(&dir);

    r.line(if r.mechanics_failed { "SUMMARY mechanics: FAIL" } else { "SUMMARY mechanics: PASS" });
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let out_dir = base.join("Quip");
    let _ = std::fs::create_dir_all(&out_dir);
    let out = out_dir.join(format!("spike-report-{now}.txt"));
    match std::fs::write(&out, &r.text) {
        Ok(()) => println!("report: {}", out.display()),
        Err(e) => eprintln!("could not write report: {e}"),
    }
    if r.mechanics_failed {
        1
    } else {
        0
    }
}
