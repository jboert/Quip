//! The focus, typing and key cases of `--selftest` (spec 5.3 - 5.5, 10.5),
//! through the real backend and the shared injector.
//!
//! Every target is a window this run opened (a console carrying its marker),
//! and input goes only through `injector::execute` / `send_text_on_lane`.
//! The results come back through files in the run's own temp folder: a
//! PowerShell that reads a line (`Read-Host`), runs a typed command, or
//! "collects" the keys that reach it for `COLLECT` and writes them out.
//!
//! SKIP only when no window is in front when a case starts (a locked screen,
//! no interactive desktop). Anything else that goes wrong is a FAIL.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use windows::Win32::System::Threading::WaitForSingleObject;
use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;

use super::*;
use crate::platform::integrity::one_below;
use crate::platform::traits::{
    FocusStep, InputAccess, InputBackend, PlatformDisplay, PlatformError, PlatformResult, WindowMove, WindowRects,
};
use crate::platform::win32::integrity::spawn_at_integrity;
use crate::services::injector::{self, Step};
use crate::services::keys::{Key, KeyChord};
use crate::services::multiline_policy::WindowsSend;
use crate::services::router::{send_text_on_lane, SendOutcome};

/// PSReadLine loads after the `-Command` script; M0 waited 4 s in all.
const SETTLE: Duration = Duration::from_secs(2);
const READY_WAIT: Duration = Duration::from_secs(20);
/// The longest a collector reads keys; a case ends it sooner with its stop
/// file (`stop_collectors`), once its input had time to arrive.
const COLLECT: Duration = Duration::from_secs(30);
/// How long input may take to reach a collector before it is told to stop.
const DRAIN: Duration = Duration::from_secs(1);
const RESULT_WAIT: Duration = Duration::from_secs(6);
const PROBE_WAIT: Duration = Duration::from_secs(15);

/// `Some(Skip)` when nothing is in front (no interactive desktop).
fn no_desktop() -> Option<Outcome> {
    // SAFETY: no arguments.
    let fg = unsafe { GetForegroundWindow() };
    fg.is_invalid().then(|| Outcome::Skip("no window is in front (locked screen or no interactive desktop)".into()))
}

/// The file's text: BOM and trailing line breaks dropped. `None` when it
/// does not exist (yet).
fn read_result(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    Some(text.trim_start_matches('\u{feff}').trim_end_matches(['\r', '\n']).to_string())
}

fn wait_result(path: &Path, timeout: Duration) -> Option<String> {
    let start = Instant::now();
    loop {
        if let Some(t) = read_result(path) {
            return Some(t);
        }
        if start.elapsed() >= timeout {
            return None;
        }
        sleep(POLL);
    }
}

/// Why a plan failed, for a FAIL line; "focus moved" when the user (or
/// anything) took focus.
fn plan_failure(e: &PlatformError) -> String {
    match e {
        PlatformError::FocusLost { after_chars } => format!("focus moved after {after_chars} chars"),
        other => other.to_string(),
    }
}

impl Ctx {
    /// The run's temp folder, made on first use.
    fn run_dir(&mut self) -> Result<PathBuf, String> {
        if let Some(d) = &self.dir {
            return Ok(d.clone());
        }
        let d = std::env::temp_dir().join(format!("quip-selftest-{}", std::process::id()));
        std::fs::create_dir_all(&d).map_err(|e| format!("cannot make {}: {e}", d.display()))?;
        self.dir = Some(d.clone());
        Ok(d)
    }

    /// A classic-console PowerShell of its own that titles itself, writes
    /// `<dir>\<m>-ready.txt`, then runs `body(marker, dir)`. Returns once the
    /// ready file is there plus `SETTLE`.
    fn open_powershell(
        &mut self,
        what: &'static str,
        tag: &str,
        body: impl Fn(&str, &str) -> String,
    ) -> Result<(PlatformWindow, String, PathBuf), String> {
        let dir = self.run_dir()?;
        let d = dir.display().to_string();
        let (w, m) = self.open_conhost_marked(what, tag, |m| {
            format!(
                r#"powershell.exe -NoLogo -NoProfile -NoExit -Command "$Host.UI.RawUI.WindowTitle='{m}'; 'ready' | Out-File -FilePath '{d}\{m}-ready.txt'; {}""#,
                body(m, &d)
            )
        })?;
        if wait_result(&dir.join(format!("{m}-ready.txt")), READY_WAIT).is_none() {
            return Err(format!("the {what} never got ready in {} s", READY_WAIT.as_secs()));
        }
        sleep(SETTLE);
        Ok((w, m, dir))
    }

