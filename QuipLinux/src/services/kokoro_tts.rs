use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;

/// Debug log to /tmp/quip-kokoro.log (mirrors Mac behaviour).
fn debug_log(msg: &str) {
    use std::io::Write as _;
    let line = format!("[{}] {}\n", chrono_stamp(), msg);
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/quip-kokoro.log")
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn chrono_stamp() -> String {
    // Simple monotonic-ish stamp without pulling in chrono
    let d = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:03}", d.as_secs(), d.subsec_millis())
}

/// Python venv location on Linux: ~/.local/share/quip/venv
fn venv_python() -> PathBuf {
    directories::ProjectDirs::from("dev", "quip", "quip")
        .map(|d| d.data_dir().join("venv/bin/python3"))
        .unwrap_or_else(|| {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
            PathBuf::from(home).join(".local/share/quip/venv/bin/python3")
        })
}

/// Path to the bundled kokoro_tts.py script (next to the binary).
fn script_path() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    // Check several locations relative to binary
    let candidates = [
        // AppImage / installed: next to the binary
        dir.join("kokoro_tts.py"),
        // Packaged: /usr/share/quip/kokoro_tts.py when bin is /usr/bin
        dir.join("../share/quip/kokoro_tts.py"),
        // Development build: QuipLinux/target/debug|release/.. -> QuipLinux/Resources
        dir.join("../../Resources/kokoro_tts.py"),
        // Workspace-style (repo-root/target/...): repo-root/QuipLinux/Resources
        dir.join("../../QuipLinux/Resources/kokoro_tts.py"),
    ];
    for c in &candidates {
        if c.exists() {
            return Some(c.canonicalize().unwrap_or(c.clone()));
        }
    }
    None
}

/// Manages a persistent Python Kokoro TTS daemon process.
/// Serialises synthesis requests through a dedicated thread.
pub struct KokoroTTS {
    /// Send synthesis requests to the worker thread.
    req_tx: mpsc::Sender<SynthRequest>,
}

struct SynthRequest {
    text: String,
    on_chunk: Box<dyn FnMut(Vec<u8>) + Send>,
    on_complete: Box<dyn FnOnce() + Send>,
}

impl KokoroTTS {
    /// Check whether the venv + script exist (TTS can potentially work).
    pub fn is_available() -> bool {
        venv_python().exists() && script_path().is_some()
    }

    /// Create and start the background worker thread that owns the daemon process.
    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel::<SynthRequest>();

        std::thread::Builder::new()
            .name("kokoro-tts".into())
            .spawn(move || {
                worker_loop(rx);
            })
            .expect("failed to spawn kokoro-tts thread");

        Self { req_tx: tx }
    }

    /// Pre-warm the daemon (load model) so first real synth is fast.
    pub fn preload(&self) {
        // Send a no-op request — the worker will ensure the daemon is running.
        let _ = self.req_tx.send(SynthRequest {
            text: String::new(),
            on_chunk: Box::new(|_| {}),
            on_complete: Box::new(|| {}),
        });
    }

    /// Queue a synthesis request. `on_chunk` is called for each WAV sentence chunk,
    /// `on_complete` fires when the stream ends (or on error).
    pub fn synthesize<F, G>(&self, text: String, on_chunk: F, on_complete: G)
    where
        F: FnMut(Vec<u8>) + Send + 'static,
        G: FnOnce() + Send + 'static,
    {
        let _ = self.req_tx.send(SynthRequest {
            text,
            on_chunk: Box::new(on_chunk),
            on_complete: Box::new(on_complete),
        });
    }
}

// ---------------------------------------------------------------------------
// Worker thread — owns the daemon child process
// ---------------------------------------------------------------------------

fn worker_loop(rx: mpsc::Receiver<SynthRequest>) {
    let mut daemon: Option<DaemonHandle> = None;

    while let Ok(req) = rx.recv() {
        // Empty text = preload only
        if req.text.is_empty() {
            ensure_daemon(&mut daemon);
            (req.on_complete)();
            continue;
        }

        if !ensure_daemon(&mut daemon) {
            debug_log("synth skipped — daemon not available");
            (req.on_complete)();
            continue;
        }

        let handle = daemon.as_mut().unwrap();
        run_synthesis(handle, &req.text, req.on_chunk, req.on_complete);
    }

    // Clean up daemon on thread exit
    if let Some(mut d) = daemon {
        let _ = d.child.kill();
    }
}

