// SettingsView.swift
// QuipMac — macOS Settings window with tabbed configuration panels

import SwiftUI
import Darwin
import AppKit

/// The six Settings panes. Single source of truth for the customizable
/// NSToolbar (id / title / SF Symbol) and the content switch below.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, layouts, projects, prompts, connection, security, notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:       return "General"
        case .layouts:       return "Layouts"
        case .projects:      return "Projects"
        case .prompts:       return "Prompts"
        case .connection:    return "Connection"
        case .security:      return "Security"
        case .notifications: return "Notifications"
        }
    }

    var systemImage: String {
        switch self {
        case .general:       return "gearshape.fill"
        case .layouts:       return "rectangle.3.group.fill"
        case .projects:      return "folder.fill"
        case .prompts:       return "text.bubble.fill"
        case .connection:    return "wifi"
        case .security:      return "lock.fill"
        case .notifications: return "bell.badge.fill"
        }
    }

    /// Sidebar icon-tile tint. Restrained, System-Settings-style mapping — one
    /// flat color per pane, semantically chosen (green = connectivity, orange =
    /// security, red = alerts) rather than decorative.
    var tint: Color {
        switch self {
        case .general:       return .gray
        case .layouts:       return .indigo
        case .projects:      return .blue
        case .prompts:       return .purple
        case .connection:    return .green
        case .security:      return .orange
        case .notifications: return .red
        }
    }
}

struct SettingsView: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(WebSocketServer.self) private var webSocketServer
    @Environment(BonjourAdvertiser.self) private var bonjourAdvertiser
    @Environment(PINManager.self) private var pinManager

    // Persisted sidebar selection so reopening Settings lands on the last pane.
    @AppStorage("settingsSelectedTab") private var selectionRaw: String = SettingsTab.general.id

    private var current: SettingsTab { SettingsTab(rawValue: selectionRaw) ?? .general }

    /// List(selection:) wants an optional; seeded from the persisted raw string
    /// on appear and written back on change. A nil (clicking empty space) snaps
    /// back to the current pane so a pane is always shown.
    @State private var selection: SettingsTab?

    var body: some View {
        // Sidebar layout — the modern macOS System Settings idiom. A
        // NavigationSplitView fills a resizable window far better than a
        // top-anchored TabView/form (no oceans of dead space when the window
        // grows), and reads as a native Apple app. Every .environment injected
        // on this scene in QuipMacApp reaches each pane unchanged.
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    SettingsIconTile(symbol: tab.systemImage, tint: tab.tint)
                }
                .tag(tab)
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 198, ideal: 214, max: 264)
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsIdentityHeader()
            }
        } detail: {
            paneContent
                // Cap the content column so panes never sprawl edge-to-edge
                // when the window is widened — the System Settings move. Rows
                // stay readable (no label-far-left / value-far-right chasm);
                // extra width becomes quiet margin. The second frame re-centers
                // that capped column in the detail pane.
                .frame(maxWidth: 600, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(current.title)
        }
        // min = floor; ideal = the size the window opens at when there's no
        // saved frame. Without an ideal, the NavigationSplitView + grouped
        // forms drove the window to a sprawling ~1200×1100; 780×600 is a tidy
        // default that still resizes freely (the original vertical-resize fix).
        .frame(minWidth: 720, idealWidth: 780, maxWidth: .infinity,
               minHeight: 480, idealHeight: 600, maxHeight: .infinity)
        .onAppear { selection = current }
        .onChange(of: selection) { _, new in
            if let new { selectionRaw = new.id } else { selection = current }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch current {
        case .general:       GeneralTab()
        case .layouts:       LayoutsTab()
        case .projects:      ProjectsTab()
        case .prompts:       PromptsTab()
        case .connection:    ConnectionTab()
        case .security:      SecurityTab()
        case .notifications: NotificationsTab()
        }
    }
}
