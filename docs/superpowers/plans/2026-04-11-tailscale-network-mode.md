# Tailscale Network Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Network Mode" picker to Quip's Settings → Connection tab with three options — Cloudflare Tunnel (default), Tailscale, Local only — where Tailscale mode auto-detects the Mac's MagicDNS hostname via the `tailscale status --json` CLI and gives the phone a stable WebSocket URL that never changes across Mac restarts.

**Architecture:** A new `NetworkMode` enum replaces the existing `localOnlyMode` toggle and is persisted in `@AppStorage`. A new `TailscaleService` class (observable, MainActor, follows the same pattern as `BonjourAdvertiser` and `CloudflareTunnel`) shells out to the Tailscale CLI on a background queue, parses JSON, and publishes `hostname` / `webSocketURL` / `isAvailable` / `lastError` for the UI to observe. `QuipMacApp` gains a single `applyNetworkMode()` helper that routes between cloudflared, Tailscale, and local-only paths. `MainWindow` and `ConnectionTab` read the mode and switch between URL sources. On iOS, `isURLTrusted()` gains `*.ts.net` and `100.64.0.0/10` CGNAT cases so the phone silently trusts tailnet URLs.

**Tech Stack:** Swift 6 / SwiftUI / Observation / AppKit (NSWorkspace.didActivateApplicationNotification), Xcode 16, macOS 14+, iOS. No test scaffolding exists in the repo; verification is build + manual spot checks.

**Important — no automated tests:** The Quip codebase has no Swift unit test target. Each task ends with `xcodebuild build` as the correctness gate, followed by manual verification where it makes sense. The final task (Task 8) is a full manual verification pass against the spec's checklist.

**Spec:** `docs/superpowers/specs/2026-04-11-tailscale-network-mode-design.md`

---

## File Structure

- **New:** `QuipMac/Services/NetworkMode.swift` — `NetworkMode` enum + one migration helper.
- **New:** `QuipMac/Services/TailscaleService.swift` — `@Observable @MainActor` class. One public `refresh()`, one public `stop()`. Private CLI locator, process runner, JSON parser.
- **Modify:** `QuipMac/QuipMacApp.swift` — instantiate `TailscaleService`, add `@AppStorage("networkMode")`, add `applyNetworkMode()` helper, wire migration, replace the existing `onChange(of: localOnlyMode)` block, add `didActivateApplicationNotification` observer for re-detection.
- **Modify:** `QuipMac/Views/SettingsView.swift` — `ConnectionTab` gets a Picker, a conditional Tailscale subview, and adaptive caption. Injects the new `TailscaleService` from environment.
- **Modify:** `QuipMac/Views/MainWindow.swift` — `tunnelQRPopover` and `tunnelStatus` switch on `networkMode` (three branches). Reads `TailscaleService` from environment.
- **Modify:** `QuipiOS/QuipApp.swift` — `isURLTrusted()` gains two new trust cases; `doConnect()` scheme-default branch for `.ts.net` / `100.x.x.x`.

---

### Task 1: Create NetworkMode enum

**Files:**
- Create: `QuipMac/Services/NetworkMode.swift`

- [ ] **Step 1: Create the enum file**

Create `QuipMac/Services/NetworkMode.swift` with exactly these contents:

```swift
// NetworkMode.swift
// QuipMac — Enumerates the three mutually-exclusive ways the Mac can expose
// its WebSocket server to the phone: via a Cloudflare quick tunnel, via
// Tailscale, or local-only (LAN).

import Foundation

enum NetworkMode: String, CaseIterable, Identifiable {
    case cloudflareTunnel
    case tailscale
    case localOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloudflareTunnel: return "Cloudflare Tunnel"
        case .tailscale:        return "Tailscale"
        case .localOnly:        return "Local only"
        }
    }
}

/// One-time migration from the legacy `localOnlyMode` boolean to `networkMode`.
/// Idempotent — safe to call on every launch. Returns the resolved mode.
@MainActor
func migrateNetworkModeIfNeeded() -> NetworkMode {
    let defaults = UserDefaults.standard
    if let raw = defaults.string(forKey: "networkMode"),
       let mode = NetworkMode(rawValue: raw) {
        return mode
    }
    // First launch after the update — derive from legacy key.
    let legacyLocalOnly = defaults.bool(forKey: "localOnlyMode")
    let resolved: NetworkMode = legacyLocalOnly ? .localOnly : .cloudflareTunnel
    defaults.set(resolved.rawValue, forKey: "networkMode")
    return resolved
}
```

- [ ] **Step 2: Add the file to the Xcode target**