    /// A PowerShell that records every key reaching it until its stop file
    /// `<dir>\<m>-stop.txt` appears (at most `COLLECT`), takes what is still
    /// queued, then writes them to `<dir>\<m>.txt`: the characters, or
    /// `Key+Modifiers` per key joined by `,` when `keys`.
    fn open_collector(&mut self, tag: &str, keys: bool) -> Result<(PlatformWindow, String, PathBuf), String> {
        let (item, sep) =
            if keys { ("($k.Key.ToString()+'+'+$k.Modifiers.ToString())", ",") } else { ("[string]$k.KeyChar", "") };
        let secs = COLLECT.as_secs();
        let (w, m, dir) = self.open_powershell("collector console", tag, |m, d| {
            format!(
                "$e=(Get-Date).AddSeconds({secs}); $o=New-Object System.Collections.ArrayList; while(((Get-Date) -lt $e) -and -not (Test-Path '{d}\\{m}-stop.txt')){{ if([Console]::KeyAvailable){{ $k=[Console]::ReadKey($true); [void]$o.Add({item}) }} else {{ Start-Sleep -Milliseconds 10 }} }}; while([Console]::KeyAvailable){{ $k=[Console]::ReadKey($true); [void]$o.Add({item}) }}; ($o -join '{sep}') | Out-File -Encoding utf8 -FilePath '{d}\\{m}.txt'"
            )
        })?;
        let file = dir.join(format!("{m}.txt"));
        Ok((w, m, file))
    }

    /// After `DRAIN`, tells the collectors whose result files are `files`
    /// to stop (each `<m>.txt` has its `<m>-stop.txt`).
    fn stop_collectors(&self, files: &[&Path]) {
        sleep(DRAIN);
        for f in files {
            let stop = f.with_file_name(format!(
                "{}-stop.txt",
                f.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
            ));
            let _ = std::fs::write(stop, "stop");
        }
    }

    /// Puts `w` (its own) in front, or says why not.
    fn front(&self, w: WindowRef) -> Result<FocusStep, String> {
        let step = self.platform.bring_to_foreground(w).map_err(|e| format!("bring_to_foreground: {e}"))?;
        match self.platform.foreground_window() {
            Ok(Some(f)) if f == w => Ok(step),
            other => Err(format!("{step:?} reported, but the window in front is {other:?}")),
        }
    }
}

/// The real platform with two test behaviours. It never sends input of its
/// own: `count_only` answers input calls without sending anything; `thief`
/// lets the first typing batch through and then focuses another window of
/// the run's own (as a user clicking away would).
struct Wrapped<'a> {
    inner: &'a Win32Platform,
    count_only: bool,
    thief: Option<WindowRef>,
    units_calls: AtomicUsize,
    key_calls: AtomicUsize,
}

impl<'a> Wrapped<'a> {
    fn counter(inner: &'a Win32Platform) -> Self {
        Wrapped {
            inner,
            count_only: true,
            thief: None,
            units_calls: AtomicUsize::new(0),
            key_calls: AtomicUsize::new(0),
        }
    }
    fn thief(inner: &'a Win32Platform, to: WindowRef) -> Self {
        Wrapped { thief: Some(to), count_only: false, ..Self::counter(inner) }
    }
}