struct DaemonHandle {
    child: Child,
    stdin: std::process::ChildStdin,
    stdout: std::process::ChildStdout,
}

fn ensure_daemon(daemon: &mut Option<DaemonHandle>) -> bool {
    // Check if existing daemon is still alive
    if let Some(d) = daemon.as_mut() {
        match d.child.try_wait() {
            Ok(None) => return true, // still running
            Ok(Some(status)) => {
                debug_log(&format!("daemon exited with {status}"));
                *daemon = None;
            }
            Err(e) => {
                debug_log(&format!("daemon check error: {e}"));
                *daemon = None;
            }
        }
    }

    let python = venv_python();
    if !python.exists() {
        debug_log(&format!("no venv at {}", python.display()));
        return false;
    }
    let script = match script_path() {
        Some(s) => s,
        None => {
            debug_log("no bundled kokoro_tts.py found");
            return false;
        }
    };

    debug_log(&format!("launching daemon: {} {} --daemon --voice af_heart", python.display(), script.display()));

    let mut child = match Command::new(&python)
        .args([script.to_str().unwrap(), "--daemon", "--voice", "af_heart"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            debug_log(&format!("failed to launch daemon: {e}"));
            return false;
        }
    };

    let stdin = child.stdin.take().expect("stdin piped");
    let stdout = child.stdout.take().expect("stdout piped");

    // Drain stderr in a background thread so it doesn't block
    if let Some(mut stderr) = child.stderr.take() {
        std::thread::Builder::new()
            .name("kokoro-stderr".into())
            .spawn(move || {
                let mut buf = [0u8; 4096];
                loop {
                    match stderr.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            let s = String::from_utf8_lossy(&buf[..n]);
                            let trimmed = s.trim();
                            if !trimmed.is_empty() {
                                debug_log(&format!("daemon stderr: {trimmed}"));
                            }
                        }
                        Err(_) => break,
                    }
                }
            })
            .ok();
    }

    let pid = child.id();
    debug_log(&format!("daemon launched pid={pid}"));

    *daemon = Some(DaemonHandle { child, stdin, stdout });
    true
}

fn run_synthesis(
    handle: &mut DaemonHandle,
    text: &str,
    mut on_chunk: Box<dyn FnMut(Vec<u8>) + Send>,
    on_complete: Box<dyn FnOnce() + Send>,
) {
    let text_bytes = text.as_bytes();
    let len = text_bytes.len() as u32;

    // Write length-prefixed request
    if handle.stdin.write_all(&len.to_be_bytes()).is_err()
        || handle.stdin.write_all(text_bytes).is_err()
        || handle.stdin.flush().is_err()
    {
        debug_log("stdin write failed — daemon may be dead");
        on_complete();
        return;
    }

    // Read chunks until 0-length marker
    let mut chunk_count = 0u32;
    loop {
        let mut hdr = [0u8; 4];
        if read_exact(&mut handle.stdout, &mut hdr).is_err() {
            debug_log("short header read — daemon died");
            let _ = handle.child.kill();
            on_complete();
            return;
        }

        let chunk_len = u32::from_be_bytes(hdr) as usize;
        if chunk_len == 0 {
            debug_log(&format!("stream complete, {chunk_count} chunks"));
            on_complete();
            return;
        }

        let mut wav = vec![0u8; chunk_len];
        if read_exact(&mut handle.stdout, &mut wav).is_err() {
            debug_log("premature EOF in chunk body — daemon died");
            let _ = handle.child.kill();
            on_complete();
            return;
        }

        chunk_count += 1;
        debug_log(&format!("chunk {chunk_count}, {} bytes", wav.len()));
        on_chunk(wav);
    }
}

/// Read exactly `buf.len()` bytes, retrying on partial reads.
fn read_exact(reader: &mut impl Read, buf: &mut [u8]) -> std::io::Result<()> {
    let mut filled = 0;
    while filled < buf.len() {
        match reader.read(&mut buf[filled..]) {
            Ok(0) => return Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "EOF")),
            Ok(n) => filled += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