The QuipMac project uses `project.yml` with `createIntermediateGroups: true` and a glob source path of `.`, so dropping the file into `QuipMac/Services/` picks it up automatically on the next build. No manual Xcode project file edits needed.

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
cd "/Volumes/Extreme SSD/Quip/QuipMac" && xcodebuild -project QuipMac.xcodeproj -scheme QuipMac -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd "/Volumes/Extreme SSD/Quip" && git add QuipMac/Services/NetworkMode.swift && git commit -m "$(cat <<'EOF'
Added the little switchboard that tells the Mac which way the phone should dial in — the cloud tunnel, Tailscale, or just the house network.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Create TailscaleService skeleton

**Files:**
- Create: `QuipMac/Services/TailscaleService.swift`

- [ ] **Step 1: Create the skeleton**

Create `QuipMac/Services/TailscaleService.swift` with the observable class, stub methods, and no logic yet. This task only gets the types in place so the rest of the app can reference them. Task 3 fills in the CLI detection body.

```swift
// TailscaleService.swift
// QuipMac — Detects the Mac's Tailscale hostname by shelling out to the
// `tailscale status --json` CLI. Exposes an observable `webSocketURL` built
// from the MagicDNS name (or the 100.x IP as a fallback) and the configured
// WebSocket port. One-shot detection — refresh() is called on app launch,
// on network-mode change, on app activation, and from a manual "Re-detect"
// button in the Connection settings tab.

import Foundation
import Observation

@MainActor
@Observable
final class TailscaleService {

    /// Detected (or overridden) hostname, e.g. "quip-mac.tail1234.ts.net" or "100.64.1.2".
    var hostname: String = ""

    /// Full WebSocket URL clients should use, e.g. "ws://quip-mac.tail1234.ts.net:8765".
    /// Empty when not available.
    var webSocketURL: String = ""

    /// True when we have a usable hostname (either auto-detected or manually overridden).
    var isAvailable: Bool = false

    /// Human-readable error message when detection fails. nil when OK.
    var lastError: String? = nil

    /// Trigger a fresh detection pass. Safe to call repeatedly.
    func refresh() {
        // Filled in by Task 3.
    }

    /// Clear all published state so the UI doesn't show a stale URL after
    /// switching away from Tailscale mode.
    func stop() {
        hostname = ""
        webSocketURL = ""
        isAvailable = false
        lastError = nil
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd "/Volumes/Extreme SSD/Quip/QuipMac" && xcodebuild -project QuipMac.xcodeproj -scheme QuipMac -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd "/Volumes/Extreme SSD/Quip" && git add QuipMac/Services/TailscaleService.swift && git commit -m "$(cat <<'EOF'
Stubbed out the Tailscale scout — just the holder for the hostname and URL so the rest of the Mac app can plug into it. The actual detective work comes next.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Implement TailscaleService CLI detection

**Files:**
- Modify: `QuipMac/Services/TailscaleService.swift`

- [ ] **Step 1: Replace the whole file with the real implementation**

Overwrite `QuipMac/Services/TailscaleService.swift` with:

```swift
// TailscaleService.swift
// QuipMac — Detects the Mac's Tailscale hostname by shelling out to the
// `tailscale status --json` CLI. Exposes an observable `webSocketURL` built
// from the MagicDNS name (or the 100.x IP as a fallback) and the configured
// WebSocket port. One-shot detection — refresh() is called on app launch,
// on network-mode change, on app activation, and from a manual "Re-detect"
// button in the Connection settings tab.

import Foundation
import Observation

@MainActor
@Observable
final class TailscaleService {

    var hostname: String = ""
    var webSocketURL: String = ""
    var isAvailable: Bool = false
    var lastError: String? = nil

    /// Generation counter — increments on every refresh() call so in-flight
    /// background detections can tell if they've been superseded before
    /// publishing their results.
    private var generation: Int = 0

    /// Hardcoded candidate paths for the Tailscale CLI. Checked in order.
    private static let cliCandidates: [String] = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// Default WebSocket port — matches the @AppStorage("wsPort") default used
    /// elsewhere in the app. Read fresh on each refresh().
    private static let defaultPort: Int = 8765

