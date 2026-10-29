import AppKit
import ApplicationServices
import Observation

/// One file Claude opened on the Mac (Q-87).
struct ClaudePreview: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Canonical path (symlinks resolved), so `/tmp/x` and `/private/tmp/x`
    /// are the same file.
    let path: String
    var openedAt: Date
    /// Shared by the files one `open` call named. Preview puts those in one
    /// window and reports only the file it is showing, so a match for one of
    /// them is a match for all.
    var reportId: UUID
    /// The terminal whose Claude session opened it; nil when it could not be
    /// matched (shown unattached on the phone).
    var terminalWindowId: String?
    /// The Preview window showing it, once seen.
    var desktopWindowNumber: CGWindowID?

    var name: String { (path as NSString).lastPathComponent }
}

/// Collects what `quip-claude-hook` reports, keeps the list of files Claude
/// opened, and ties each to its terminal and its Preview window (Q-87).
///
/// The anti-goal it exists to keep: only paths the hook reported are ever
/// listed. Preview windows are read only to find the ones showing those paths;
/// any other Preview window is never listed or sent anywhere.
@MainActor
@Observable
final class ClaudePreviewService {
    nonisolated static let maxAge: TimeInterval = 6 * 3600
    nonisolated static let previewBundleId = "com.apple.Preview"

    /// Newest first.
    private(set) var previews: [ClaudePreview] = [] {
        didSet {
            let ids = Set(previews.map(\.id))
            if thumbnails.keys.contains(where: { !ids.contains($0) }) {
                thumbnails = thumbnails.filter { ids.contains($0.key) }
            }
        }
    }
    /// Base64 JPEG thumbnails by preview id, made off main after each report.
    private(set) var thumbnails: [UUID: String] = [:]
    /// Called after every change to `previews`.
    @ObservationIgnored var onChange: (() -> Void)?
    /// The Mac's current windows, for terminal matching.
    @ObservationIgnored var windowsProvider: () -> [ManagedWindow] = { [] }

    @ObservationIgnored let inbox: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?

    init(inbox: URL = ClaudeHookReport.inboxDirectory, now: @escaping () -> Date = Date.init) {
        self.inbox = inbox
        self.now = now
    }

