// WindowManager.swift
// QuipMac — Window enumeration, arrangement, and display management
// Uses CGWindowList + AXUIElement APIs for window control

import AppKit
import Observation
import CoreGraphics
import ApplicationServices

// MARK: - Models

/// Represents a window managed by Quip
struct ManagedWindow: Identifiable, Sendable {
    let id: String                // Unique identifier (bundleId + windowNumber)
    let name: String              // Window title
    let app: String               // Application name
    var subtitle: String          // Directory path or secondary info
    let bundleId: String          // Application bundle identifier
    let icon: NSImage?            // App icon (non-Sendable but only used on MainActor)
    var isEnabled: Bool           // Whether this window participates in layouts
    var assignedColor: String     // Hex color from palette
    let pid: pid_t                // Process ID
    let windowNumber: CGWindowID  // CG window number
    var bounds: CGRect            // Current window frame
    var iterm2SessionId: String?
    /// The tty device attached to this iTerm2 session, e.g. "ttys009".
    /// Lets us find the actual shell PID for this specific window —
    /// otherwise every iTerm2 window shares the app's PID and the
    /// per-window process-tree walk in TerminalStateDetector sees one
    /// conflated blob of "all Claudes" instead of this window's Claude.
    var iterm2Tty: String?
    /// True when the window's bounds center falls inside some currently-
    /// connected NSScreen. Populated fresh on every snapshot refresh —
    /// CG's `.optionOnScreenOnly` is not reliable for windows parked on
    /// inactive Spaces or disconnected monitors, so we re-check here.
    var isOnVisibleScreen: Bool = true

    /// Whether this window is hosted by a terminal emulator Quip supports
    /// (Terminal.app or iTerm2). Used for auto-grouping in the sidebar.
    var isTerminal: Bool {
        bundleId == TerminalApp.terminal.bundleIdentifier
            || bundleId == TerminalApp.iterm2.bundleIdentifier
    }

    /// Convert to shared WindowState for protocol messages.
    /// Frame is normalized to 0-1 relative to the given screen bounds.
    func toWindowState(state: String = "neutral", screenBounds: CGRect? = nil, isThinking: Bool = false) -> WindowState {
        let frame: WindowFrame
        if let screen = screenBounds, screen.width > 0, screen.height > 0 {
            frame = WindowFrame(
                x: (bounds.origin.x - screen.origin.x) / screen.width,
                y: (bounds.origin.y - screen.origin.y) / screen.height,
                width: bounds.width / screen.width,
                height: bounds.height / screen.height
            )
        } else {
            frame = WindowFrame(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.width,
                height: bounds.height
            )
        }
        return WindowState(
            id: id,
            name: name,
            app: app,
            folder: subtitle.isEmpty ? nil : subtitle,
            enabled: isEnabled,
            frame: frame,
            state: state,
            color: assignedColor,
            isThinking: isThinking
        )
    }
}

// MARK: - WindowManager

@MainActor
@Observable
final class WindowManager {

    // Rich, vibrant color palette for window identification
    static let colorPalette: [String] = [
        "#F5A623", "#4A90D9", "#7ED321", "#D0021B", "#9013FE",
        "#50E3C2", "#BD10E0", "#B8E986", "#F8E71C", "#FF6B6B"
    ]

    /// All currently tracked windows
    var windows: [ManagedWindow] = []

    /// Custom ordering of window IDs — preserved across refreshes
    var customOrder: [String] = []

    /// iTerm2 session UUIDs the user explicitly attached from the phone's
    /// "scan existing sessions" flow. Persisted to UserDefaults so the
    /// attachment survives Quip restarts. On every snapshot apply, any
    /// CG window whose iterm2SessionId is in this set gets auto-enabled —
    /// that's how "I attached this yesterday" becomes "it's back in my
    /// picker today" without any phone round-trip.
    private(set) var attachedSessionIds: Set<String> = []
    private static let attachedSessionIdsKey = "attachedITermSessionIds"

    /// Available displays
    var displays: [DisplayInfo] = []

