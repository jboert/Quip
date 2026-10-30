import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Opens a link in another app. `open` answers false when no app takes the
/// scheme; it needs no `LSApplicationQueriesSchemes` entry, unlike
/// `canOpenURL`, so a Custom link works too.
@MainActor
protocol URLOpener {
    func open(_ url: URL) async -> Bool
}

#if canImport(UIKit)
struct SystemURLOpener: URLOpener {
    func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}
#endif

/// Q-88 US-011: one tap from a window (or a Mac) to a remote-desktop app.
/// "Remote in here" first asks the Mac to bring the window forward and waits
/// briefly for it to say so, so the remote session opens on that window.
@MainActor
final class RemoteInFlow {
    enum Result: String {
        case opened
        case noApp = "no_app"
        /// No host or name, or a template that cannot make a link: the
        /// caller opens the Remote-in setting.
        case noHost = "no_host"
    }

    struct Outcome: Equatable {
        let result: Result
        let url: URL?
        let waitedMs: Int
        let logLine: String
    }

    static let echoWait: Duration = .milliseconds(500)

    private let opener: URLOpener
    private let sleep: (Duration) async -> Void
    private let now: () -> ContinuousClock.Instant
    private var waiting: (id: String, c: CheckedContinuation<Void, Never>)?

    init(opener: URLOpener,
         sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.opener = opener
        self.sleep = sleep
        self.now = now
    }

    /// The Mac's `frontmost_changed`, for the window being waited on.
    func frontmostChanged(_ windowId: String?) {
        if let windowId { release(windowId) }
    }

    /// - Parameters:
    ///   - windowId: the window to bring forward first; nil for a whole Mac.
    ///   - alreadyFront: the Mac already reports it frontmost, so no echo
    ///     will come and there is nothing to wait for.
    func run(settings: RemoteInSettings, host: String, name: String,
             windowId: String?, alreadyFront: Bool,
             selectWindow: (String) -> Void) async -> Outcome {
        let kind = Self.hostKind(template: settings.template, host: host)
        func outcome(_ result: Result, _ url: URL?, _ waited: Int) -> Outcome {
            Outcome(result: result, url: url, waitedMs: waited,
                    logLine: "remote_in preset=\(settings.preset.rawValue) host_kind=\(kind) result=\(result.rawValue) waited_ms=\(waited)")
        }
        guard case .success(let url) = RemoteInURLBuilder.build(settings.template, host: host, name: name) else {
            return outcome(.noHost, nil, 0)
        }
        var waited = 0
        if let windowId {
            selectWindow(windowId)
            if !alreadyFront {
                let start = now()
                await waitForEcho(windowId)
                let d = now() - start
                waited = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
            }
        }
        let opened = await opener.open(url)
        return outcome(opened ? .opened : .noApp, url, waited)
    }

    /// Resumes on the echo or after `echoWait`, whichever comes first.
    private func waitForEcho(_ windowId: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiting = (windowId, c)
            Task { @MainActor in
                await sleep(Self.echoWait)
                release(windowId)
            }
        }
    }

    private func release(_ windowId: String) {
        guard let w = waiting, w.id == windowId else { return }
        waiting = nil
        w.c.resume()
    }

    /// What kind of address the link uses, for the log. Never the address.
    static func hostKind(template: String, host: String) -> String {
        let used = RemoteInURLBuilder.placeholders(in: template)
        guard used.contains("host") else { return used.contains("name") ? "name" : "custom" }
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { return "none" }
        switch BackendConnectionManager.urlPriority("ws://\(host)") {
        case BackendConnectionManager.tailscalePriority: return "tailscale"
        case BackendConnectionManager.bonjourPriority, BackendConnectionManager.lanPriority,
             BackendConnectionManager.linkLocalPriority: return "lan"
        default: return "custom"
        }
    }
}