impl WindowBackend for Wrapped<'_> {
    fn list_windows(&self) -> PlatformResult<Vec<PlatformWindow>> {
        self.inner.list_windows()
    }
    fn list_displays(&self) -> PlatformResult<Vec<PlatformDisplay>> {
        self.inner.list_displays()
    }
    fn foreground_window(&self) -> PlatformResult<Option<WindowRef>> {
        self.inner.foreground_window()
    }
    fn current_shell(&self, w: WindowRef) -> PlatformResult<Option<Shell>> {
        self.inner.current_shell(w)
    }
    fn bring_to_foreground(&self, w: WindowRef) -> PlatformResult<FocusStep> {
        self.inner.bring_to_foreground(w)
    }
    fn restore(&self, w: WindowRef) -> PlatformResult<()> {
        self.inner.restore(w)
    }
    fn rects(&self, w: WindowRef) -> PlatformResult<WindowRects> {
        self.inner.rects(w)
    }
    fn move_windows(&self, m: &[WindowMove]) -> Vec<PlatformResult<()>> {
        self.inner.move_windows(m)
    }
    fn minimize(&self, w: WindowRef) -> PlatformResult<()> {
        self.inner.minimize(w)
    }
    fn close(&self, w: WindowRef) -> PlatformResult<()> {
        self.inner.close(w)
    }
    fn input_access(&self, w: WindowRef) -> PlatformResult<InputAccess> {
        self.inner.input_access(w)
    }
}

impl InputBackend for Wrapped<'_> {
    fn send_units(&self, w: WindowRef, units: &[u16]) -> PlatformResult<usize> {
        let n = self.units_calls.fetch_add(1, Ordering::SeqCst);
        if self.count_only {
            return Err(PlatformError::Failed("counted, not sent".into()));
        }
        let r = self.inner.send_units(w, units);
        if let (0, Some(to)) = (n, self.thief) {
            let _ = self.inner.bring_to_foreground(to);
        }
        r
    }
    fn press_key(&self, w: WindowRef, chord: KeyChord) -> PlatformResult<usize> {
        self.key_calls.fetch_add(1, Ordering::SeqCst);
        if self.count_only {
            return Err(PlatformError::Failed("counted, not sent".into()));
        }
        self.inner.press_key(w, chord)
    }
}

/// Two consoles of its own, the second in front: the first comes to the
/// front, handle and pid.
pub fn focus_own_console(ctx: &mut Ctx) -> Outcome {
    if let Some(s) = no_desktop() {
        return s;
    }
    let mut own = Vec::new();
    for tag in ["focus-a", "focus-b"] {
        match ctx.open_conhost("focus console", tag, cmd_titled) {
            Ok(w) => own.push(w.window_ref()),
            Err(e) => return Outcome::Fail(e),
        }
    }
    match ctx.front(own[1]) {
        Ok(step) => ctx.notes.push(format!("second console in front via {}", step.as_str())),
        Err(e) => return Outcome::Fail(format!("could not put the second console in front: {e}")),
    }
    match ctx.front(own[0]) {
        Ok(step) => {
            ctx.notes.push(format!("first console in front via {}", step.as_str()));
            Outcome::Pass
        }
        Err(e) => Outcome::Fail(e),
    }
}

/// The marker text with accented, CJK and emoji characters.
fn marker_text(m: &str) -> String {
    format!("{m}-é-漢字-🙂")
}

fn read_back(ctx: &mut Ctx, w: &PlatformWindow, path: &Path, text: &str) -> Outcome {
    match send_text_on_lane(&ctx.platform, w.window_ref(), text, true) {
        SendOutcome::Ran { report, .. } => {
            if let Some(f) = report.focus {
                ctx.notes.push(format!("focus via {}", f.as_str()));
            }
            if let Some(e) = &report.error {
                return Outcome::Fail(format!("send_text: {}", plan_failure(e)));
            }
        }
        SendOutcome::Refused { shell } => return Outcome::Fail(format!("refused as {shell:?}")),
        SendOutcome::Gone => return Outcome::Fail("its window is gone".into()),
    }
    match wait_result(path, RESULT_WAIT) {
        Some(got) if got == text => Outcome::Pass,
        Some(got) => Outcome::Fail(format!("read back {got:?}, wanted {text:?}")),
        None => Outcome::Fail(format!("nothing read back in {} s", RESULT_WAIT.as_secs())),
    }
}

/// Spec 10.5 "Typing": a marker with emoji, then Return, into a PowerShell
/// of its own that reads one line and writes it out.
pub fn type_marker_read_back(ctx: &mut Ctx) -> Outcome {
    if let Some(s) = no_desktop() {
        return s;
    }
    let opened = ctx.open_powershell("Read-Host PowerShell", "type", |m, d| {
        format!("$r = Read-Host; $r | Out-File -Encoding utf8 -FilePath '{d}\\{m}.txt'")
    });
    let (w, m, dir) = match opened {
        Ok(o) => o,
        Err(e) => return Outcome::Fail(e),
    };
    read_back(ctx, &w, &dir.join(format!("{m}.txt")), &marker_text(&m))
}

