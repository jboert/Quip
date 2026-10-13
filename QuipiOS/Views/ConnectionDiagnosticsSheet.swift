import SwiftUI
import AVFoundation

/// State for the inline connection-test probe that sits next to the URL field.
/// Kept separate from `client.isConnected` so we can offer a "just reach out
/// and see" button that doesn't disturb an active session.
enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failed(String)

    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// One-line status to show inline under the URL field. `nil` hides the pill.
    var resultMessage: String? {
        switch self {
        case .idle, .testing: return nil
        case .success(let msg), .failed(let msg): return msg
        }
    }
}

enum ConnectionProbeError: Error {
    case timeout(TimeInterval)
}

// MARK: - Connection Diagnostics

/// Renders the in-memory `WebSocketClient.recentConnectionEvents` ring
/// buffer (last 30 lifecycle transitions). Read-only; no live tail —
/// pull-to-refresh re-reads the buffer. Surfaces enough state that the
/// user can answer "is the socket alive right now and what was the last
/// thing that happened" without plugging into a Mac to tail device logs.
struct ConnectionDiagnosticsSheet: View {
    var client: WebSocketClient
    @State private var bundleStatus: String?
    @State private var bundleURL: URL?
    @State private var showShareSheet = false
    @State private var logTailText: String = ""
    @State private var logTailCapturedAt: String = ""
    /// Both Mac round-trips on this sheet are deadline-bounded. They used to be
    /// bare `Bool`s flipped true on send and false only on reply — so a Mac that
    /// never answered left "Waiting for Mac…" and a disabled button on screen
    /// with no way out but closing the sheet. The waiting state IS the deadline
    /// now: there is no way to enter one without arming the other.
    ///
    /// The zip gets a longer deadline than the tail — the Mac has to walk the log
    /// dir and compress up to 4 MiB, where the tail is a 16 KB read.
    @StateObject private var bundleRequest = PendingMacRequest(deadline: 25)
    @StateObject private var logTailRequest = PendingMacRequest(deadline: 10)

    /// What the "Mac log tail" section shows, given the request state and
    /// whether any tail text is on screen. Pulled out as a pure function so
    /// the failure-visibility contract is unit-testable without SwiftUI:
    /// a failure must be shown whenever one exists, regardless of whether
    /// stale content from an earlier successful fetch is also present. A
    /// refresh that times out while stale text is showing must not let that
    /// stale text silently swallow the failure — the user needs to be able
    /// to tell "Mac returned identical logs" from "Mac never answered".
    enum LogTailDisplay: Equatable {
        case fetching
        case failureOnly(String)
        case empty
        /// Stale/fresh tail text, plus an optional failure banner rendered
        /// above it (non-nil when the most recent refresh failed).
        case content(failure: String?)
    }

    static func logTailDisplay(isInFlight: Bool, failureMessage: String?, textIsEmpty: Bool) -> LogTailDisplay {
        if isInFlight && textIsEmpty { return .fetching }
        if let failure = failureMessage, textIsEmpty { return .failureOnly(failure) }
        if textIsEmpty { return .empty }
        return .content(failure: failureMessage)
    }