    func refresh() {
        generation += 1
        let myGen = generation

        // Path 1: manual override wins — skip the CLI entirely.
        let override = UserDefaults.standard.string(forKey: "tailscaleHostnameOverride") ?? ""
        let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOverride.isEmpty {
            let port = UserDefaults.standard.integer(forKey: "wsPort")
            publish(
                hostname: trimmedOverride,
                port: port > 0 ? port : Self.defaultPort,
                error: nil,
                generation: myGen
            )
            return
        }

        // Path 2: auto-detect — run the CLI off the main actor.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.detectViaCLI()
            await MainActor.run {
                guard let self else { return }
                // Bail if a newer refresh() has been started.
                guard self.generation == myGen else { return }
                switch result {
                case .success(let detectedHost):
                    let port = UserDefaults.standard.integer(forKey: "wsPort")
                    self.publish(
                        hostname: detectedHost,
                        port: port > 0 ? port : Self.defaultPort,
                        error: nil,
                        generation: myGen
                    )
                case .failure(let message):
                    self.hostname = ""
                    self.webSocketURL = ""
                    self.isAvailable = false
                    self.lastError = message
                }
            }
        }
    }

    func stop() {
        generation += 1
        hostname = ""
        webSocketURL = ""
        isAvailable = false
        lastError = nil
    }

    // MARK: - Private

    private func publish(hostname: String, port: Int, error: String?, generation myGen: Int) {
        guard self.generation == myGen else { return }
        self.hostname = hostname
        self.webSocketURL = "ws://\(hostname):\(port)"
        self.isAvailable = true
        self.lastError = error
    }

    /// Runs on a background task. Locates the CLI, shells out to
    /// `tailscale status --json`, parses the response, returns either a
    /// detected hostname or a human-readable error message.
    private nonisolated static func detectViaCLI() -> Result<String, String> {
        // 1. Locate the CLI.
        let fm = FileManager.default
        let cliPath = cliCandidates.first { path in
            fm.isExecutableFile(atPath: path)
        }
        guard let cli = cliPath else {
            return .failure("Tailscale not installed — install from tailscale.com")
        }

        // 2. Shell out with a 3-second timeout.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure("Failed to run Tailscale CLI: \(error.localizedDescription)")
        }

        // Manual 3s timeout — Process has no built-in.
        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .failure("Tailscale CLI timed out — is the daemon running?")
        }

        guard process.terminationStatus == 0 else {
            return .failure("Tailscale not running or not logged in")
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return .failure("Tailscale CLI returned no output")
        }

        // 3. Parse JSON and extract the Self node's DNSName or first TailscaleIP.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = json["Self"] as? [String: Any] else {
            return .failure("Could not parse Tailscale status JSON")
        }

        if let dnsName = selfNode["DNSName"] as? String, !dnsName.isEmpty {
            // DNSName includes a trailing dot (e.g. "quip-mac.tail1234.ts.net.") — strip it.
            var trimmed = dnsName
            if trimmed.hasSuffix(".") {
                trimmed.removeLast()
            }
            return .success(trimmed)
        }

        if let ips = selfNode["TailscaleIPs"] as? [String], let first = ips.first, !first.isEmpty {
            return .success(first)
        }

        return .failure("No Tailscale identity found — try logging in")
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd "/Volumes/Extreme SSD/Quip/QuipMac" && xcodebuild -project QuipMac.xcodeproj -scheme QuipMac -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd "/Volumes/Extreme SSD/Quip" && git add QuipMac/Services/TailscaleService.swift && git commit -m "$(cat <<'EOF'
Taught the Tailscale scout how to actually sniff out the hostname — pokes the Tailscale CLI with a stick, waits three seconds, digs the MagicDNS name outta the JSON, falls back to the 100-dot-somethin' IP if there ain't one. Manual override skips the whole song and dance.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Wire TailscaleService into QuipMacApp

**Files:**
- Modify: `QuipMac/QuipMacApp.swift`

- [ ] **Step 1: Add the service instance and networkMode state**

Open `QuipMac/QuipMacApp.swift`. Find the top of the `QuipMacApp` struct (around lines 4–13). Replace the block:

```swift
@main
struct QuipMacApp: App {
    @State private var windowManager = WindowManager()
    @State private var webSocketServer = WebSocketServer()
    @State private var bonjourAdvertiser = BonjourAdvertiser()
    @State private var terminalStateDetector = TerminalStateDetector()
    @State private var terminalColorManager = TerminalColorManager()
    @State private var keystrokeInjector = KeystrokeInjector()
    @State private var tunnel = CloudflareTunnel()
    @State private var pinManager = PINManager()
    @AppStorage("localOnlyMode") private var localOnlyMode = false
```

with:

```swift
@main
struct QuipMacApp: App {
    @State private var windowManager = WindowManager()
    @State private var webSocketServer = WebSocketServer()
    @State private var bonjourAdvertiser = BonjourAdvertiser()
    @State private var terminalStateDetector = TerminalStateDetector()
    @State private var terminalColorManager = TerminalColorManager()
    @State private var keystrokeInjector = KeystrokeInjector()
    @State private var tunnel = CloudflareTunnel()
    @State private var tailscale = TailscaleService()
    @State private var pinManager = PINManager()
    @AppStorage("networkMode") private var networkModeRaw: String = NetworkMode.cloudflareTunnel.rawValue
```

Rationale: `localOnlyMode` is gone from the view state. `networkModeRaw` is a String because `@AppStorage` doesn't support enum storage directly; we decode it via a computed helper below.