    // Next color index for assignment
    private var colorIndex: Int = 0

    // MARK: - Init / Attached Session Persistence

    init() {
        loadAttachedSessionIds()
    }

    /// Load the persisted attached-session UUID list from UserDefaults.
    /// Called once at init. Missing / corrupt data is treated as an empty
    /// list — we never throw since a corrupt pref shouldn't brick the app.
    private func loadAttachedSessionIds() {
        guard let arr = UserDefaults.standard.array(forKey: Self.attachedSessionIdsKey) as? [String] else { return }
        attachedSessionIds = Set(arr)
        if !attachedSessionIds.isEmpty {
            print("[WindowManager] loaded \(attachedSessionIds.count) attached iTerm session(s)")
        }
    }

    private func persistAttachedSessionIds() {
        UserDefaults.standard.set(Array(attachedSessionIds), forKey: Self.attachedSessionIdsKey)
    }

    /// Remember this iTerm session UUID as one the user has attached.
    /// Idempotent — re-attaching the same session is a no-op. The actual
    /// ManagedWindow gets enabled on the next snapshot apply (or the caller
    /// can force a refresh; see QuipMacApp.handleAttachITermWindow).
    func markSessionAttached(sessionId: String) {
        guard !sessionId.isEmpty, !attachedSessionIds.contains(sessionId) else { return }
        attachedSessionIds.insert(sessionId)
        persistAttachedSessionIds()
    }

    /// Drop a session from the attached set and persist. Future snapshots
    /// will stop auto-enabling the window. Currently-running windows stay
    /// enabled for the rest of the session (the user can toggle off). MVP
    /// has no UI for this yet, but it's here for US-006 reconciliation and
    /// for a future "stop tracking" affordance.
    func markSessionDetached(sessionId: String) {
        guard attachedSessionIds.contains(sessionId) else { return }
        attachedSessionIds.remove(sessionId)
        persistAttachedSessionIds()
    }

    // MARK: - Display Info

    struct DisplayInfo: Identifiable, Sendable, Equatable, Hashable {
        let id: String
        let name: String
        let frame: CGRect
        let isMain: Bool
    }

    // MARK: - Refresh Displays

    /// Enumerate available displays from NSScreen
    func refreshDisplays() {
        displays = NSScreen.screens.enumerated().map { index, screen in
            let isMain = (screen == NSScreen.main)
            let name = screen.localizedName
            return DisplayInfo(
                id: "display-\(index)",
                name: name,
                frame: screen.frame,
                isMain: isMain
            )
        }
    }

    // MARK: - Refresh Window List

    /// Raw window data fetched off main — no NSImage, no state merging.
    struct RawWindowInfo: Sendable {
        let id: String
        let name: String
        let app: String
        let bundleId: String
        let pid: pid_t
        let windowNumber: CGWindowID
        let bounds: CGRect
    }