    // MARK: - Inbox

    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let fd = open(inbox.path, O_EVTONLY)
        guard fd >= 0 else {
            log(.error, "inbox watch failed: open errno=\(errno)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drainInbox() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        drainInbox()
    }

    /// Reads and deletes every finished report. Reports older than `maxAge`
    /// (written while Quip was not running) are dropped unread.
    func drainInbox() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: inbox.path) else { return }
        var reports: [ClaudeHookReport] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = inbox.appendingPathComponent(name)
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let report = try? JSONDecoder().decode(ClaudeHookReport.self, from: data) else {
                log(.warn, "SKIPPED reason=unreadable-report file=\(name)")
                continue
            }
            guard now().timeIntervalSince1970 - report.at < Self.maxAge else { continue }
            reports.append(report)
        }
        for report in reports.sorted(by: { $0.at < $1.at }) { ingest(report) }
    }

    func ingest(_ report: ClaudeHookReport) {
        if report.skippedExpansion > 0 {
            log(.info, "SKIPPED reason=expansion count=\(report.skippedExpansion)")
        }
        guard !report.paths.isEmpty else { return }
        log(.info, "REPORTED paths=\(report.paths.count) tty=\(report.tty ?? "-") iterm=\(report.itermSessionId ?? "-")")
        let windows = windowsProvider()
        if let id = Self.terminalWindowId(for: report, windows: windows, terminalTTYs: [:]) {
            apply(report, terminalWindowId: id)
            return
        }
        // Terminal.app tabs' ttys are not polled; ask only when a report needs one.
        guard report.tty != nil, windows.contains(where: { $0.bundleId == TerminalApp.terminal.bundleIdentifier }) else {
            apply(report, terminalWindowId: nil)
            return
        }
        Task { [weak self] in
            let ttys = await AppleScriptRunner.offMain { Self.fetchTerminalTTYs() }
            guard let self else { return }
            self.apply(report, terminalWindowId: Self.terminalWindowId(
                for: report, windows: self.windowsProvider(), terminalTTYs: ttys))
        }
    }

    private func apply(_ report: ClaudeHookReport, terminalWindowId: String?) {
        previews = Self.merge(report, terminalWindowId: terminalWindowId, into: previews, now: now())
        // (Re)make thumbnails: a re-opened path is often a re-taken screenshot.
        let fresh = Set(report.paths.map(Self.canonical))
        for preview in previews where fresh.contains(preview.path) {
            let (id, path) = (preview.id, preview.path)
            Task { [weak self] in
                let thumb = await Task.detached { ClaudePreviewImages.thumbnail(path: path) }.value
                guard let self, let thumb, self.previews.contains(where: { $0.id == id }) else { return }
                self.thumbnails[id] = thumb
                self.onChange?()
            }
        }
        for path in report.paths {
            let name = (path as NSString).lastPathComponent
            if let terminalWindowId {
                log(.info, "ATTACHED preview=\(name) window=\(terminalWindowId)")
            } else {
                log(.info, "UNATTACHED preview=\(name)")
            }
        }
        onChange?()
    }

    // MARK: - Phone

    /// The list as phones see it: file names only, never full paths.
    var items: [ClaudePreviewItem] {
        previews.map { p in
            ClaudePreviewItem(id: p.id.uuidString, name: p.name, terminalWindowId: p.terminalWindowId,
                              openedAt: p.openedAt.timeIntervalSince1970,
                              hasDesktopWindow: p.desktopWindowNumber != nil,
                              thumb: thumbnails[p.id], isPDF: ClaudePreviewImages.isPDF(p.path))
        }
    }

    func path(for id: String) -> String? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return previews.first { $0.id == uuid }?.path
    }

    /// Drops `id` from the list. With `closeOnDesktop`, also closes its
    /// Preview window — unless another listed file is in the same window, so
    /// dismissing one of a group never closes the others' window.
    func dismiss(id: UUID, closeOnDesktop: Bool) {
        guard let preview = previews.first(where: { $0.id == id }) else { return }
        previews.removeAll { $0.id == id }
        if closeOnDesktop, let number = preview.desktopWindowNumber,
           !previews.contains(where: { $0.desktopWindowNumber == number }),
           let window = windowsProvider().first(where: { $0.windowNumber == number }) {
            let closed = Self.pressClose(pid: window.pid, bounds: window.bounds, title: window.name)
            log(closed ? .info : .warn, "CLOSE preview=\(preview.name) window=\(number) result=\(closed ? "ok" : "failed")")
        }
        log(.info, "DISMISSED preview=\(preview.name) closeOnDesktop=\(closeOnDesktop)")
        onChange?()
    }

    // MARK: - Desktop windows

    /// Called on the window snapshot tick. Matches listed files to the Preview
    /// windows showing them, and expires what is gone. Does nothing (no AX
    /// reads) while the list is empty.
    func refreshDesktopWindows(_ windows: [ManagedWindow]) {
        guard !previews.isEmpty else { return }
        let previewWindows = windows.filter { $0.bundleId == Self.previewBundleId }
        let targets = previewWindows.map { (number: $0.windowNumber, pid: $0.pid, bounds: $0.bounds, title: $0.name) }
        Task { [weak self] in
            let docs = await Task.detached { Self.readDocuments(targets) }.value
            guard let self else { return }
            let live = Set(previewWindows.map(\.windowNumber))
            let updated = Self.expire(
                Self.applyDocuments(docs, liveWindows: live, to: self.previews),
                now: self.now(),
                fileExists: { FileManager.default.fileExists(atPath: $0) })
            guard updated != self.previews else { return }
            for gone in self.previews where !updated.contains(where: { $0.id == gone.id }) {
                self.log(.info, "EXPIRED preview=\(gone.name)")
            }
            self.previews = updated
            self.onChange?()
        }
    }

    // MARK: - Pure

    nonisolated static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private nonisolated static func bareTTY(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty else { return nil }
        return tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    /// The terminal window whose Claude session wrote `report`: iTerm2 session
    /// id first (exact), then the tty against iTerm2's and Terminal.app's.
    /// Never "the most recent terminal": no match means unattached.
    nonisolated static func terminalWindowId(for report: ClaudeHookReport,
                                             windows: [ManagedWindow],
                                             terminalTTYs: [CGWindowID: [String]]) -> String? {
        if let session = report.itermSessionId,
           let w = windows.first(where: { $0.iterm2SessionId == session }) {
            return w.id
        }
        guard let tty = bareTTY(report.tty) else { return nil }
        if let w = windows.first(where: { bareTTY($0.iterm2Tty) == tty }) { return w.id }
        if let w = windows.first(where: { w in
            w.bundleId == TerminalApp.terminal.bundleIdentifier
                && (terminalTTYs[w.windowNumber] ?? []).contains { bareTTY($0) == tty }
        }) {
            return w.id
        }
        return nil
    }

    /// Adds the report's files, newest first. A file already listed moves to
    /// the front with the new time (and terminal, when this one matched)
    /// instead of appearing twice — `open shot.png` again reuses its window.
    nonisolated static func merge(_ report: ClaudeHookReport, terminalWindowId: String?,
                                  into previews: [ClaudePreview], now: Date) -> [ClaudePreview] {
        var out = previews
        let reportId = UUID()
        for raw in report.paths.reversed() {
            let path = canonical(raw)
            if let i = out.firstIndex(where: { $0.path == path }) {
                var p = out.remove(at: i)
                p.openedAt = now
                p.reportId = reportId
                if let terminalWindowId { p.terminalWindowId = terminalWindowId }
                out.insert(p, at: 0)
            } else {
                out.insert(ClaudePreview(id: UUID(), path: path, openedAt: now, reportId: reportId,
                                         terminalWindowId: terminalWindowId, desktopWindowNumber: nil), at: 0)
            }
        }
        return out
    }

    /// `docs` maps each live Preview window to the canonical path it shows.
    /// A file shown in a window takes that window, and so do the other files
    /// of its `open` call (Preview grouped them). A file whose window has
    /// closed is removed: closing it on the Mac is closing it here too.
    nonisolated static func applyDocuments(_ docs: [CGWindowID: String], liveWindows: Set<CGWindowID>,
                                           to previews: [ClaudePreview]) -> [ClaudePreview] {
        var out = previews
        for i in out.indices {
            if let match = docs.first(where: { $0.value == out[i].path }) {
                out[i].desktopWindowNumber = match.key
            }
        }
        for i in out.indices where out[i].desktopWindowNumber == nil {
            if let sibling = out.first(where: { $0.reportId == out[i].reportId && $0.desktopWindowNumber != nil }) {
                out[i].desktopWindowNumber = sibling.desktopWindowNumber
            }
        }
        return out.filter { p in
            guard let number = p.desktopWindowNumber else { return true }
            return liveWindows.contains(number)
        }
    }

    nonisolated static func expire(_ previews: [ClaudePreview], now: Date,
                                   fileExists: (String) -> Bool) -> [ClaudePreview] {
        previews.filter { now.timeIntervalSince($0.openedAt) < maxAge && fileExists($0.path) }
    }

    // MARK: - AX and AppleScript

    /// Each Preview window's document, via the public `AXDocument` attribute
    /// (a file URL). AX rather than AppleScript: no Automation prompt, and it
    /// stays off the AppleScript path. Windows are matched to AX elements with
    /// the same position/size/title resolver focus uses.
    nonisolated static func readDocuments(
        _ targets: [(number: CGWindowID, pid: pid_t, bounds: CGRect, title: String)]
    ) -> [CGWindowID: String] {
        var out: [CGWindowID: String] = [:]
        for (pid, group) in Dictionary(grouping: targets, by: { $0.pid }) {
            let (elements, candidates) = axWindows(pid: pid)
            for target in group {
                let focus = WindowManager.AXFocusTarget(origin: target.bounds.origin, size: target.bounds.size,
                                                        title: target.title)
                guard case let .unique(i) = WindowManager.resolveAXWindow(target: focus, candidates: candidates) else { continue }
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(elements[i], kAXDocumentAttribute as CFString, &ref) == .success,
                      let s = ref as? String, let url = URL(string: s), url.isFileURL else { continue }
                out[target.number] = canonical(url.path)
            }
        }
        return out
    }

    /// Presses the window's close button. Generic AX, so it works for any app
    /// (the iTerm-only `closeWindow` is a different path).
    nonisolated static func pressClose(pid: pid_t, bounds: CGRect, title: String) -> Bool {
        let (elements, candidates) = axWindows(pid: pid)
        let focus = WindowManager.AXFocusTarget(origin: bounds.origin, size: bounds.size, title: title)
        guard case let .unique(i) = WindowManager.resolveAXWindow(target: focus, candidates: candidates) else { return false }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elements[i], kAXCloseButtonAttribute as CFString, &ref) == .success,
              let button = ref, CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    private nonisolated static func axWindows(pid: pid_t) -> ([AXUIElement], [WindowManager.AXCandidate]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return ([], []) }
        let candidates = windows.map { w -> WindowManager.AXCandidate in
            var c = WindowManager.AXCandidate()
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &v) == .success,
               let v, CFGetTypeID(v) == AXValueGetTypeID() {
                var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); c.origin = p
            }
            var s: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
               let s, CFGetTypeID(s) == AXValueGetTypeID() {
                var z = CGSize.zero; AXValueGetValue(s as! AXValue, .cgSize, &z); c.size = z
            }
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success {
                c.title = t as? String
            }
            return c
        }
        return (windows, candidates)
    }

    /// Terminal.app window id (= CGWindowID) → the ttys of all its tabs, so a
    /// Claude in a background tab still matches its window.
    nonisolated static func fetchTerminalTTYs() -> [CGWindowID: [String]] {
        let script = """
        set output to ""
        tell application "Terminal"
            repeat with w in windows
                try
                    set wid to id of w
                    repeat with t in tabs of w
                        set output to output & wid & ":" & (tty of t) & linefeed
                    end repeat
                end try
            end repeat
        end tell
        return output
        """
        let result = AppleScriptRunner.run(script, cached: true)
        guard !result.failed, let text = result.stringValue else { return [:] }
        return parseTerminalTTYs(text)
    }

    nonisolated static func parseTerminalTTYs(_ text: String) -> [CGWindowID: [String]] {
        var out: [CGWindowID: [String]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UInt32(parts[0]) else { continue }
            out[CGWindowID(id), default: []].append(String(parts[1]))
        }
        return out
    }

    private func log(_ severity: QuipLog.Severity, _ message: String) {
        QuipLog.write(severity: severity, subsystem: "claude-previews", message: message,
                      to: LogPaths.claudePreviewsPath)
    }
}