- [ ] **Step 2: Add the computed networkMode helper**

Immediately after the `@AppStorage("networkMode")` line (inside the struct, before `var body`), insert:

```swift
    private var networkMode: NetworkMode {
        NetworkMode(rawValue: networkModeRaw) ?? .cloudflareTunnel
    }
```

- [ ] **Step 3: Inject the TailscaleService into each scene's environment**

Still in `QuipMacApp.swift`, find the three scene blocks (`WindowGroup`, `MenuBarExtra`, `Settings`). Each has a chain of `.environment(...)` modifiers. Add `.environment(tailscale)` to each scene's chain right after `.environment(tunnel)`.

Scene 1 — `WindowGroup` body should become:

```swift
        WindowGroup {
            MainWindow()
                .environment(windowManager)
                .environment(webSocketServer)
                .environment(bonjourAdvertiser)
                .environment(terminalStateDetector)
                .environment(terminalColorManager)
                .environment(keystrokeInjector)
                .environment(tunnel)
                .environment(tailscale)
                .onAppear { startServicesOnce() }
                .onChange(of: networkModeRaw) { _, _ in
                    applyNetworkMode()
                }
        }
```

Note: the old `.onChange(of: localOnlyMode) { _, isLocalOnly in ... }` block is replaced by the simpler `.onChange(of: networkModeRaw)` that calls `applyNetworkMode()`.

Scene 2 — `MenuBarExtra`:

```swift
        MenuBarExtra("Quip", systemImage: "waveform.circle.fill") {
            MenuBarView()
                .environment(windowManager)
                .environment(webSocketServer)
                .environment(bonjourAdvertiser)
                .environment(tunnel)
                .environment(tailscale)
                .onAppear { startServicesOnce() }
        }
        .menuBarExtraStyle(.window)
```

Scene 3 — `Settings`:

```swift
        Settings {
            SettingsView()
                .environment(windowManager)
                .environment(webSocketServer)
                .environment(bonjourAdvertiser)
                .environment(tunnel)
                .environment(tailscale)
                .environment(pinManager)
        }
```

- [ ] **Step 4: Add applyNetworkMode() and rework startServicesOnce()**

Find the existing `startServicesOnce()` method (around lines 83–101). Replace the entire method body with:

```swift
    @State private var servicesStarted = false

    private func startServicesOnce() {
        guard !servicesStarted else { return }
        servicesStarted = true

        // One-time migration from legacy localOnlyMode bool to networkMode enum.
        let migrated = migrateNetworkModeIfNeeded()
        if networkModeRaw != migrated.rawValue {
            networkModeRaw = migrated.rawValue
        }

        webSocketServer.pinManager = pinManager
        let requirePIN = UserDefaults.standard.bool(forKey: "requirePINForLocal")
        webSocketServer.requireAuth = requirePIN
        webSocketServer.start()

        // Apply current network mode (starts tunnel or Tailscale as needed).
        applyNetworkMode()

        // Small delay to let WebSocket listener reach .ready before advertising
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            bonjourAdvertiser.startAdvertising()
        }

        // Re-detect Tailscale whenever another app activates — cheap way to
        // pick up the case where the user opened the Tailscale app while Quip
        // was already running and hadn't yet logged in.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if networkMode == .tailscale {
                    tailscale.refresh()
                }
            }
        }
    }

    /// Switch between Cloudflare tunnel, Tailscale, and local-only based on
    /// the current `networkMode`. Safe to call repeatedly — each branch is
    /// idempotent on its own dependencies.
    @MainActor
    private func applyNetworkMode() {
        let requirePIN = UserDefaults.standard.bool(forKey: "requirePINForLocal")
        webSocketServer.requireAuth = requirePIN

        switch networkMode {
        case .cloudflareTunnel:
            tailscale.stop()
            tunnel.webSocketServer = webSocketServer
            tunnel.start()
        case .tailscale:
            tunnel.stop()
            tailscale.refresh()
        case .localOnly:
            tunnel.stop()
            tailscale.stop()
        }
    }
```

**Gotcha:** the `NotificationCenter.addObserver` closure captures `networkMode` and `tailscale` — both are MainActor-isolated. Wrap the body in `Task { @MainActor in ... }` exactly as shown above so the compiler accepts the capture.

**Gotcha 2:** `NSWorkspace.didActivateApplicationNotification` is in AppKit. `QuipMacApp.swift` already imports `SwiftUI`, which re-exports enough for the symbol to resolve on macOS. If the compiler complains, add `import AppKit` at the top of the file.

- [ ] **Step 5: Build to verify**