    var body: some View {
        List {
            Section {
                switch Self.logTailDisplay(isInFlight: logTailRequest.isInFlight,
                                            failureMessage: logTailRequest.failureMessage,
                                            textIsEmpty: logTailText.isEmpty) {
                case .fetching:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Fetching…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                case .failureOnly(let failure):
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                case .empty:
                    Text("No snapshot yet — pull to refresh.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                case .content(let failure):
                    if let failure {
                        Text(failure)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                    ScrollView {
                        Text(logTailText)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 320)
                }
            } header: {
                HStack {
                    Text("Mac log tail")
                    Spacer()
                    Button {
                        requestLogTail()
                    } label: {
                        if logTailRequest.isInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(logTailRequest.isInFlight || !client.isAuthenticated)
                    .font(.system(size: 12))
                }
            } footer: {
                if !logTailCapturedAt.isEmpty {
                    Text("Snapshot captured \(logTailCapturedAt). Tap refresh icon for fresh tail. Full zip download below.")
                } else {
                    Text("Auto-fetched on open. Last 16 KB of each Mac log file (websocket / push / kokoro), text only.")
                }
            }

            Section {
                Button {
                    requestMacLogs()
                } label: {
                    HStack {
                        if bundleRequest.isInFlight {
                            ProgressView().controlSize(.small)
                        }
                        Image(systemName: "arrow.down.doc")
                        Text(bundleRequest.isInFlight ? "Waiting for Mac…" : "Get Mac logs (zip)")
                    }
                }
                .disabled(bundleRequest.isInFlight || !client.isAuthenticated)
                if let url = bundleURL {
                    Button {
                        showShareSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share \(url.lastPathComponent)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if let failure = bundleRequest.failureMessage {
                    // Outranks bundleStatus: on a timeout that would still read
                    // "Requesting…", which is exactly the lie we're fixing.
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                } else if let status = bundleStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Full bundle (AirDrop / save)")
            } footer: {
                Text("Zip of websocket.log + push.log + kokoro.log + system info. Capped at 4 MiB.")
            }

            Section("Current state") {
                stateRow(label: "Connected", value: client.isConnected ? "yes" : "no",
                         tint: client.isConnected ? .green : .secondary)
                stateRow(label: "Authenticated", value: client.isAuthenticated ? "yes" : "no",
                         tint: client.isAuthenticated ? .green : .secondary)
                if let url = client.serverURL {
                    stateRow(label: "Server", value: url.host ?? url.absoluteString, tint: .secondary)
                    let (label, tint) = transportClassification(for: url)
                    stateRow(label: "Transport", value: label, tint: tint)
                }
                let (whisperLabel, whisperTint) = whisperStateClassification(client.whisperStatus)
                stateRow(label: "Whisper (Mac)", value: whisperLabel, tint: whisperTint)
                let pttPath: PTTPath = client.isConnected
                    ? selectPTTPath(isConnected: client.isConnected, whisperStatus: client.whisperStatus)
                    : .local
                stateRow(label: "Next PTT path",
                         value: pttPath == .remote ? "remote (Whisper)" : "local (SFSpeech)",
                         tint: pttPath == .remote ? .green : .orange)
                if let err = client.lastError, !err.isEmpty {
                    stateRow(label: "Last error", value: err, tint: .red)
                }
            }

            Section {
                if client.recentConnectionEvents.isEmpty {
                    Text("No events yet — try a reconnect or background+return.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                } else {
                    ForEach(Array(client.recentConnectionEvents.reversed().enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                    }
                }
            } header: {
                HStack {
                    Text("Recent events (\(client.recentConnectionEvents.count))")
                    Spacer()
                    Button("Copy") {
                        UIPasteboard.general.string = client.recentConnectionEvents.joined(separator: "\n")
                    }
                    .font(.system(size: 12))
                    .textCase(nil)
                }
            } footer: {
                Text("Ring buffer keeps the last 30 events. Newest first. Useful when triaging \"why is it stuck on Connecting\" — paste into a bug report.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            if let url = bundleURL {
                DiagnosticsShareSheet(items: [url])
            }
        }
        .onAppear {
            wireBundleHandler()
            wireLogTailHandler()
            // Auto-fetch the tail snapshot on open. Lightweight (~50 KB
            // text) so it's fine to fire every time the sheet appears.
            // Full zip stays opt-in via the button below.
            if client.isAuthenticated {
                requestLogTail()
            }
        }
    }

    private func wireBundleHandler() {
        // Set every time the sheet appears so we re-grab the current handler
        // closure (the previous handler may have been a leftover from a
        // prior screen instance).
        client.onDiagnosticsBundle = { msg in
            if let err = msg.errorReason {
                bundleStatus = nil
                bundleRequest.resolve(.failed(cause: err, nextStep: "Try again"))
                return
            }
            guard let base64 = msg.data, let raw = Data(base64Encoded: base64) else {
                bundleStatus = nil
                bundleRequest.resolve(.failed(cause: "Mac sent a malformed bundle",
                                              nextStep: "Try again — if it repeats, update Quip on the Mac"))
                return
            }
            do {
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dest = dir.appendingPathComponent(msg.filename.isEmpty ? "Quip-diagnostics.zip" : msg.filename)
                try? FileManager.default.removeItem(at: dest)
                try raw.write(to: dest)
                bundleURL = dest
                bundleStatus = "Bundle ready (\(raw.count / 1024) KB) — tap Share."
                bundleRequest.resolve(.succeeded)
                // If the Mac answered after the 25s deadline already fired,
                // resolve() above is a no-op by design — an action must not
                // be resurrected once timed out. But we just saved a working
                // bundle, so leaving the old "Mac didn't respond" failure on
                // screen would contradict the Share button sitting right above
                // it. Clear it explicitly so the UI is coherent.
                if case .failed = bundleRequest.state {
                    bundleRequest.reset()
                }
            } catch {
                bundleStatus = nil
                bundleRequest.resolve(.failed(cause: "Couldn't save the bundle: \(error.localizedDescription)",
                                              nextStep: "Free up space on the phone, then try again"))
            }
        }
    }

    private func wireLogTailHandler() {
        client.onLogTail = { msg in
            logTailText = msg.text
            // Format the captured timestamp as HH:mm:ss for the footer
            // staleness indicator. Falls back to the raw ISO string if
            // parsing fails.
            if let date = ISO8601DateFormatter().date(from: msg.capturedAt) {
                let f = DateFormatter()
                f.timeStyle = .medium
                f.dateStyle = .none
                logTailCapturedAt = "at \(f.string(from: date))"
            } else {
                logTailCapturedAt = msg.capturedAt
            }
            logTailRequest.resolve(.succeeded)
            // If the Mac answered after the 10s deadline already fired,
            // resolve() above is a no-op by design — an action must not
            // be resurrected once timed out. But we just wrote fresh,
            // genuinely current text above, so leaving the old "Mac
            // didn't respond" failure on screen would contradict the
            // just-updated tail sitting right below it. Clear it
            // explicitly so the UI is coherent.
            if case .failed = logTailRequest.state {
                logTailRequest.reset()
            }
        }
    }

    private func requestLogTail() {
        logTailRequest.attempt(isConnected: client.isAuthenticated,
                               nextStep: "Reconnect, then tap refresh") {
            client.send(RequestLogTailMessage())
        }
    }

    private func requestMacLogs() {
        bundleStatus = "Requesting…"
        bundleURL = nil
        let armed = bundleRequest.attempt(isConnected: client.isAuthenticated,
                                          nextStep: "Reconnect, then try again") {
            client.send(RequestDiagnosticsMessage())
        }
        // Nothing left the phone, so there is no bundle coming — the failure
        // banner from `attempt` is the whole story and a "Requesting…" line
        // above it would contradict it.
        if !armed { bundleStatus = nil }
    }

    @ViewBuilder
    private func stateRow(label: String, value: String, tint: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 13))
    }

    /// Classify the active WS URL into a transport bucket so the user can
    /// answer "am I going LAN, Tailscale, or tunnel right now?" without
    /// reading the URL byte-by-byte. Heuristics:
    ///   - `wss://*.trycloudflare.com` or `wss://*.cfargotunnel.com` → Tunnel
    ///   - host in `100.64.0.0/10` (Tailscale CGNAT) → Tailscale
    ///   - host ends `.local` or is RFC1918 → LAN
    ///   - everything else → Direct
    private func transportClassification(for url: URL) -> (String, Color) {
        guard let host = url.host?.lowercased() else { return ("Unknown", .secondary) }
        if host.hasSuffix(".trycloudflare.com") || host.hasSuffix(".cfargotunnel.com") {
            return ("Cloudflare tunnel", .blue)
        }
        if host.hasSuffix(".local") {
            return ("LAN (Bonjour)", .green)
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            let a = parts[0], b = parts[1]
            if a == 100 && (64...127).contains(b) { return ("Tailscale", .indigo) }
            if a == 10 { return ("LAN (10.x)", .green) }
            if a == 192 && b == 168 { return ("LAN (192.168.x)", .green) }
            if a == 172 && (16...31).contains(b) { return ("LAN (172.16-31.x)", .green) }
            if a == 127 { return ("Loopback", .secondary) }
        }
        return ("Direct", .secondary)
    }

    private func whisperStateClassification(_ state: WhisperState) -> (String, Color) {
        switch state {
        case .preparing: return ("preparing", .orange)
        case .downloading(let p): return ("downloading \(Int(p * 100))%", .orange)
        case .ready: return ("ready", .green)
        case .failed(let m): return ("failed: \(m)", .red)
        }
    }
}

/// "Why is text taking so long to land?" view. Three friendly numbers up top
/// (median total / network / Mac-side), then a compact sparkline of recent
/// samples, then a per-path table so the user can tell at a glance whether
/// Codex (pasteText) or Claude (sendText) is the slow one. No raw timestamps —
/// the spec is "approachable", not "engineering dashboard".
struct LatencyDiagnosticsSheet: View {
    @Bindable var client: WebSocketClient

    var body: some View {
        List {
            Section {
                let summary = LatencySummary.from(samples: client.latencySamples)
                HStack(spacing: 10) {
                    Circle().fill(summary.color).frame(width: 12, height: 12)
                    Text(summary.label)
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                if client.latencySamples.isEmpty {
                    Text("No samples yet. Send a few messages from a Codex / Claude window — the numbers fill in as round-trips complete.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Round-trip")
            } footer: {
                Text("Median of the last 20 text-land round-trips. Snappy = under 250ms; OK up to 600ms; Slow past that.")
            }

            if !client.latencySamples.isEmpty {
                Section {
                    medianRow("Network", samples: client.latencySamples.map(\.netRtt))
                    medianRow("Mac processing", samples: client.latencySamples.map(\.totalMs))
                    medianRow("AppleScript / paste", samples: client.latencySamples.map(\.injectMs))
                } header: {
                    Text("Where the time goes")
                } footer: {
                    Text("Network = phone↔Mac alone. Mac processing = arrival to text landed. AppleScript / paste is the inject step itself.")
                }

                let codex = client.latencySamples.filter { $0.path == "pasteText" }
                let other = client.latencySamples.filter { $0.path == "sendText" }
                Section {
                    if !codex.isEmpty {
                        medianRow("Codex (pasteText)", samples: codex.map(\.totalRtt))
                    }
                    if !other.isEmpty {
                        medianRow("Claude / shell (sendText)", samples: other.map(\.totalRtt))
                    }
                    if codex.isEmpty && other.isEmpty {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("By routing path")
                }

                Section {
                    LatencySparkline(samples: client.latencySamples)
                        .frame(height: 60)
                        .padding(.vertical, 4)
                } header: {
                    Text("Recent (\(client.latencySamples.count) samples)")
                }

                // Phase 3: hot-swap routing. ON unless the user opts out — the
                // reader must agree with `BackendConnectionManager
                // .autoSwapEnabled`, or this row would show OFF while the
                // engine is running (which is exactly backwards from the bug
                // this replaced, where the row showed OFF and the engine
                // genuinely never ran for anyone).
                Section {
                    Toggle("Auto-pick fastest path", isOn: Binding(
                        get: { BackendConnectionManager.autoSwapEnabled() },
                        set: { UserDefaults.standard.set($0, forKey: BackendConnectionManager.autoSwapDefaultsKey) }
                    ))
                } header: {
                    Text("Routing")
                } footer: {
                    Text("When ON, Quip probes alternate paths to your Mac (LAN, Tailscale, tunnel) every minute and switches to the fastest one when a clear winner emerges. Causes a sub-second connection blip during a swap.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Latency")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func medianRow(_ title: String, samples: [Int]) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(median(samples))ms")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Tiny inline sparkline of recent total-RTT samples. Bar heights normalized
/// to the max in the buffer so the chart auto-scales as conditions change —
/// the user looks for *shape* (climbing? stable? spiky?) more than absolute
/// height. Bar color follows the LatencySummary bucket of that single sample.
private struct LatencySparkline: View {
    let samples: [WebSocketClient.LatencySample]

    var body: some View {
        let maxRtt = max(1, samples.map(\.totalRtt).max() ?? 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(samples.indices, id: \.self) { i in
                    let s = samples[i]
                    let h = max(2, CGFloat(s.totalRtt) / CGFloat(maxRtt) * geo.size.height)
                    Rectangle()
                        .fill(LatencySummary.from(samples: [s]).color)
                        .frame(width: max(1, (geo.size.width - CGFloat(samples.count - 1)) / CGFloat(samples.count)),
                               height: h)
                }
            }
        }
        .accessibilityLabel("Latency sparkline of \(samples.count) recent samples")
    }
}