/// Spec 10.5 "Multi-line": two command lines with Return requested land
/// with Shift+Enter and do not run; one Return then runs both.
pub fn multi_line_waits_for_return(ctx: &mut Ctx) -> Outcome {
    if let Some(s) = no_desktop() {
        return s;
    }
    let (w, m, dir) = match ctx.open_powershell("PSReadLine PowerShell", "multi", |_, _| String::new()) {
        Ok(o) => o,
        Err(e) => return Outcome::Fail(e),
    };
    let (a, b) = (dir.join(format!("{m}-a.txt")), dir.join(format!("{m}-b.txt")));
    let text = format!("'x' | Out-File -FilePath '{}'\n'x' | Out-File -FilePath '{}'", a.display(), b.display());
    let target = w.window_ref();
    match send_text_on_lane(&ctx.platform, target, &text, true) {
        SendOutcome::Ran { report, decision, shell } => {
            if !matches!(decision, WindowsSend::Type { press_return: false, .. }) {
                return Outcome::Fail(format!("the policy for {shell:?} would press Return: {decision:?}"));
            }
            if let Some(e) = &report.error {
                return Outcome::Fail(format!("send_text: {}", plan_failure(e)));
            }
        }
        SendOutcome::Refused { shell } => return Outcome::Fail(format!("refused as {shell:?}, not PowerShell")),
        SendOutcome::Gone => return Outcome::Fail("its window is gone".into()),
    }
    sleep(Duration::from_secs(2));
    if a.exists() || b.exists() {
        return Outcome::Fail("a line ran before Return".into());
    }
    let report = injector::execute(&ctx.platform, target, &[Step::Focus, Step::Key(KeyChord::RETURN)]);
    if let Some(e) = &report.error {
        return Outcome::Fail(format!("Return: {}", plan_failure(e)));
    }
    let start = Instant::now();
    while start.elapsed() < RESULT_WAIT {
        if a.exists() && b.exists() {
            return Outcome::Pass;
        }
        sleep(POLL);
    }
    Outcome::Fail(format!("after Return: first ran={}, second ran={}", a.exists(), b.exists()))
}

/// Multi-line text to cmd is refused before any input call.
pub fn multi_line_refused_in_cmd(ctx: &mut Ctx) -> Outcome {
    if let Some(s) = no_desktop() {
        return s;
    }
    let w = match ctx.open_conhost("cmd console", "refuse", cmd_titled) {
        Ok(w) => w,
        Err(e) => return Outcome::Fail(e),
    };
    let counter = Wrapped::counter(&ctx.platform);
    let out = send_text_on_lane(&counter, w.window_ref(), "rem one\nrem two", true);
    let (u, k) = (counter.units_calls.load(Ordering::SeqCst), counter.key_calls.load(Ordering::SeqCst));
    match out {
        SendOutcome::Refused { .. } if u == 0 && k == 0 => Outcome::Pass,
        SendOutcome::Refused { .. } => Outcome::Fail(format!("refused, but {u} typing and {k} key calls were made")),
        SendOutcome::Ran { shell, .. } => Outcome::Fail(format!("ran as {shell:?}: {u} typing and {k} key calls")),
        SendOutcome::Gone => Outcome::Fail("its window is gone".into()),
    }
}