Run:
```bash
cd "/Volumes/Extreme SSD/Quip/QuipMac" && xcodebuild -project QuipMac.xcodeproj -scheme QuipMac -configuration Debug build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. If errors mention missing `AppKit`, add `import AppKit` to line 2 of `QuipMacApp.swift` and rebuild.

- [ ] **Step 6: Commit**

```bash
cd "/Volumes/Extreme SSD/Quip" && git add QuipMac/QuipMacApp.swift && git commit -m "$(cat <<'EOF'
Hooked up the new switchboard in the main app — on startup it checks the old lil localOnlyMode lever, flips it over to the new three-way picker, and fires up the cloud tunnel or the Tailscale scout dependin' on what you picked. Also listens for when you open the Tailscale app so it can re-sniff the hostname right then.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Update Connection tab UI

**Files:**
- Modify: `QuipMac/Views/SettingsView.swift`

- [ ] **Step 1: Replace the ConnectionTab struct**

Open `QuipMac/Views/SettingsView.swift`. Find the `ConnectionTab` private struct (around lines 297–377). Replace its entire body with:

```swift
private struct ConnectionTab: View {
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser
    @Environment(TailscaleService.self) private var tailscale

    @AppStorage("wsPort") private var port: Int = 8765
    @AppStorage("bonjourServiceName") private var serviceName: String = "Quip"
    @AppStorage("networkMode") private var networkModeRaw: String = NetworkMode.cloudflareTunnel.rawValue
    @AppStorage("tailscaleHostnameOverride") private var tailscaleOverride: String = ""
    @AppStorage("requirePINForLocal") private var requirePINForLocal = false
    @State private var logEntries: [String] = []

    private var networkMode: NetworkMode {
        NetworkMode(rawValue: networkModeRaw) ?? .cloudflareTunnel
    }

    private var modeCaption: String {
        switch networkMode {
        case .cloudflareTunnel:
            return "Cloudflare tunnel enables connections from anywhere. Local connections always require PIN when tunnel is active."
        case .tailscale:
            return "Both devices must be on your Tailscale network. The URL stays stable across restarts."
        case .localOnly:
            return "Clients must be on the same network. QR code shows local address."
        }
    }

    var body: some View {
        Form {
            Section("WebSocket Server") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(webSocketServer.isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(webSocketServer.isRunning ? "Running" : "Stopped")
                    }
                }

                LabeledContent("Connected Clients") {
                    Text("\(webSocketServer.connectedClientCount)")
                        .monospacedDigit()
                }

                TextField("Port", value: $port, format: .number)
                    .frame(width: 100)
            }

            Section("Bonjour Discovery") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bonjourAdvertiser.isAdvertising ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(bonjourAdvertiser.isAdvertising ? "Advertising" : "Stopped")
                    }
                }

                TextField("Service Name", text: $serviceName)
            }

            Section("Network Mode") {
                Picker("Network Mode", selection: $networkModeRaw) {
                    ForEach(NetworkMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(modeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if networkMode == .tailscale {
                    LabeledContent("Hostname") {
                        if tailscale.hostname.isEmpty {
                            Text("Not detected")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text(tailscale.hostname)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    Button {
                        tailscale.refresh()
                    } label: {
                        Label("Re-detect", systemImage: "arrow.clockwise")
                    }

                    TextField("Hostname override (optional)", text: $tailscaleOverride)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tailscaleOverride) { _, _ in
                            tailscale.refresh()
                        }

                    if let err = tailscale.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Toggle("Require PIN for local connections", isOn: $requirePINForLocal)
            }

            Section("Connection Log") {
                if logEntries.isEmpty {
                    Text("No recent activity")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(logEntries, id: \.self) { entry in
                                Text(entry)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd "/Volumes/Extreme SSD/Quip/QuipMac" && xcodebuild -project QuipMac.xcodeproj -scheme QuipMac -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd "/Volumes/Extreme SSD/Quip" && git add QuipMac/Views/SettingsView.swift && git commit -m "$(cat <<'EOF'
Tore out the old on-off toggle in the Connection settings and put a three-way picker in its place — cloud tunnel, Tailscale, or just local. When you pick Tailscale it shows you the hostname it sniffed out plus an override box if you wanna type one in yourself.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Update MainWindow status bar and QR popover

**Files:**
- Modify: `QuipMac/Views/MainWindow.swift`

- [ ] **Step 1: Add TailscaleService and networkMode to the view**

Open `QuipMac/Views/MainWindow.swift`. Find the environment/AppStorage block at lines 7–13. Replace:

```swift
struct MainWindow: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser
    @Environment(CloudflareTunnel.self) private var tunnel

    @AppStorage("localOnlyMode") private var localOnlyMode = false
