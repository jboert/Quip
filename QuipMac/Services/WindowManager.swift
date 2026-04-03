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

    /// Convert to shared WindowState for protocol messages.
    /// Frame is normalized to 0-1 relative to the given screen bounds.
    func toWindowState(state: String = "neutral", screenBounds: CGRect? = nil) -> WindowState {
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
            app: subtitle.isEmpty ? app : subtitle,
            enabled: isEnabled,
            frame: frame,
            state: state,
            color: assignedColor
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

    /// Available displays
    var displays: [DisplayInfo] = []

    // Next color index for assignment
    private var colorIndex: Int = 0

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

    /// Enumerate all on-screen, normal-level windows (filters out menubar, dock, etc.)
    func refreshWindowList() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        var refreshed: [ManagedWindow] = []

        for info in infoList {
            // Must have a valid window layer (0 = normal windows)
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }
            guard let windowNumber = info[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            guard let ownerName = info[kCGWindowOwnerName as String] as? String else {
                continue
            }
            // Filter out common system UI elements
            let systemApps = ["Window Server", "Control Center", "Notification Center", "SystemUIServer"]
            if systemApps.contains(ownerName) { continue }

            let title = info[kCGWindowName as String] as? String ?? ownerName

            // Parse bounds
            var bounds = CGRect.zero
            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any] {
                let x = boundsDict["X"] as? CGFloat ?? 0
                let y = boundsDict["Y"] as? CGFloat ?? 0
                let w = boundsDict["Width"] as? CGFloat ?? 0
                let h = boundsDict["Height"] as? CGFloat ?? 0
                bounds = CGRect(x: x, y: y, width: w, height: h)
            }

            // Skip tiny windows (toolbars, status items, etc.)
            if bounds.width < 50 || bounds.height < 50 { continue }

            // Get bundle ID from running application
            let runningApp = NSRunningApplication(processIdentifier: pid)
            let bundleId = runningApp?.bundleIdentifier ?? "unknown.\(pid)"
            let icon = runningApp?.icon

            let windowId = "\(bundleId).\(windowNumber)"

            // Preserve existing state if this window was already tracked
            if let existing = windows.first(where: { $0.id == windowId }) {
                refreshed.append(ManagedWindow(
                    id: windowId,
                    name: title,
                    app: ownerName,
                    subtitle: existing.subtitle,
                    bundleId: bundleId,
                    icon: icon,
                    isEnabled: existing.isEnabled,
                    assignedColor: existing.assignedColor,
                    pid: pid,
                    windowNumber: windowNumber,
                    bounds: bounds
                ))
            } else {
                refreshed.append(ManagedWindow(
                    id: windowId,
                    name: title,
                    app: ownerName,
                    subtitle: "",
                    bundleId: bundleId,
                    icon: icon,
                    isEnabled: false,
                    assignedColor: assignColor(),
                    pid: pid,
                    windowNumber: windowNumber,
                    bounds: bounds
                ))
            }
        }

        // Sort by customOrder if set, otherwise keep CG order
        if !customOrder.isEmpty {
            var ordered: [ManagedWindow] = []
            for id in customOrder {
                if let w = refreshed.first(where: { $0.id == id }) {
                    ordered.append(w)
                }
            }
            for w in refreshed where !customOrder.contains(w.id) {
                ordered.append(w)
                customOrder.append(w.id)
            }
            // Remove stale IDs
            let activeIds = Set(refreshed.map(\.id))
            customOrder.removeAll { !activeIds.contains($0) }
            windows = ordered
        } else {
            windows = refreshed
            customOrder = refreshed.map(\.id)
        }
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
    func arrangeWindows(frames: [String: CGRect]) {
        // Check Accessibility permission — prompt if not granted
        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        if !trusted {
            print("[WindowManager] Accessibility permission not granted. Please enable in System Settings > Privacy & Security > Accessibility.")
            return
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
        refreshITerm2Subtitles()
        refreshTerminalSubtitles()
    }

    private func refreshITerm2Subtitles() {
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

        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, let output = result.stringValue else { return }

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let wid = Int(parts[0]) else { continue }
            let path = String(parts[1])
            // Extract just the last folder name
            let folder = (path as NSString).lastPathComponent

            // Find matching window by CG window number
            if let index = windows.firstIndex(where: { $0.windowNumber == CGWindowID(wid) }) {
                windows[index].subtitle = folder
            }
        }
    }

    private func refreshTerminalSubtitles() {
        // Terminal.app window names typically include the directory already
        // Just extract the folder from the window name if possible
        for i in windows.indices where windows[i].bundleId == "com.apple.Terminal" {
            let name = windows[i].name
            // Terminal titles look like "bcap — ~/Projects/foo — zsh"
            if name.contains("—") {
                let parts = name.components(separatedBy: "—").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count >= 2 {
                    // Use the path part (usually second segment)
                    let pathPart = parts[1]
                    let folder = (pathPart as NSString).lastPathComponent
                    windows[i].subtitle = folder
                }
            }
        }
    }
}