/// Spec 10.5 "Wrong-window guard": focus moves to a second window of its own
/// after the first batch; typing stops and the second window gets nothing.
pub fn focus_stolen_stops_typing(ctx: &mut Ctx) -> Outcome {
    if let Some(s) = no_desktop() {
        return s;
    }
    let (first, _, first_file) = match ctx.open_collector("steal-a", false) {
        Ok(o) => o,
        Err(e) => return Outcome::Fail(e),
    };
    let (second, _, second_file) = match ctx.open_collector("steal-b", false) {
        Ok(o) => o,
        Err(e) => return Outcome::Fail(e),
    };
    let text: String = "0123456789".repeat(10);
    let thief = Wrapped::thief(&ctx.platform, second.window_ref());
    let report = match send_text_on_lane(&thief, first.window_ref(), &text, false) {
        SendOutcome::Ran { report, .. } => report,
        SendOutcome::Refused { shell } => return Outcome::Fail(format!("refused as {shell:?}")),
        SendOutcome::Gone => return Outcome::Fail("its window is gone".into()),
    };
    ctx.stop_collectors(&[&first_file, &second_file]);
    let mut problems = Vec::new();
    if report.error != Some(PlatformError::FocusLost { after_chars: 32 }) {
        problems.push(format!("ended with {:?}, not focus lost after 32 chars", report.error));
    }
    let wait = COLLECT + RESULT_WAIT;
    match wait_result(&first_file, wait) {
        Some(got) if got == text[..32] => {}
        other => problems.push(format!("the first window got {other:?}, not the first 32 chars")),
    }
    match wait_result(&second_file, wait) {
        Some(got) if got.is_empty() => {}
        other => problems.push(format!("the window that took focus got {other:?}")),
    }
    fail_all(problems)
}

/// Spec 5.5 keys, read back by `[Console]::ReadKey`.
pub fn quick_keys_reach_own_console(ctx: &mut Ctx) -> Outcome {
    if let Some(s) = no_desktop() {
        return s;
    }
    let (w, _, file) = match ctx.open_collector("keys", true) {
        Ok(o) => o,
        Err(e) => return Outcome::Fail(e),
    };
    let chords = [
        KeyChord::plain(Key::Up),
        KeyChord::plain(Key::Down),
        KeyChord::plain(Key::Right),
        KeyChord::plain(Key::Tab),
        KeyChord::shift(Key::Tab),
        KeyChord::plain(Key::Escape),
        KeyChord::plain(Key::Backspace),
        KeyChord::RETURN,
    ];
    let steps: Vec<Step> = std::iter::once(Step::Focus).chain(chords.iter().map(|&c| Step::Key(c))).collect();
    let report = injector::execute(&ctx.platform, w.window_ref(), &steps);
    ctx.stop_collectors(&[&file]);
    if let Some(e) = &report.error {
        return Outcome::Fail(format!("keys: {}", plan_failure(e)));
    }
    let want = "UpArrow+0,DownArrow+0,RightArrow+0,Tab+0,Tab+Shift,Escape+0,Backspace+0,Enter+0";
    match wait_result(&file, COLLECT + RESULT_WAIT) {
        Some(got) if got == want => Outcome::Pass,
        Some(got) => Outcome::Fail(format!("keys arrived as {got:?}, wanted {want:?}")),
        None => Outcome::Fail("the collector wrote nothing".into()),
    }
}

/// Its own pings under `owner`.
fn own_pings(owner: u32) -> Vec<u32> {
    let procs = process_snapshot().unwrap_or_default();
    own::cleanup_targets(owner, &procs).into_iter().filter(|p| exe_stem(&p.exe) == "ping").map(|p| p.pid).collect()
}