```

with:

```swift
struct MainWindow: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser
    @Environment(CloudflareTunnel.self) private var tunnel
    @Environment(TailscaleService.self) private var tailscale

    @AppStorage("networkMode") private var networkModeRaw: String = NetworkMode.cloudflareTunnel.rawValue

    private var networkMode: NetworkMode {
        NetworkMode(rawValue: networkModeRaw) ?? .cloudflareTunnel
    }
```

- [ ] **Step 2: Replace tunnelQRPopover with three-way branching**

Find the existing `tunnelQRPopover` computed property (lines 163–202). Replace the whole property with:

```swift
    // MARK: - QR Popover

    private var tunnelQRPopover: some View {
        let qrURL: String = {
            switch networkMode {
            case .cloudflareTunnel: return tunnel.webSocketURL
            case .tailscale:        return tailscale.webSocketURL
            case .localOnly:        return localWSURL
            }
        }()

        return VStack(spacing: 12) {
            if networkMode == .cloudflareTunnel && qrURL.isEmpty {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for tunnel...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if networkMode == .tailscale && qrURL.isEmpty {
                if let err = tailscale.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Detecting Tailscale...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Scan with iPhone")
                    .font(.headline)

                if let qrImage = generateQR(from: qrURL) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                }

                HStack(spacing: 8) {
                    Text(qrURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(qrURL, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(20)
        .frame(width: 280)
    }
```

- [ ] **Step 3: Replace tunnelStatus with three-way branching**

Find the existing `tunnelStatus` computed property (starts around line 219, originally containing the `localOnlyMode` branch). Replace the whole property with:

```swift
    // MARK: - Tunnel Status

    private var tunnelStatus: some View {
        HStack(spacing: 6) {
            switch networkMode {
            case .localOnly:
                Image(systemName: "house")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Local only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(localWSURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(localWSURL, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy local URL")

            case .tailscale:
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(tailscale.isAvailable ? .blue : .red)
                if tailscale.isAvailable && !tailscale.webSocketURL.isEmpty {
                    Text(tailscale.webSocketURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tailscale.webSocketURL, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Tailscale URL")
                } else if let err = tailscale.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Detecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .cloudflareTunnel:
                if tunnel.isRunning && !tunnel.webSocketURL.isEmpty {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(tunnel.webSocketURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tunnel.webSocketURL, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy tunnel URL")
                } else if tunnel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting tunnel...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text("Tunnel offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
```

- [ ] **Step 4: Build to verify**

Run:
```bash
cd "/Volumes/Extreme SSD/Quip/QuipMac" && xcodebuild -project QuipMac.xcodeproj -scheme QuipMac -configuration Debug build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
cd "/Volumes/Extreme SSD/Quip" && git add QuipMac/Views/MainWindow.swift && git commit -m "$(cat <<'EOF'
The little status strip and the QR popup on the main window now know about all three modes — slaps up the cloud URL, the Tailscale URL, or the LAN address dependin' on which one you got picked. Tailscale gets its own little network icon.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Update iOS trust and scheme-default

**Files:**
- Modify: `QuipiOS/QuipApp.swift`

- [ ] **Step 1: Extend isURLTrusted to accept Tailscale hosts**

Open `QuipiOS/QuipApp.swift`. Find the `isURLTrusted` function (around lines 958–982). Replace the whole function with:

```swift
    private func isURLTrusted(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let scheme = url.scheme?.lowercased() ?? ""

        // wss:// to *.trycloudflare.com is trusted
        if scheme == "wss" && (host == "trycloudflare.com" || host.hasSuffix(".trycloudflare.com")) {
            return true
        }

        // ws:// to local/private IPs and Tailscale targets is trusted
        if scheme == "ws" {
            if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }

            // Tailscale MagicDNS hostnames (e.g. quip-mac.tail1234.ts.net)
            if host.hasSuffix(".ts.net") { return true }

            // RFC 1918 private ranges + Tailscale CGNAT 100.64.0.0/10
            let parts = host.split(separator: ".").compactMap { UInt8($0) }
            if parts.count == 4 {
                if parts[0] == 10 { return true }                                    // 10.0.0.0/8
                if parts[0] == 172 && (16...31).contains(parts[1]) { return true }   // 172.16.0.0/12
                if parts[0] == 192 && parts[1] == 168 { return true }               // 192.168.0.0/16
                if parts[0] == 169 && parts[1] == 254 { return true }               // 169.254.0.0/16 link-local
                if parts[0] == 100 && (64...127).contains(parts[1]) { return true } // 100.64.0.0/10 Tailscale CGNAT
            }
            return false
        }

        return false
    }
```

**Note:** the only additions are the `.ts.net` suffix check and the CGNAT octet range check. Everything else is identical to the current function.

- [ ] **Step 2: Add scheme-default branch for Tailscale inputs**

Find `doConnect()` in the same file (around lines 935–956). The current URL-normalization logic:

```swift
    private func doConnect() {
        guard !urlText.isEmpty else { return }
        let urlStr: String
        if urlText.hasPrefix("wss://") || urlText.hasPrefix("ws://") {
            urlStr = urlText
        } else if urlText.contains("trycloudflare.com") {
            urlStr = "wss://\(urlText)"
        } else if urlText.contains(":") {
            urlStr = "ws://\(urlText)"
        } else {
            urlStr = "wss://\(urlText)"
        }
```

Replace the whole `let urlStr: String = { ... }` block with:

```swift
    private func doConnect() {
        guard !urlText.isEmpty else { return }
        let urlStr: String
        if urlText.hasPrefix("wss://") || urlText.hasPrefix("ws://") {
            urlStr = urlText
        } else if urlText.contains("trycloudflare.com") {
            urlStr = "wss://\(urlText)"
        } else if urlText.hasSuffix(".ts.net") || urlText.contains(".ts.net:") {
            urlStr = "ws://\(urlText)"
        } else if looksLikeTailscaleCGNAT(urlText) {
            urlStr = "ws://\(urlText)"
        } else if urlText.contains(":") {
            urlStr = "ws://\(urlText)"
        } else {
            urlStr = "wss://\(urlText)"
        }
```

- [ ] **Step 3: Add the looksLikeTailscaleCGNAT helper**

Right after `isURLTrusted` (inside the same struct), add:

```swift
    /// True if `raw` starts with a 100.64–127.x.x address (Tailscale CGNAT range).
    /// Accepts optional port suffix.
    private func looksLikeTailscaleCGNAT(_ raw: String) -> Bool {
        let hostPart = raw.split(separator: ":").first.map(String.init) ?? raw
        let parts = hostPart.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
```

- [ ] **Step 4: Build the iOS app to verify**

The iOS app ships as a separate Xcode project. Find the scheme:

```bash
ls "/Volumes/Extreme SSD/Quip/QuipiOS"
```

If `QuipiOS.xcodeproj` exists, build it with:

```bash
cd "/Volumes/Extreme SSD/Quip/QuipiOS" && xcodebuild -project QuipiOS.xcodeproj -scheme QuipiOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

**If the scheme or destination errors out**, fall back to:

```bash
cd "/Volumes/Extreme SSD/Quip/QuipiOS" && xcodebuild -list
```

to discover the actual scheme name, then rerun with the correct `-scheme`.

- [ ] **Step 5: Commit**

```bash
cd "/Volumes/Extreme SSD/Quip" && git add QuipiOS/QuipApp.swift && git commit -m "$(cat <<'EOF'
Told the phone to quit bellyachin' when it sees a Tailscale address — anything endin' in ts.net or startin' with 100-dot-64 through 100-dot-127 is fine by us, same as the house network. Also if you paste a bare Tailscale hostname in the box it figures out to put ws in front of it for ya.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Manual verification pass

**Files:** None (verification only)

This task exists so there's a clear "feature done" gate. Nothing commits. Run through all seven spec-listed scenarios and confirm each one before marking the task complete.

- [ ] **Step 1: Fresh install default — Cloudflare Tunnel**

Delete existing AppStorage, rebuild, launch:

```bash
defaults delete com.quip.QuipMac 2>/dev/null
cd "/Volumes/Extreme SSD/Quip/QuipMac" && xcodebuild -project QuipMac.xcodeproj -scheme QuipMac -configuration Debug build 2>&1 | tail -3
pkill -f "Quip.app/Contents/MacOS/Quip" 2>/dev/null; sleep 1
open "/Users/bcap/Library/Developer/Xcode/DerivedData/QuipMac-fxvynnnopbjesoesekslagiaorfw/Build/Products/Debug/Quip.app"
```

Open Settings → Connection. **Expect:** Picker selected on "Cloudflare Tunnel". Status bar shows `wss://...trycloudflare.com` within ~5 seconds.

- [ ] **Step 2: Legacy localOnlyMode migration**

Seed legacy key, relaunch:

```bash
defaults delete com.quip.QuipMac 2>/dev/null
defaults write com.quip.QuipMac localOnlyMode -bool true
pkill -f "Quip.app/Contents/MacOS/Quip" 2>/dev/null; sleep 1
open "/Users/bcap/Library/Developer/Xcode/DerivedData/QuipMac-fxvynnnopbjesoesekslagiaorfw/Build/Products/Debug/Quip.app"
```

Open Settings → Connection. **Expect:** Picker selected on "Local only". No cloudflared process started. `defaults read com.quip.QuipMac networkMode` prints `localOnly`.

- [ ] **Step 3: Tailscale happy path (requires Tailscale installed + logged in)**

In Settings, select "Tailscale" in the picker. **Expect:** Within 1–2 seconds, the "Hostname" row shows `<something>.ts.net` and the main window status bar shows `ws://<hostname>:8765`. No cloudflared running (check with `pgrep -f "cloudflared tunnel"`). Open the QR popover — QR renders.

Scan QR with phone (phone also on Tailscale). **Expect:** phone connects without any "Unrecognized Server" warning, PIN prompt appears as normal, auth succeeds.

Bounce the Mac app (quit and relaunch). **Expect:** phone reconnects to the same URL automatically (via existing WebSocketClient reconnect-with-backoff).

- [ ] **Step 4: Tailscale CLI missing**

Temporarily hide the CLI:

```bash
sudo mv /usr/local/bin/tailscale /usr/local/bin/tailscale.bak 2>/dev/null
sudo mv /opt/homebrew/bin/tailscale /opt/homebrew/bin/tailscale.bak 2>/dev/null
```

In the already-running app, open Settings → Connection, click "Re-detect". **Expect:** red error caption reads "Tailscale not installed — install from tailscale.com". App does not crash.

Restore:

```bash
sudo mv /usr/local/bin/tailscale.bak /usr/local/bin/tailscale 2>/dev/null
sudo mv /opt/homebrew/bin/tailscale.bak /opt/homebrew/bin/tailscale 2>/dev/null
```

Click "Re-detect" again. **Expect:** error clears, hostname populates.

- [ ] **Step 5: Hostname override**

In Settings → Connection, with mode still "Tailscale", type `100.64.1.2` in the override field. **Expect:** Hostname row immediately switches to `100.64.1.2` and the status bar shows `ws://100.64.1.2:8765`.

Clear the override field. **Expect:** Auto-detected hostname returns.

- [ ] **Step 6: Switch back to Cloudflare**

Select "Cloudflare Tunnel" in the picker. **Expect:** Tailscale hostname row disappears, cloudflared starts, a fresh trycloudflare URL appears in the status bar within ~5 seconds.

- [ ] **Step 7: iOS trust sanity check**

On the phone, paste `100.64.1.2:8765` into the connect bar (bare, no scheme). Tap the arrow. **Expect:** No warning dialog fires — `isURLTrusted` returns true for CGNAT. (The connection will then time out if there's no real server at that IP — that's fine, the test is only about the trust gate.)

Do the same with `quip-mac.tail1234.ts.net:8765`. **Expect:** Same result — no warning.

- [ ] **Step 8: TTS filter regression check**

Final sanity check that the earlier filter fix still works (unrelated to Tailscale but verifies the rebuild didn't regress anything):

```bash
cd "/Volumes/Extreme SSD/Quip/QuipMac/Resources" && python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('k', 'kokoro_tts.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sample = '''⏺ Hello there.

7 tasks (2 done, 1 in progress, 4 open)
  ✔ Foo
  ◼ Bar
  ◻ Baz'''
print(m.filter_text(sample))
"
```

**Expect:** Output is exactly `Hello there.` — none of the task-list lines.

---

## Self-Review Checklist

**Spec coverage:**
- ✅ NetworkMode enum with three cases — Task 1
- ✅ Migration from legacy `localOnlyMode` — Task 1 (helper) + Task 4 (wiring in `startServicesOnce`)
- ✅ TailscaleService with observable fields — Task 2 (skeleton) + Task 3 (logic)
- ✅ CLI candidate paths, JSON parsing, DNSName + IP fallback — Task 3
- ✅ Manual override — Task 3 (`refresh()`) + Task 5 (`TextField` binding)
- ✅ `applyNetworkMode()` in `QuipMacApp` — Task 4
- ✅ `didActivateApplicationNotification` observer — Task 4
- ✅ Connection tab picker + Tailscale subview + adaptive caption — Task 5
- ✅ `requirePINForLocal` retained — Task 5 (kept the Toggle)
- ✅ `tunnelQRPopover` + `tunnelStatus` three-way branching — Task 6
- ✅ New status bar icon for Tailscale (`network` glyph) — Task 6
- ✅ iOS `isURLTrusted()` additions — Task 7
- ✅ iOS `doConnect()` scheme defaulting for Tailscale inputs — Task 7
- ✅ Manual verification against spec's 7-point checklist — Task 8

**Placeholder scan:** None. Every step shows the code to write, the exact command to run, and the expected output.

**Type consistency:** `TailscaleService` fields (`hostname`, `webSocketURL`, `isAvailable`, `lastError`), enum cases (`cloudflareTunnel`, `tailscale`, `localOnly`), and AppStorage keys (`networkMode`, `tailscaleHostnameOverride`, `wsPort`) are spelled identically across Tasks 1–7.