    /// Fetch on-screen windows from CG. Safe to call from any thread.
    nonisolated static func fetchWindowList() -> [RawWindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [RawWindowInfo] = []
        let systemApps: Set<String> = ["Window Server", "Control Center", "Notification Center", "SystemUIServer"]

        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowNumber = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  !systemApps.contains(ownerName) else { continue }

            let title = info[kCGWindowName as String] as? String ?? ownerName
            var bounds = CGRect.zero
            if let d = info[kCGWindowBounds as String] as? [String: Any] {
                bounds = CGRect(x: d["X"] as? CGFloat ?? 0, y: d["Y"] as? CGFloat ?? 0,
                                width: d["Width"] as? CGFloat ?? 0, height: d["Height"] as? CGFloat ?? 0)
            }
            if bounds.width < 50 || bounds.height < 50 { continue }

            let runningApp = NSRunningApplication(processIdentifier: pid)
            let bundleId = runningApp?.bundleIdentifier ?? "unknown.\(pid)"
            let windowId = "\(bundleId).\(windowNumber)"

            result.append(RawWindowInfo(id: windowId, name: title, app: ownerName,
                                        bundleId: bundleId, pid: pid,
                                        windowNumber: windowNumber, bounds: bounds))
        }
        return result
    }

    /// Apply pre-fetched window data on main. Merges with existing state, resolves icons.
    func applyWindowSnapshot(_ raw: [RawWindowInfo]) {
        // Precompute once per snapshot. Accessing NSScreen.screens is MainActor-safe
        // and we're already on main here.
        let screens = NSScreen.screens
        let totalHeight = screens.map { $0.frame.maxY }.max() ?? 0

        var refreshed: [ManagedWindow] = []
        for info in raw {
            // CG bounds use top-left origin; NSScreen frames use bottom-left.
            // Flip the Y to compare against screen frames. Same technique as
            // `windows(for display:)` below.
            let flippedY = totalHeight - info.bounds.midY
            let center = CGPoint(x: info.bounds.midX, y: flippedY)
            let onScreen = screens.contains { $0.frame.contains(center) }

            let icon = NSRunningApplication(processIdentifier: info.pid)?.icon
            if let existing = windows.first(where: { $0.id == info.id }) {
                refreshed.append(ManagedWindow(
                    id: info.id, name: info.name, app: info.app,
                    subtitle: existing.subtitle, bundleId: info.bundleId, icon: icon,
                    isEnabled: existing.isEnabled, assignedColor: existing.assignedColor,
                    pid: info.pid, windowNumber: info.windowNumber, bounds: info.bounds,
                    iterm2SessionId: existing.iterm2SessionId,
                    iterm2Tty: existing.iterm2Tty,
                    isOnVisibleScreen: onScreen
                ))
            } else {
                refreshed.append(ManagedWindow(
                    id: info.id, name: info.name, app: info.app,
                    subtitle: "", bundleId: info.bundleId, icon: icon,
                    isEnabled: false, assignedColor: assignColor(),
                    pid: info.pid, windowNumber: info.windowNumber, bounds: info.bounds,
                    iterm2SessionId: nil,
                    iterm2Tty: nil,
                    isOnVisibleScreen: onScreen
                ))
            }
        }

        if !customOrder.isEmpty {
            var ordered: [ManagedWindow] = []
            for id in customOrder {
                if let w = refreshed.first(where: { $0.id == id }) { ordered.append(w) }
            }
            for w in refreshed where !customOrder.contains(w.id) {
                ordered.append(w)
                customOrder.append(w.id)
            }
            let activeIds = Set(refreshed.map(\.id))
            customOrder.removeAll { !activeIds.contains($0) }
            windows = ordered
        } else {
            windows = refreshed
            customOrder = refreshed.map(\.id)
        }
    }

    /// Convenience: fetch + apply in one call (runs CG query on main — use the
    /// static fetchWindowList + applyWindowSnapshot pair for off-main usage).
    func refreshWindowList() {
        applyWindowSnapshot(Self.fetchWindowList())
    }

    // MARK: - Filter by Display

    /// Returns windows whose center point falls within the given display's frame.
    /// CG window bounds use top-left origin; NSScreen uses bottom-left origin.
    /// We convert the CG Y to NSScreen coordinates for comparison.
    func windows(for display: DisplayInfo) -> [ManagedWindow] {
        // Get the total height of all screens to convert coordinates
        let totalHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? display.frame.height
        return windows.filter { window in
            // Convert CG top-left Y to NSScreen bottom-left Y
            let flippedY = totalHeight - window.bounds.midY
            let center = CGPoint(x: window.bounds.midX, y: flippedY)
            return display.frame.contains(center)
        }
    }

    // MARK: - Focus Window

    /// Bring a window to front and focus it
    func focusWindow(_ windowId: String) {
        guard let window = windows.first(where: { $0.id == windowId }) else { return }
        let app = NSRunningApplication(processIdentifier: window.pid)
        app?.activate()

        // Also raise the specific window via AX
        let appElement = AXUIElementCreateApplication(window.pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

        // Find matching AX window by position
        for axWindow in axWindows {
            var posRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success else { continue }
            var axPos = CGPoint.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &axPos)

            if abs(axPos.x - window.bounds.origin.x) < 10 && abs(axPos.y - window.bounds.origin.y) < 10 {
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                break
            }
        }
    }

    // MARK: - Arrange Windows

    /// Arrange enabled windows according to target frames.
    /// `frames` maps window IDs to their desired CGRect.
    @discardableResult
    func arrangeWindows(frames: [String: CGRect]) -> Bool {
        // Silent check — the prompting variant fires the Accessibility dialog
        // EVERY call until granted, so a phone user spamming the arrange button
        // got the dialog on every tap. The one-time prompt is done from
        // `promptForAccessibilityIfNeeded()` at app launch.
        guard AXIsProcessTrusted() else {
            print("[WindowManager] Accessibility permission not granted — skipping arrange. Grant in System Settings → Privacy & Security → Accessibility.")
            return false
        }

        print("[WindowManager] Arranging \(frames.count) windows")
        for (windowId, targetFrame) in frames {
            guard let window = windows.first(where: { $0.id == windowId }) else {
                print("[WindowManager] Window \(windowId) not found")
                continue
            }
            print("[WindowManager] Moving \(window.name) (pid=\(window.pid), wn=\(window.windowNumber)) to \(targetFrame)")
            moveAndResize(pid: window.pid, windowNumber: window.windowNumber, to: targetFrame)
        }
        // Refresh to pick up new positions after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            self.refreshWindowList()
        }
        return true
    }

    /// Shows the Accessibility access dialog ONCE per session if the app
    /// doesn't already have permission. Call this early (e.g. from App init)
    /// so the user sees one dialog at launch, not one per arrange tap.
    func promptForAccessibilityIfNeeded() {
        if AXIsProcessTrusted() { return }
        print("[WindowManager] Accessibility not granted. Enable in System Settings → Privacy & Security → Accessibility.")
    }

    // MARK: - AXUIElement Window Control

    /// Move and resize a specific window using Accessibility API.
    /// Matches the correct AX window by comparing current position/size
    /// against the known CG bounds of the window.
    private func moveAndResize(pid: pid_t, windowNumber: CGWindowID, to frame: CGRect) {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let attrResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard attrResult == .success, let axWindows = windowsRef as? [AXUIElement] else {
            print("[WindowManager] Failed to get AX windows for pid \(pid). Check Accessibility permission.")
            return
        }

        // Find the managed window's current bounds so we can match the correct AX window
        let managedWindow = windows.first { $0.pid == pid && $0.windowNumber == windowNumber }
        let currentBounds = managedWindow?.bounds ?? .zero

        // Find the best matching AX window by comparing positions
        var bestMatch: AXUIElement?
        var bestDistance: CGFloat = .infinity

        for axWindow in axWindows {
            // Get current AX position
            var posRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
                  let posValue = posRef else { continue }
            var axPos = CGPoint.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &axPos)

            // Get current AX size
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let sizeValue = sizeRef else { continue }
            var axSize = CGSize.zero
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &axSize)

            // Distance from known CG bounds
            let dx = axPos.x - currentBounds.origin.x
            let dy = axPos.y - currentBounds.origin.y
            let dw = axSize.width - currentBounds.width
            let dh = axSize.height - currentBounds.height
            let dist = sqrt(dx*dx + dy*dy + dw*dw + dh*dh)

            if dist < bestDistance {
                bestDistance = dist
                bestMatch = axWindow
            }
        }

        // If no position match, fall back to first window
        guard let targetAXWindow = bestMatch ?? axWindows.first else { return }

        // Set position
        var position = CGPoint(x: frame.origin.x, y: frame.origin.y)
        if let posValue = AXValueCreate(.cgPoint, &position) {
            let posResult = AXUIElementSetAttributeValue(targetAXWindow, kAXPositionAttribute as CFString, posValue)
            if posResult != .success {
                print("[WindowManager] Failed to set position: \(posResult.rawValue)")
            }
        }

        // Set size
        var size = CGSize(width: frame.size.width, height: frame.size.height)
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            let sizeResult = AXUIElementSetAttributeValue(targetAXWindow, kAXSizeAttribute as CFString, sizeValue)
            if sizeResult != .success {
                print("[WindowManager] Failed to set size: \(sizeResult.rawValue)")
            }
        }
    }

    // MARK: - Toggle Window

    /// Enable or disable a window for layout management
    func toggleWindow(_ windowId: String, enabled: Bool) {
        guard let index = windows.firstIndex(where: { $0.id == windowId }) else { return }
        windows[index].isEnabled = enabled
    }

    // MARK: - Color Assignment

    private func assignColor() -> String {
        let color = Self.colorPalette[colorIndex % Self.colorPalette.count]
        colorIndex += 1
        return color
    }

    // MARK: - Terminal Subtitles

    /// Query iTerm2 and Terminal.app for current session paths and update subtitles.
    func refreshSubtitles() {
        let subs = Self.fetchSubtitles()
        applySubtitles(subs)
    }

    /// Query iTerm2 for current session UUIDs and update `iterm2SessionId` on matching windows.
    func refreshIterm2SessionIds() {
        let sessions = Self.fetchIterm2SessionIds()
        applyIterm2SessionIds(sessions)
    }

    /// Filter the window list for LayoutUpdate broadcasts.
    ///
    /// Mirror OFF (default): only windows the user has explicitly enabled —
    /// Quip is an allowlist.
    ///
    /// Mirror ON: every terminal currently drawn on a connected screen goes
    /// out, so the phone shows the *visible* desktop at a glance. Off-screen
    /// terminals (inactive Space, disconnected monitor) are filtered out —
    /// CG's `.optionOnScreenOnly` isn't reliable here, so we re-check in
    /// `applyWindowSnapshot`. Enabled windows always ride along regardless
    /// of visibility, so a browser the user turned on, or a terminal that
    /// later slipped off-screen, doesn't disappear from the phone.
    nonisolated static func windowsForBroadcast(_ all: [ManagedWindow], mirrorDesktop: Bool) -> [ManagedWindow] {
        if mirrorDesktop {
            return all.filter { ($0.isTerminal && $0.isOnVisibleScreen) || $0.isEnabled }
        }
        return all.filter(\.isEnabled)
    }

    /// True when any tracked iTerm2 window is missing its session UUID — the
    /// snapshot timer checks this to fetch session IDs immediately on the next
    /// tick instead of waiting for the subtitle cycle. Without this, a newly
    /// spawned iTerm2 window can spend up to ~10s routing its text/keystrokes
    /// to whichever iTerm2 window happens to be frontmost on the Mac, because
    /// the AppleScript fallback path targets `current session of front window`.
    var needsIterm2SessionIdRefresh: Bool {
        let iterm2BundleId = TerminalApp.iterm2.bundleIdentifier
        return windows.contains { $0.bundleId == iterm2BundleId && $0.iterm2SessionId == nil }
    }

    /// One iTerm2 window's session mapping: the window's screen bounds and the
    /// UUID of its current session. Keyed by bounds (not by title) because
    /// iTerm2 window titles are frequently duplicated across windows — same
    /// process, same cwd → same title → collision.
    struct Iterm2SessionInfo: Sendable {
        let bounds: CGRect
        let uuid: String
        /// Tty device name (e.g. "ttys009") for this session. Used to find
        /// the per-window shell PID so state detection isn't conflated
        /// across all iTerm windows sharing the app PID.
        let tty: String
    }

    /// Fetch subtitles off main — runs AppleScript that can block for 1-3 seconds.
    /// Returns a dictionary of CGWindowID → subtitle string.
    nonisolated static func fetchSubtitles() -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]

        // iTerm2 subtitles via AppleScript
        let script = """
        set output to ""
        tell application "iTerm2"
            repeat with w in windows
                set wid to id of w
                tell current session of w
                    try
                        set p to variable named "path"
                    on error
                        set p to ""
                    end try
                end tell
                set output to output & wid & ":" & p & linefeed
            end repeat
        end tell
        return output
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            let asResult = appleScript.executeAndReturnError(&error)
            if error == nil, let output = asResult.stringValue {
                for line in output.components(separatedBy: "\n") where !line.isEmpty {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, let wid = Int(parts[0]) else { continue }
                    let path = String(parts[1])
                    result[CGWindowID(wid)] = (path as NSString).lastPathComponent
                }
            }
        }

        return result
    }

    /// One iTerm2 window as seen by a full "scan all" pass — used by the
    /// phone's "attach to existing session" flow. Unlike the tracked
    /// `ManagedWindow`, this is a lightweight snapshot whose only job is to
    /// describe what's currently open so the user can pick one to promote.
    struct ITermWindowDescriptor: Sendable, Equatable {
        let windowNumber: CGWindowID
        let title: String
        let sessionId: String
        let cwd: String
        let isMiniaturized: Bool
    }

    /// Enumerate every iTerm2 window on the Mac, whether Quip is already
    /// tracking it or not. Safe to call from any thread. Returns an empty
    /// list if iTerm2 isn't running (rather than launching it).
    nonisolated static func fetchAllITermWindows() -> [ITermWindowDescriptor] {
        // Guard first so we don't auto-launch iTerm2 just to scan.
        // `is running` on `application "iTerm2"` still loads the AE dictionary
        // which can spawn the app on some systems, so we route through System
        // Events' process list instead.
        let runningCheck = """
        tell application "System Events"
            return (name of processes) contains "iTerm2"
        end tell
        """
        guard let runScript = NSAppleScript(source: runningCheck) else { return [] }
        var runErr: NSDictionary?
        let runResult = runScript.executeAndReturnError(&runErr)
        guard runErr == nil, runResult.booleanValue else { return [] }

        // Four fields per window, TAB-separated, newline between windows.
        // Matches the separator style of `fetchIterm2SessionIds` above so
        // titles and paths with punctuation can't confuse the parser. "|"
        // wouldn't be safe — cwds and titles routinely contain it.
        let script = """
        set output to ""
        tell application "iTerm2"
            repeat with w in windows
                set wid to id of w
                set mini to miniaturized of w
                tell current session of w
                    set uid to unique id
                    set t to name
                    try
                        set p to variable named "path"
                    on error
                        set p to ""
                    end try
                end tell
                set output to output & wid & "\\t" & uid & "\\t" & t & "\\t" & p & "\\t" & mini & linefeed
            end repeat
        end tell
        return output
        """
        guard let appleScript = NSAppleScript(source: script) else { return [] }
        var error: NSDictionary?
        let asResult = appleScript.executeAndReturnError(&error)
        guard error == nil, let output = asResult.stringValue else { return [] }
        return parseITermWindowList(output)
    }

    /// Pure parser — kept separate from the AppleScript runner so we can
    /// test it against fixture strings without needing iTerm2 on CI.
    nonisolated static func parseITermWindowList(_ output: String) -> [ITermWindowDescriptor] {
        var result: [ITermWindowDescriptor] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 5,
                  let wid = Int(parts[0]) else { continue }
            let uuid = parts[1]
            let title = parts[2]
            let cwd = parts[3]
            // AppleScript booleans serialize as "true"/"false"; be tolerant of
            // either word in either case just in case the locale-aware
            // formatter ever hands us something different.
            let miniRaw = parts[4].lowercased()
            let mini = (miniRaw == "true")
            result.append(ITermWindowDescriptor(
                windowNumber: CGWindowID(wid),
                title: title,
                sessionId: uuid,
                cwd: cwd,
                isMiniaturized: mini
            ))
        }
        return result
    }

    /// Instance-side convenience for callers already on the main actor
    /// (e.g. the WebSocket scan-request handler in US-002).
    func listAllITermWindows() -> [ITermWindowDescriptor] {
        Self.fetchAllITermWindows()
    }

    /// Un-minimize an iTerm2 window and bring it to the front. Required
    /// before attaching a minimized window — CG's `.optionOnScreenOnly`
    /// excludes miniaturized windows, so without this the ManagedWindow
    /// never gets created and the phone's picker can't see it. Safe to
    /// call on a non-minimized window (no-op). Matches windows by their
    /// AppleScript `id`, which is the same number as CGWindowID.
    nonisolated static func unminimizeITermWindow(windowNumber: Int) -> Bool {
        let script = """
        tell application "iTerm2"
            try
                set w to first window whose id is \(windowNumber)
                if miniaturized of w then set miniaturized of w to false
                activate
                select w
                return "ok"
            on error errMsg
                return "err:" & errMsg
            end try
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let err = error {
            print("[WindowManager] unminimizeITermWindow failed: \(err)")
            return false
        }
        return result.stringValue == "ok"
    }

    nonisolated static func fetchIterm2SessionIds() -> [Iterm2SessionInfo] {
        var result: [Iterm2SessionInfo] = []
        // bounds of w returns {left, top, right, bottom} in screen coordinates
        // with top-left origin — same as CGWindowList. We join the four with
        // commas and use TAB to separate from the UUID so titles (or UUIDs
        // containing punctuation) can't confuse the parser.
        let script = """
        set output to ""
        tell application "iTerm2"
            repeat with w in windows
                set {l, t, r, b} to bounds of w
                tell current session of w
                    set uid to unique id
                    try
                        set ttyPath to tty
                    on error
                        set ttyPath to ""
                    end try
                end tell
                set output to output & l & "," & t & "," & r & "," & b & "\\t" & uid & "\\t" & ttyPath & linefeed
            end repeat
        end tell
        return output
        """

        guard let appleScript = NSAppleScript(source: script) else { return result }
        var error: NSDictionary?
        let asResult = appleScript.executeAndReturnError(&error)
        guard error == nil, let output = asResult.stringValue else { return result }

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            // Accept 2 fields (no tty, older iTerm) or 3 (with tty).
            guard parts.count >= 2 else { continue }
            let coords = parts[0].components(separatedBy: ",")
            guard coords.count == 4,
                  let l = Double(coords[0]), let t = Double(coords[1]),
                  let r = Double(coords[2]), let b = Double(coords[3]) else { continue }
            let bounds = CGRect(x: l, y: t, width: r - l, height: b - t)
            let uuid = parts[1]
            // iTerm returns full device path like "/dev/ttys009". Strip to just
            // "ttys009" so it matches ps's `tt` column.
            let rawTty = parts.count >= 3 ? parts[2] : ""
            let tty = rawTty.hasPrefix("/dev/") ? String(rawTty.dropFirst(5)) : rawTty
            result.append(Iterm2SessionInfo(bounds: bounds, uuid: uuid, tty: tty))
        }
        return result
    }

    /// Apply pre-fetched subtitles to windows. Call on main.
    func applySubtitles(_ subtitles: [CGWindowID: String]) {
        for (wid, folder) in subtitles {
            if let index = windows.firstIndex(where: { $0.windowNumber == wid }) {
                windows[index].subtitle = folder
            }
        }
        // Terminal.app — extract from window name
        for i in windows.indices where windows[i].bundleId == "com.apple.Terminal" {
            let name = windows[i].name
            if name.contains("—") {
                let parts = name.components(separatedBy: "—").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count >= 2 {
                    let pathPart = parts[1]
                    windows[i].subtitle = (pathPart as NSString).lastPathComponent
                }
            }
        }
    }

    /// Attach each iTerm2 session UUID to the tracked window whose bounds best
    /// match its AppleScript-reported bounds. Matching by bounds (not by title)
    /// is required because iTerm2 windows routinely share titles — same
    /// command, same cwd.
    ///
    /// Why 4D distance (midX, midY, width, height) instead of just midpoint:
    /// a dev who works with several iTerm windows stacked at near-identical
    /// positions — e.g. a column of three 600-wide panes that start at the
    /// same x — has midpoints clumped within a few points of each other, so
    /// 2D midpoint matching hands the wrong UUIDs out. Width and height are
    /// what actually distinguish the windows, and folding them into the
    /// distance metric gets the right pair out of a clump.
    ///
    /// Why greedy-unique assignment: without it, two different CG windows
    /// could both nominate the same AppleScript session as their "best match"
    /// and we'd silently hand the same UUID to both — one of them then reads
    /// or types into its neighbor's pane. Claiming each UUID once prevents
    /// that collision; any window that can't find an unclaimed match within
    /// tolerance is left with a nil UUID, and the phone's read/write paths
    /// refuse to touch it until the next refresh.
    /// Reconcile the persisted attached-session list against what iTerm2
    /// currently reports. Any sessionId the user attached in a prior run
    /// that is no longer present in iTerm (session closed, Mac rebooted,
    /// etc.) gets dropped from the persistent set — otherwise we'd hold
    /// onto zombie UUIDs forever. Call this after each `listAllITermWindows`
    /// fetch in handlers where we have a fresh view of iTerm reality.
    /// Does NOT drop sessionIds when iTerm simply isn't running yet (empty
    /// list) — only when we have a list AND the id isn't in it.
    func reconcileAttachedSessions(withLiveSessionIds live: Set<String>) {
        guard !live.isEmpty else { return }
        let stale = attachedSessionIds.subtracting(live)
        guard !stale.isEmpty else { return }
        for sid in stale { attachedSessionIds.remove(sid) }
        persistAttachedSessionIds()
        print("[WindowManager] reconciled attached sessions: dropped \(stale.count) stale UUID(s): \(stale)")
    }

    /// After iterm2SessionIds are applied, make sure every window whose
    /// session the user previously attached is flagged enabled. Without
    /// this, attached windows wouldn't come back enabled after a Quip
    /// restart — they'd be in the list but invisible to the default
    /// (non-mirror) picker. Call after `applyIterm2SessionIds`.
    func enableAttachedWindows() {
        guard !attachedSessionIds.isEmpty else { return }
        for i in windows.indices {
            if let sid = windows[i].iterm2SessionId, attachedSessionIds.contains(sid) {
                windows[i].isEnabled = true
            }
        }
    }

    func applyIterm2SessionIds(_ sessions: [Iterm2SessionInfo]) {
        let iterm2BundleId = TerminalApp.iterm2.bundleIdentifier
        // Tolerance is per-dimension (midX/Y/width/height each). Summed as
        // squared distance, the effective threshold is 4 * tol^2 in 4D.
        let perDimTolerance: CGFloat = 40
        let matchToleranceSquared: CGFloat = 4 * perDimTolerance * perDimTolerance

        var claimedUUIDs: Set<String> = []

        // Build (CG-window-index, best-session-index, dist²) triples, then
        // assign in ascending-distance order so the *most confident* matches
        // claim their UUIDs first. Shakier matches either fall back to the
        // next-best unclaimed session or end up nil.
        struct Candidate { let windowIndex: Int; let sessionIndex: Int; let distSq: CGFloat }
        var candidates: [Candidate] = []
        for i in windows.indices where windows[i].bundleId == iterm2BundleId {
            let target = windows[i].bounds
            for (sIdx, session) in sessions.enumerated() {
                let dx = session.bounds.midX - target.midX
                let dy = session.bounds.midY - target.midY
                let dw = session.bounds.width - target.width
                let dh = session.bounds.height - target.height
                let distSq = dx * dx + dy * dy + dw * dw + dh * dh
                candidates.append(Candidate(windowIndex: i, sessionIndex: sIdx, distSq: distSq))
            }
            // Clear any stale assignment before re-matching on this pass.
            windows[i].iterm2SessionId = nil
            windows[i].iterm2Tty = nil
        }
        candidates.sort { $0.distSq < $1.distSq }

        for c in candidates where c.distSq <= matchToleranceSquared {
            let session = sessions[c.sessionIndex]
            if claimedUUIDs.contains(session.uuid) { continue }
            if windows[c.windowIndex].iterm2SessionId != nil { continue }
            windows[c.windowIndex].iterm2SessionId = session.uuid
            windows[c.windowIndex].iterm2Tty = session.tty.isEmpty ? nil : session.tty
            claimedUUIDs.insert(session.uuid)
        }
    }
}