/// Ctrl+C to its own console running `ping -n 120 127.0.0.1`: the ping ends.
pub fn ctrl_c_stops_ping(ctx: &mut Ctx) -> Outcome {
    if let Some(s) = no_desktop() {
        return s;
    }
    let w = match ctx
        .open_conhost("ping console", "ping", |m| format!(r#"cmd.exe /K "title {m} & ping -n 120 127.0.0.1""#))
    {
        Ok(w) => w,
        Err(e) => return Outcome::Fail(e),
    };
    if !wait_until(OPEN_WAIT, || !own_pings(w.pid).is_empty()) {
        return Outcome::Fail(format!("no ping under its console:\n{}", process_tree(w.pid)));
    }
    let report =
        injector::execute(&ctx.platform, w.window_ref(), &[Step::Focus, Step::Key(KeyChord::ctrl(Key::Letter('c')))]);
    if let Some(e) = &report.error {
        return Outcome::Fail(format!("ctrl+c: {}", plan_failure(e)));
    }
    if wait_until(Duration::from_secs(3), || own_pings(w.pid).is_empty()) {
        Outcome::Pass
    } else {
        Outcome::Fail(format!("ping still running 3 s after ctrl+c:\n{}", process_tree(w.pid)))
    }
}

/// Spec 5.4 step 2b on a real desktop: `Quip.exe --input-probe`, started one
/// integrity level BELOW this run, types at a collector of this run's own.
/// The injector must refuse, and the collector must get nothing.
pub fn elevated_target_types_nothing(ctx: &mut Ctx) -> Outcome {
    if let Some(s) = no_desktop() {
        return s;
    }
    let own_rid = ctx.platform.own_rid();
    let Some(lower) = one_below(own_rid) else {
        return Outcome::Fail(format!("no level below this run's own ({own_rid:#x})"));
    };
    let (w, marker, file) = match ctx.open_collector("probe", false) {
        Ok(o) => o,
        Err(e) => return Outcome::Fail(e),
    };
    if let Err(e) = ctx.front(w.window_ref()) {
        return Outcome::Fail(format!("could not put the collector in front: {e}"));
    }
    let cmd = format!("\"{}\" --input-probe {marker}", ctx.probe_exe.display());
    let mut child = match spawn_at_integrity(&cmd, lower) {
        Ok(c) => c,
        Err(e) => {
            return Outcome::Fail(format!("cannot start the probe at {lower:#x} (this run is {own_rid:#x}): {e}"))
        }
    };
    // SAFETY: a live process handle owned by `child`.
    let waited = unsafe { WaitForSingleObject(child.process.0, PROBE_WAIT.as_millis() as u32) };
    if waited.0 != 0 {
        return Outcome::Fail(format!("the probe (pid {}) did not exit in {} s", child.pid, PROBE_WAIT.as_secs()));
    }
    ctx.stop_collectors(&[&file]);
    let mut out = String::new();
    let _ = child.output.read_to_string(&mut out);
    let line = out.lines().find(|l| l.starts_with("access=")).unwrap_or(out.trim()).to_string();
    ctx.notes.push(format!("probe at {lower:#x} under {own_rid:#x}: {line}"));
    let mut problems = Vec::new();
    if !line.contains("injector=input blocked") {
        problems.push(format!("the injector did not refuse: {out:?}"));
    }
    match wait_result(&file, COLLECT + RESULT_WAIT) {
        Some(got) if got.is_empty() => {}
        other => problems.push(format!("the collector got {other:?}")),
    }
    fail_all(problems)
}

/// A Windows Terminal window of its own whose PowerShell tab reads a line:
/// the marker with emoji, then Return, reads back. SKIP without `wt.exe`.
pub fn windows_terminal_types_and_reads_back(ctx: &mut Ctx) -> Outcome {
    if let Some(s) = no_desktop() {
        return s;
    }
    if !on_path("wt.exe") {
        return Outcome::Skip("wt.exe is not installed".into());
    }
    let dir = match ctx.run_dir() {
        Ok(d) => d,
        Err(e) => return Outcome::Fail(e),
    };
    let before = match ctx.handles() {
        Ok(h) => h,
        Err(e) => return Outcome::Fail(e),
    };
    let m = ctx.new_marker("wt-type");
    let d = dir.display().to_string();
    let script = format!(
        "$Host.UI.RawUI.WindowTitle='{m}'; 'ready' | Out-File -FilePath '{d}\\{m}-ready.txt'; $r = Read-Host; $r | Out-File -Encoding utf8 -FilePath '{d}\\{m}.txt'"
    );
    // wt.exe splits its own command line at every `;` (a new-tab
    // separator) unless it is written `\;`.
    let script = script.replace(';', "\\;");
    let index = ctx.expect("Windows Terminal", &m, WT_CLASS, false);
    let launched = Command::new("wt.exe")
        .args(["-w", "new", "powershell.exe", "-NoLogo", "-NoProfile", "-NoExit", "-Command", &script])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if let Err(e) = launched {
        return Outcome::Fail(format!("cannot run wt.exe: {e}"));
    }
    let Some(w) = ctx.wait_new(&before, WT_OPEN_WAIT, |w| w.class_name == WT_CLASS && own::has_marker(&w.title, &m))
    else {
        return Outcome::Fail(format!("no new Windows Terminal window titled {m} in {} s", WT_OPEN_WAIT.as_secs()));
    };
    ctx.claim(index, &w);
    if wait_result(&dir.join(format!("{m}-ready.txt")), READY_WAIT).is_none() {
        return Outcome::Fail("its tab never got ready".into());
    }
    sleep(SETTLE);
    read_back(ctx, &w, &dir.join(format!("{m}.txt")), &marker_text(&m))
}
